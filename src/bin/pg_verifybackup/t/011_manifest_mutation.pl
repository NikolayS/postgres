# Copyright (c) 2021-2026, PostgreSQL Global Development Group

# Regression coverage for "corrupt file in, clean error out", applied to the
# backup manifest: take a real base backup, then apply deterministic mutations
# to its real backup_manifest (truncation at structural boundaries, byte/bit
# flips of JSON structure at fixed anchor points, and bogus size / checksum
# fields) and confirm that pg_verifybackup rejects every mutant with a nonzero
# exit status and a clean error message, and never dies from a signal (crash /
# assertion failure / core dump).
#
# The existing 005_bad_manifest.pl feeds pg_verifybackup hand-written tiny
# manifests to exercise individual JSON parse errors; 003_corruption.pl mutates
# the backup *data* and appends a byte to the manifest. What was missing, and
# what this test adds, is mutating a real, full-sized manifest at the byte level
# (truncations at fixed offsets and structural bit flips) and asserting the
# tool fails cleanly without crashing.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Set up an instance and populate it with a little data.
my $primary = PostgreSQL::Test::Cluster->new('primary');
$primary->init(allows_streaming => 1);
$primary->start;
$primary->safe_psql('postgres', <<'EOM');
CREATE TABLE t1 (a int, b text);
INSERT INTO t1 SELECT g, repeat('x', 100) FROM generate_series(1, 1000) g;
CHECKPOINT;
EOM

# Take a base backup with a manifest and confirm it verifies cleanly.
my $backup_path = $primary->backup_dir . '/mutation';
$primary->command_ok(
	[
		'pg_basebackup',
		'--pgdata' => $backup_path,
		'--no-sync',
		'--checkpoint' => 'fast',
	],
	'base backup ok');
command_ok([ 'pg_verifybackup', $backup_path ], 'intact backup verified');

my $manifest_path = "$backup_path/backup_manifest";
my $orig = slurp_file($manifest_path);
my $orig_len = length($orig);
note("real backup manifest is $orig_len bytes");

# ---------------------------------------------------------------------------
# Build the mutation matrix. Every mutation is deterministic: fixed truncation
# lengths and fixed anchor points located structurally in the real manifest,
# with fixed replacement bytes. No randomness.
#
# Note on expected errors: the manifest carries its own SHA256 "Manifest-
# Checksum" covering all preceding bytes, so any byte change that leaves the
# JSON well-formed is caught as a "manifest checksum mismatch", while changes
# that break the JSON structure are caught earlier as a parse error. Both are
# clean, signal-free failures, which is the property under test.
# ---------------------------------------------------------------------------
my @mutations;

# --- Truncation at structural boundaries -----------------------------------
push @mutations,
  {
	name => 'truncate to 0 bytes (empty manifest)',
	data => '',
	err => qr/backup manifest/,
  },
  {
	name => 'truncate to 1 byte (lone opening brace)',
	data => substr($orig, 0, 1),
	err => qr/could not parse backup manifest/,
  },
  {
	name => 'truncate at midpoint (mid-JSON)',
	data => substr($orig, 0, int($orig_len / 2)),
	err => qr/pg_verifybackup: error:/,
  },
  {
	name => 'truncate final newline',
	data => substr($orig, 0, $orig_len - 1),
	err => qr/pg_verifybackup: error:/,
  };

# --- Bit / byte flips of JSON structure at fixed anchor points -------------

# Flip the top-level opening brace to an opening bracket: well-formed prefix,
# but not the object the parser expects.
push @mutations,
  {
	name => 'corrupt top-level object start',
	data => replace_at($orig, 0, '['),
	err => qr/could not parse backup manifest/,
  };

# Corrupt the version key so it is no longer recognized.
{
	my $off = index($orig, 'PostgreSQL-Backup-Manifest-Version');
	die "could not locate version key" if $off < 0;
	push @mutations,
	  {
		name => 'corrupt version key name',
		data => replace_at($orig, $off, 'Q'),
		err => qr/could not parse backup manifest/,
	  };
}

# Corrupt the structural brace that opens the "Files" array's first object.
{
	my $off = index($orig, '{ "Path": ');
	if ($off >= 0)
	{
		push @mutations,
		  {
			name => 'corrupt file object start',
			data => replace_at($orig, $off, 'Z'),
			err => qr/could not parse backup manifest/,
		  };
	}
}

# --- Bogus size / checksum fields (valid JSON -> checksum mismatch) ---------

# Change one digit of a file's Size field.
if ($orig =~ /"Size": (\d)/)
{
	my $off = $-[1];    # offset of the first Size digit
	my $newdigit = (substr($orig, $off, 1) eq '9') ? '1' : '9';
	push @mutations,
	  {
		name => 'bogus file size',
		data => replace_at($orig, $off, $newdigit),
		err => qr/manifest checksum mismatch/,
	  };
}

# Flip one hex character of a file's Checksum value.
if ($orig =~ /"Checksum": "([0-9a-f])/)
{
	my $off = $-[1];
	my $newc = (substr($orig, $off, 1) eq 'a') ? 'b' : 'a';
	push @mutations,
	  {
		name => 'bogus file checksum',
		data => replace_at($orig, $off, $newc),
		err => qr/manifest checksum mismatch/,
	  };
}

# Flip one hex character inside the manifest's own SHA256 checksum.
if ($orig =~ /"Manifest-Checksum": "([0-9a-f])/)
{
	my $off = $-[1];
	my $newc = (substr($orig, $off, 1) eq 'a') ? 'b' : 'a';
	push @mutations,
	  {
		name => 'corrupt manifest checksum value',
		data => replace_at($orig, $off, $newc),
		err => qr/manifest checksum mismatch/,
	  };
}

# ---------------------------------------------------------------------------
# Run pg_verifybackup against each mutated manifest and require a clean
# failure. We restore the pristine manifest into memory for each iteration, so
# mutations do not compound.
# ---------------------------------------------------------------------------
for my $m (@mutations)
{
	# Overwrite the backup's manifest with the mutated bytes.
	open(my $fh, '>:raw', $manifest_path) || die "open $manifest_path: $!";
	print $fh $m->{data};
	close($fh);

	my ($stdout, $stderr) = ('', '');
	print("# Running: pg_verifybackup $backup_path\n");
	IPC::Run::run([ 'pg_verifybackup', $backup_path ],
		'>' => \$stdout, '2>' => \$stderr);
	my $child = $?;

	# The cardinal requirement: never a crash / signal / core dump.
	my $signal = $child & 127;
	is($signal, 0, "no crash on: $m->{name}")
	  or diag("pg_verifybackup died from signal $signal on '$m->{name}'; "
		  . "stderr: $stderr");

	# And it must reject the manifest with a nonzero exit and a clean message.
	my $exit_code = $child >> 8;
	isnt($exit_code, 0, "nonzero exit on: $m->{name}");
	like($stderr, $m->{err}, "clean error message on: $m->{name}");
}

done_testing();

# Return a copy of $str with the single byte at $off replaced by $repl.
sub replace_at
{
	my ($str, $off, $repl) = @_;
	substr($str, $off, 1) = $repl;
	return $str;
}
