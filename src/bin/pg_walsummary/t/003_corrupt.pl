# Copyright (c) 2021-2026, PostgreSQL Global Development Group

# Regression coverage for "corrupt file in, clean error out": generate a real
# WAL summary file, then apply deterministic mutations to it (truncation at
# structural boundaries, bit flips in header / fork-number / chunk-size fields,
# and oversized length/count values) and confirm that pg_walsummary rejects
# every mutant with a nonzero exit status and a clean error message, and never
# dies from a signal (crash / assertion failure / core dump).
#
# This exercises the on-disk validation in src/common/blkreftable.c, including
# the fork-number and chunk-size sanity checks added by commit ee654419d5.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# The on-disk block reference table format (see src/common/blkreftable.c):
#
#   uint32  magic (BLOCKREFTABLE_MAGIC == 0x652b137b)
#   repeated serialized entries, each:
#       uint32  rlocator.spcOid
#       uint32  rlocator.dbOid
#       uint32  rlocator.relNumber
#       int32   forknum
#       uint32  limit_block
#       uint32  nchunks
#       uint16  chunk_usage[nchunks]         (chunk length array)
#       uint16  chunk_data[...]              (per chunk: chunk_usage[j] entries)
#   an all-zero 24-byte serialized entry acts as the terminator
#   uint32  crc
#
# All integers are stored in native byte order; the test reads and writes the
# file on the same machine that produced it, so native byte order is correct.
use constant {
	BLOCKREFTABLE_MAGIC => 0x652b137b,
	ENTRY_LEN => 24,             # sizeof(BlockRefTableSerializedEntry)
	OFF_FORKNUM => 12,           # within a serialized entry
	OFF_LIMIT_BLOCK => 16,
	OFF_NCHUNKS => 20,
	MAX_FORKNUM => 3,            # INIT_FORKNUM
	MAX_ENTRIES_PER_CHUNK => 4096,    # BLOCKS_PER_CHUNK / BLOCKS_PER_ENTRY
};

# Set up a database instance with WAL summarization enabled.
my $node = PostgreSQL::Test::Cluster->new('node');
$node->init(has_archiving => 1, allows_streaming => 1);
$node->append_conf('postgresql.conf', 'summarize_wal = on');
$node->start;

# Generate WAL that touches many blocks so that the resulting summary file
# contains at least one relation fork with real chunk data (not just a limit
# block), which lets us exercise the chunk-size validation path.
$node->safe_psql('postgres', <<'EOM');
CREATE TABLE mytable (a int, b text);
INSERT INTO mytable
SELECT g, repeat('x', 200) FROM generate_series(1, 5000) g;
UPDATE mytable SET b = repeat('y', 200) WHERE a % 3 = 0;
VACUUM FREEZE mytable;
CHECKPOINT;
EOM

my $base_lsn = $node->safe_psql('postgres', 'SELECT pg_current_wal_insert_lsn()');
$node->safe_psql('postgres', 'CHECKPOINT');

# Wait until a summary covering our activity has been written to disk.
$node->poll_query_until('postgres', <<EOM)
SELECT EXISTS (
    SELECT * FROM pg_available_wal_summaries()
    WHERE end_lsn >= '$base_lsn'
)
EOM
  or die "timed out waiting for WAL summarization to catch up";

# Stop the server so the set of summary files is stable while we mutate copies.
$node->stop;

# Pick the largest summary file on disk; it is the most likely to contain a
# relation fork with chunk data.
my $summary_dir = $node->data_dir . '/pg_wal/summaries';
opendir(my $dh, $summary_dir) || die "opendir $summary_dir: $!";
my @summaries = sort grep { /\.summary$/ } readdir($dh);
closedir($dh);
die "no WAL summary files were generated" unless @summaries;

my ($orig_file, $orig_size) = ('', -1);
for my $f (@summaries)
{
	my $path = "$summary_dir/$f";
	my $sz = -s $path;
	($orig_file, $orig_size) = ($path, $sz) if $sz > $orig_size;
}
note("using WAL summary file $orig_file ($orig_size bytes)");

# Read the pristine summary file into memory.
my $orig = slurp_file($orig_file);
my $orig_len = length($orig);

# Sanity check: pg_walsummary reads the unmodified file cleanly.
{
	my $good = "$PostgreSQL::Test::Utils::tmp_check/good.summary";
	write_summary($good, $orig);
	my ($ret, $stdout, $stderr) = run_walsummary($good);
	is($ret, 0, "pristine summary file parses successfully");
}

# Parse the entry structure so we can target specific fields precisely.
my $magic = unpack('L', substr($orig, 0, 4));
is($magic, BLOCKREFTABLE_MAGIC, "summary file has expected magic number");

my $first_entry_off = 4;
my $first_chunk_size_off;    # offset of first chunk_usage[] value, if any
my $mid_chunk_off;           # a byte offset that lands inside chunk data

{
	my $pos = 4;
	while ($pos + ENTRY_LEN <= $orig_len)
	{
		my $hdr = substr($orig, $pos, ENTRY_LEN);
		last if $hdr eq ("\0" x ENTRY_LEN);    # terminator

		my $nchunks = unpack('L', substr($hdr, OFF_NCHUNKS, 4));
		my $entry_start = $pos;
		$pos += ENTRY_LEN;

		if ($nchunks > 0 && !defined $first_chunk_size_off)
		{
			$first_chunk_size_off = $pos;
		}

		# Read chunk_usage[] and advance past the chunk data.
		my @usage = unpack("S$nchunks", substr($orig, $pos, 2 * $nchunks));
		$pos += 2 * $nchunks;
		for my $u (@usage)
		{
			# The first non-empty chunk gives us a genuine "mid-chunk" offset.
			$mid_chunk_off = $pos + 1
			  if $u > 0 && !defined $mid_chunk_off;
			$pos += 2 * $u;
		}
	}
}

note(
	defined $first_chunk_size_off
	? "first chunk_usage[] value at offset $first_chunk_size_off"
	: "no relation fork with chunk data found");

# ---------------------------------------------------------------------------
# Build the mutation matrix. Each mutation is deterministic: fixed offsets
# (computed from the real file structure) and fixed values, no randomness.
# ---------------------------------------------------------------------------
my @mutations;

# --- Truncation at structural boundaries -----------------------------------
push @mutations,
  {
	name => 'truncate to 0 bytes (empty file)',
	data => '',
	err => qr/ends unexpectedly/,
  },
  {
	name => 'truncate mid-magic (2 bytes)',
	data => substr($orig, 0, 2),
	err => qr/ends unexpectedly/,
  },
  {
	name => 'truncate after magic (no entries)',
	data => substr($orig, 0, 4),
	err => qr/ends unexpectedly/,
  },
  {
	name => 'truncate mid-header (partial first entry)',
	data => substr($orig, 0, 4 + 12),
	err => qr/ends unexpectedly/,
  },
  {
	name => 'truncate mid-CRC (drop trailing bytes)',
	data => substr($orig, 0, $orig_len - 3),
	err => qr/ends unexpectedly/,
  };

push @mutations,
  {
	name => 'truncate mid-chunk (inside chunk data)',
	data => substr($orig, 0, $mid_chunk_off),
	err => qr/ends unexpectedly/,
  }
  if defined $mid_chunk_off;

# --- Bit flips in header / fork-number / chunk-size fields -----------------
push @mutations,
  {
	name => 'corrupt magic number',
	data => mutate_u32($orig, 0, BLOCKREFTABLE_MAGIC ^ 0x01),
	err => qr/wrong magic number/,
  },
  {
	name => 'invalid fork number (too large)',
	data => mutate_i32($orig, $first_entry_off + OFF_FORKNUM, 16),
	err => qr/invalid fork number/,
  },
  {
	name => 'invalid fork number (negative)',
	data => mutate_i32($orig, $first_entry_off + OFF_FORKNUM, -5),
	err => qr/invalid fork number/,
  },
  {
	name => 'corrupt limit_block (CRC mismatch)',
	data => mutate_u32(
		$orig, $first_entry_off + OFF_LIMIT_BLOCK,
		unpack('L', substr($orig, $first_entry_off + OFF_LIMIT_BLOCK, 4)) ^
		  0xFFFF),
	err => qr/wrong checksum/,
  };

push @mutations,
  {
	name => 'oversized chunk size value',
	data => mutate_u16($orig, $first_chunk_size_off, 0xFFFF),
	err => qr/chunk \d+ has invalid size/,
  }
  if defined $first_chunk_size_off;

# --- Oversized length / count values ---------------------------------------
push @mutations,
  {
	name => 'oversized nchunks (overflows allocation limit)',
	data => mutate_u32($orig, $first_entry_off + OFF_NCHUNKS, 0xFFFFFFFF),
	err => qr/oversized chunk size array/,
  },
  {
	# Large but below the allocation cap: passes the oversize check, then the
	# read of the chunk-size array runs off the end of the (short) file.
	name => 'large nchunks (chunk array runs off end of file)',
	data => mutate_u32($orig, $first_entry_off + OFF_NCHUNKS, 0x00100000),
	err => qr/ends unexpectedly/,
  };

# ---------------------------------------------------------------------------
# Run pg_walsummary on each mutant and require a clean failure.
# ---------------------------------------------------------------------------
my $i = 0;
for my $m (@mutations)
{
	my $path = sprintf("%s/mutant_%02d.summary",
		$PostgreSQL::Test::Utils::tmp_check, $i++);
	write_summary($path, $m->{data});

	my ($ret, $stdout, $stderr) = run_walsummary($path);

	# The cardinal requirement: never a crash / signal / core dump.
	my $signal = $ret & 127;
	is($signal, 0, "no crash on: $m->{name}")
	  or diag("pg_walsummary died from signal $signal on '$m->{name}'; "
		  . "stderr: $stderr");

	# And it must reject the file with a nonzero exit and a clean message.
	my $exit_code = $ret >> 8;
	isnt($exit_code, 0, "nonzero exit on: $m->{name}");
	like($stderr, $m->{err}, "clean error message on: $m->{name}");
}

done_testing();

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

# Overwrite 4 bytes at $off with a native-order uint32.
sub mutate_u32
{
	my ($data, $off, $val) = @_;
	substr($data, $off, 4) = pack('L', $val);
	return $data;
}

# Overwrite 4 bytes at $off with a native-order int32.
sub mutate_i32
{
	my ($data, $off, $val) = @_;
	substr($data, $off, 4) = pack('l', $val);
	return $data;
}

# Overwrite 2 bytes at $off with a native-order uint16.
sub mutate_u16
{
	my ($data, $off, $val) = @_;
	substr($data, $off, 2) = pack('S', $val);
	return $data;
}

sub write_summary
{
	my ($path, $data) = @_;
	open(my $fh, '>:raw', $path) || die "open $path: $!";
	print $fh $data;
	close($fh);
	return;
}

# Run pg_walsummary on a file, returning ($child_error, $stdout, $stderr).
# $child_error is Perl's $? so callers can inspect both the signal (low 7 bits)
# and the exit code (>> 8) -- command_fails_like() would hide a signal death.
sub run_walsummary
{
	my ($path) = @_;
	my ($stdout, $stderr) = ('', '');
	print("# Running: pg_walsummary -i $path\n");
	IPC::Run::run([ 'pg_walsummary', '-i', $path ],
		'>' => \$stdout, '2>' => \$stderr);
	return ($?, $stdout, $stderr);
}
