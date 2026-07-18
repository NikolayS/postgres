# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Physical oracle for incremental backup completeness.
#
# Incremental backups rely on the WAL summarizer, which only knows about
# buffers that WAL records properly register.  Any code path that modifies a
# relation page without registering the buffer (or without WAL-logging the
# change at all) is invisible to the summarizer, and pg_combinebackup will
# silently reconstruct a stale page from an older backup.  Past bugs of this
# class (e.g. visibility map buffers not registered by heap operations) were
# only caught operation-by-operation.  This test is a generic oracle: it
# runs a mixed workload with churn concurrent to a chain of incremental
# backups, then quiesces the cluster and takes -- back to back, with no
# intervening relation writes -- a final incremental backup and a reference
# full backup.  The combined result of the backup chain must then be
# physically identical, relation block by relation block, to the reference
# full backup.
#
# Comparison scope and masking:
# - main, _vm and _init relation forks under base/ and global/ are compared
#   byte-for-byte per 8 KB block.
# - _fsm forks are skipped: the free space map is not fully WAL-logged by
#   design, so it is legitimately allowed to diverge.
# - Within a block, only pd_lsn and pd_checksum (the first 10 bytes of the
#   page header) are masked.  Everything else, including hint bits in tuple
#   infomasks, must match: data checksums are enabled by default, so hint
#   bit changes that reach disk are WAL-logged as full-page hints and hence
#   visible to the WAL summarizer.  Blocks that differ only in the masked
#   bytes are counted and reported as a note, not a failure.
#
# Quiescence discipline: after the workload stops, a settle sequence
# (VACUUM, catalog/table scans to set any remaining hint bits, CHECKPOINT)
# runs before the final backup pair.  The WAL range spanning both final
# backups is then checked with pg_waldump: if any WAL record in that range
# references a relation block, the reference backup might not describe the
# same cluster state as the combined backup, so the pair is retaken (with a
# bounded number of attempts) rather than risking a false verdict.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use constant BLCKSZ => 8192;
# pd_lsn (8 bytes) + pd_checksum (2 bytes)
use constant MASKED_HEADER_BYTES => 10;
# blocks per 1 GB segment file with default BLCKSZ
use constant RELSEG_SIZE => 131072;

my $mode = $ENV{PG_TEST_PG_COMBINEBACKUP_MODE} || '--copy';
note "testing using mode $mode";

# Set up a primary with WAL summarization.  Autovacuum is disabled so that
# all relation modifications come from the (bounded) workload below and the
# final quiesce is actually quiescent.  Data checksums are left at their
# default (enabled); the no-masking-of-hint-bits policy above depends on it.
my $primary = PostgreSQL::Test::Cluster->new('primary');
$primary->init(allows_streaming => 1);
$primary->append_conf('postgresql.conf', <<EOF);
summarize_wal = on
autovacuum = off
# keep all WAL so pg_waldump can audit the final backup window
wal_keep_size = '1GB'
EOF
$primary->start;

ok( $primary->safe_psql('postgres', 'SHOW data_checksums') eq 'on',
	'data checksums are enabled (hint bit writes are WAL-logged)');

# Seed workload: a heap with indexes fed by a sequence, a TOAST-heavy table,
# a table whose VM bits will be set and cleared repeatedly, a table for bulk
# COPY extension, a table that gets truncated and re-extended, and an
# unlogged table (so that an init fork is part of the comparison).
$primary->safe_psql('postgres', <<'EOSQL');
CREATE SEQUENCE heap_seq;
CREATE TABLE t_heap (id bigint PRIMARY KEY DEFAULT nextval('heap_seq'),
                     grp int, val text);
INSERT INTO t_heap (grp, val)
    SELECT g % 100, 'seed-' || g FROM generate_series(1, 20000) g;
CREATE INDEX t_heap_grp_idx ON t_heap (grp);

CREATE TABLE t_toast (id int PRIMARY KEY, big text);
INSERT INTO t_toast
    SELECT g, (SELECT string_agg(md5(g::text || s::text), '')
               FROM generate_series(1, 300) s)
    FROM generate_series(1, 20) g;

CREATE TABLE t_vm (id int, val text);
INSERT INTO t_vm SELECT g, 'vm-' || g FROM generate_series(1, 5000) g;
VACUUM (FREEZE) t_vm;

CREATE TABLE t_copy (id bigint);
CREATE TABLE t_trunc (id int, val text);
INSERT INTO t_trunc SELECT g, 'tr-' || g FROM generate_series(1, 5000) g;

CREATE UNLOGGED TABLE t_unlogged (id int, val text);
INSERT INTO t_unlogged SELECT g, 'ul-' || g FROM generate_series(1, 1000) g;

CREATE TABLE t_dropped AS
    SELECT g AS id, 'drop-' || g AS val FROM generate_series(1, 2000) g;
EOSQL

my $backup_dir = $primary->backup_dir;

# Take the full backup F0 that anchors the incremental chain.
my $f0_path = $backup_dir . '/f0';
$primary->command_ok(
	[
		'pg_basebackup', '--no-sync',
		'--pgdata' => $f0_path,
		'--checkpoint' => 'fast',
	],
	'full backup F0');

# Helper: run a churn script in a background session, concurrently with a
# foreground action (an incremental backup).  The DO block is submitted
# asynchronously; \echo output tells us it has started.  After the
# foreground action completes we synchronize on a trivial query, which can
# only run once the DO block has finished.
my $bg = $primary->background_psql('postgres');

sub churn_concurrently_with
{
	my ($phase, $churn_sql, $action) = @_;

	$bg->query_until(
		qr/${phase}_started/, qq{\\echo ${phase}_started
$churn_sql
});
	$action->();
	my $sync = $bg->query_safe(qq{SELECT '${phase}_synced'});
	like($sync, qr/${phase}_synced/, "$phase churn completed");
	return;
}

# Phase 1 churn: scattered updates, inserts and deletes on the heap, TOAST
# value rewrites.  Runs concurrently with incremental backup I1.
my $phase1_churn = <<'EOSQL';
DO $$
DECLARE i int;
BEGIN
    FOR i IN 1..40 LOOP
        UPDATE t_heap SET val = val || 'x' WHERE grp = (i * 7) % 100;
        INSERT INTO t_heap (grp, val)
            SELECT (i * 13 + g) % 100, 'p1-' || i
            FROM generate_series(1, 100) g;
        DELETE FROM t_heap
            WHERE grp = (i * 11) % 100 AND id % 5 = i % 5;
        UPDATE t_toast SET big = md5(i::text) || big
            WHERE id = (i % 20) + 1;
        COMMIT;
        PERFORM pg_sleep(0.05);
    END LOOP;
END
$$;
EOSQL

my $i1_path = $backup_dir . '/i1';
churn_concurrently_with(
	'phase1',
	$phase1_churn,
	sub {
		$primary->command_ok(
			[
				'pg_basebackup', '--no-sync',
				'--pgdata' => $i1_path,
				'--checkpoint' => 'fast',
				# rate-limit so the backup genuinely overlaps the churn
				'--max-rate' => '4M',
				'--incremental' => $f0_path . '/backup_manifest',
			],
			'incremental backup I1 (concurrent churn)');
	});

# Interlude between I1 and I2: set and clear VM bits, bulk COPY extension,
# TRUNCATE and re-extend, index creation.
$primary->safe_psql('postgres',
	"COPY t_copy FROM STDIN;\n" . join("\n", 1 .. 60000) . "\n\\.\n");
$primary->safe_psql('postgres', <<'EOSQL');
DELETE FROM t_vm WHERE id % 7 = 0;
VACUUM t_vm;
VACUUM (FREEZE) t_heap;
TRUNCATE t_trunc;
INSERT INTO t_trunc SELECT g, 'tr2-' || g FROM generate_series(1, 8000) g;
CREATE INDEX t_trunc_idx ON t_trunc (id);
EOSQL

# Phase 2 churn: operations that clear freshly-set VM bits (the historical
# summarizer blind spot): updates, deletes, tuple locks, plus more heap and
# TOAST churn.  Runs concurrently with incremental backup I2.
my $phase2_churn = <<'EOSQL';
DO $$
DECLARE i int;
BEGIN
    FOR i IN 1..40 LOOP
        UPDATE t_vm SET val = val || 'y' WHERE id % 97 = i;
        DELETE FROM t_vm WHERE id % 89 = i;
        PERFORM * FROM t_heap WHERE grp = (i * 3) % 100 FOR UPDATE;
        UPDATE t_heap SET val = 'p2-' || i WHERE grp = (i * 17) % 100;
        INSERT INTO t_copy SELECT g FROM generate_series(1, 200) g;
        UPDATE t_toast SET big = big || md5((i * 31)::text)
            WHERE id = (i % 20) + 1;
        COMMIT;
        PERFORM pg_sleep(0.05);
    END LOOP;
END
$$;
EOSQL

my $i2_path = $backup_dir . '/i2';
churn_concurrently_with(
	'phase2',
	$phase2_churn,
	sub {
		$primary->command_ok(
			[
				'pg_basebackup', '--no-sync',
				'--pgdata' => $i2_path,
				'--checkpoint' => 'fast',
				# rate-limit so the backup genuinely overlaps the churn
				'--max-rate' => '4M',
				'--incremental' => $i1_path . '/backup_manifest',
			],
			'incremental backup I2 (concurrent churn)');
	});

# Post-I2 activity: index churn, more VM cycling, unlogged churn, and a
# table drop, all of which land in the final incremental I3.
$primary->safe_psql('postgres', <<'EOSQL');
DROP INDEX t_heap_grp_idx;
CREATE INDEX t_heap_grp_idx2 ON t_heap (grp);
DELETE FROM t_vm WHERE id % 11 = 0;
VACUUM (FREEZE) t_vm;
TRUNCATE t_unlogged;
INSERT INTO t_unlogged SELECT g, 'ul2-' || g FROM generate_series(1, 1000) g;
DROP TABLE t_dropped;
EOSQL

# End of workload.
$bg->quit;

# Quiesce and take the final backup pair: incremental I3 (completing the
# chain) and reference full backup R, back to back.  Both must capture the
# identical set of relation blocks.  The settle sequence makes the cluster
# truly quiescent: VACUUM sets hint bits and VM bits everywhere and
# reconciles catalogs, the SELECT sweep sets hint bits on the tuples the
# VACUUM itself created, and CHECKPOINT flushes everything so that nothing
# is left for a later checkpoint (e.g. R's own start checkpoint) to write.
#
# Even so, we verify rather than hope: any WAL record carrying a block
# reference between the start of I3 and the end of R means a relation page
# may have changed between the two backups, invalidating the comparison.
# In that case the pair is retaken.
my $settle_sweep = q{
SELECT count(*) FROM pg_class;
SELECT count(*) FROM pg_attribute;
SELECT count(*) FROM pg_type;
SELECT count(*) FROM pg_index;
SELECT count(*) FROM pg_depend;
SELECT count(*) FROM pg_shdepend;
SELECT count(*) FROM pg_database;
SELECT count(*) FROM pg_authid;
SELECT count(*) FROM pg_auth_members;
SELECT count(*) FROM pg_statistic;
SELECT count(*) FROM pg_sequence;
SELECT count(*) FROM t_heap;
SELECT count(*) FROM t_toast;
SELECT count(*) FROM t_vm;
SELECT count(*) FROM t_copy;
SELECT count(*) FROM t_trunc;
SELECT count(*) FROM t_unlogged;
};

sub insert_lsn
{
	return $primary->safe_psql('postgres',
		'SELECT pg_current_wal_insert_lsn()');
}

sub parse_lsn
{
	my ($lsn) = @_;
	my ($hi, $lo) = split m{/}, $lsn;
	return (hex($hi) << 32) + hex($lo);
}

my $max_attempts = 3;
my ($i3_path, $r_path);
my $accepted = 0;

for my $attempt (1 .. $max_attempts)
{
	$primary->safe_psql('postgres', 'VACUUM');
	$primary->safe_psql('postgres', $settle_sweep);
	$primary->safe_psql('postgres', 'CHECKPOINT');

	my $lsn_start = insert_lsn();

	$i3_path = $backup_dir . "/i3_attempt$attempt";
	$primary->command_ok(
		[
			'pg_basebackup', '--no-sync',
			'--pgdata' => $i3_path,
			'--checkpoint' => 'fast',
			'--incremental' => $i2_path . '/backup_manifest',
		],
		"final incremental backup I3 (attempt $attempt)");

	my $lsn_mid = insert_lsn();

	$r_path = $backup_dir . "/r_attempt$attempt";
	$primary->command_ok(
		[
			'pg_basebackup', '--no-sync',
			'--pgdata' => $r_path,
			'--checkpoint' => 'fast',
		],
		"reference full backup R (attempt $attempt)");

	my $lsn_end = insert_lsn();

	note "attempt $attempt: I3 window start $lsn_start, "
	  . "between backups $lsn_mid, after R $lsn_end";

	# The backup-end WAL switch leaves the insert LSN pointing into a
	# segment whose file may not exist yet.  Write and flush one trivial
	# record just past the audited window: it materializes that segment
	# and serves as a coverage sentinel proving pg_waldump really read
	# through $lsn_end.
	$primary->safe_psql('postgres', 'SELECT txid_current()');

	# Backups themselves emit WAL (checkpoint and backup-end records), so
	# the insert LSN moving is expected; what must NOT appear in this
	# window is any record referencing a relation block.  pg_waldump is
	# run without --end (an end LSN exactly at a segment boundary confuses
	# its page reader) and always terminates with an end-of-WAL error;
	# instead, we require that the records it printed reach $lsn_end.
	my ($wal_out, $wal_err) = run_command(
		[
			'pg_waldump',
			'--path' => $primary->data_dir . '/pg_wal',
			'--start' => $lsn_start,
		]);

	my $end_n = parse_lsn($lsn_end);
	my $max_n = 0;
	my @blkref_lines;
	foreach my $line (split /\n/, $wal_out)
	{
		next unless $line =~ m{lsn: ([0-9A-Fa-f]+/[0-9A-Fa-f]+), prev};
		my $n = parse_lsn($1);
		$max_n = $n if $n > $max_n;
		push @blkref_lines, $line if $n < $end_n && $line =~ /blkref/;
	}

	if (@blkref_lines)
	{
		diag "attempt $attempt: relation blocks referenced in WAL "
		  . "between final backups; not quiescent:";
		diag join("\n",
			@blkref_lines[ 0 .. ($#blkref_lines > 9 ? 9 : $#blkref_lines) ]);
	}
	elsif ($max_n < $end_n)
	{
		diag "attempt $attempt: pg_waldump did not cover the full window "
		  . "(reached " . sprintf('%X/%08X', $max_n >> 32, $max_n & 0xFFFFFFFF)
		  . ", needed $lsn_end): $wal_err";
	}
	else
	{
		$accepted = 1;
		ok(1, "final backup pair captured identical cluster state "
			  . "(attempt $attempt)");
		last;
	}
}

ok($accepted,
	"quiescent final backup pair obtained within $max_attempts attempts")
  or die 'cannot obtain a quiescent reference point, aborting';

# Map relfilenode paths to relation names for better diagnostics.
my %relname_by_path;
{
	my $rows = $primary->safe_psql('postgres',
		q{SELECT pg_relation_filepath(oid), relname
		  FROM pg_class WHERE pg_relation_filepath(oid) IS NOT NULL});
	foreach my $row (split /\n/, $rows)
	{
		my ($path, $name) = split /\|/, $row;
		$relname_by_path{$path} = $name;
	}
}

$primary->stop;

# Reconstruct the combined backup C = F0 + I1 + I2 + I3.
my $c_path = $backup_dir . '/combined';
$primary->command_ok(
	[
		'pg_combinebackup', $mode, '--no-sync',
		'--output' => $c_path,
		$f0_path, $i1_path, $i2_path, $i3_path,
	],
	'pg_combinebackup reconstructs the chain');

#
# Physical comparison of C against R.
#

# Return a hash of relation data files (relative paths) under base/ and
# global/ in a backup directory: main, _vm and _init forks, including
# extra segment files; _fsm is excluded by design (not fully WAL-logged).
sub collect_relation_files
{
	my ($root) = @_;
	my %files;
	my @dirs = ('global');
	if (-d "$root/base")
	{
		push @dirs, map { "base/$_" } grep { /^\d+$/ } slurp_dir("$root/base");
	}
	foreach my $dir (@dirs)
	{
		next unless -d "$root/$dir";
		foreach my $f (slurp_dir("$root/$dir"))
		{
			next unless $f =~ /^\d+(?:_(vm|init|fsm))?(?:\.\d+)?$/;
			my $fork = $1 // 'main';
			next if $fork eq 'fsm';
			$files{"$dir/$f"} = 1;
		}
	}
	return \%files;
}

# Describe the divergence within one block: the differing byte ranges
# (computed on the masked images, so pd_lsn/pd_checksum noise is excluded)
# with hex dumps of the raw bytes.
sub describe_block_diff
{
	my ($rel, $relname, $blkno, $cbuf, $rbuf, $cmask, $rmask) = @_;

	my $absblk = $blkno;
	$absblk += $1 * RELSEG_SIZE if $rel =~ /\.(\d+)$/;

	my $msg = "DIVERGENCE: $rel ($relname) block $absblk:";
	my $xor = $cmask ^ $rmask;
	my $nranges = 0;
	while ($xor =~ /[^\0]+/g)
	{
		my ($s, $e) = ($-[0], $+[0] - 1);
		my $len = $e - $s + 1;
		my $show = $len > 16 ? 16 : $len;
		$msg .= sprintf(
			"\n  bytes %d..%d differ; combined=%s%s reference=%s%s",
			$s, $e,
			unpack('H*', substr($cbuf, $s, $show)),
			$len > $show ? '...' : '',
			unpack('H*', substr($rbuf, $s, $show)),
			$len > $show ? '...' : '');
		last if ++$nranges >= 5;
	}
	return $msg;
}

sub compare_relation_file
{
	my ($c_file, $r_file, $rel, $relname, $reports, $stats) = @_;

	open my $cf, '<:raw', $c_file or die "open $c_file: $!";
	open my $rf, '<:raw', $r_file or die "open $r_file: $!";
	my $c_size = -s $cf;
	my $r_size = -s $rf;
	my $ndiv = 0;

	if ($c_size != $r_size)
	{
		$ndiv++;
		push @$reports,
		  "DIVERGENCE: $rel ($relname): size mismatch: "
		  . "combined $c_size vs reference $r_size bytes";
	}

	my $minsize = $c_size < $r_size ? $c_size : $r_size;
	my $nblocks = int($minsize / BLCKSZ);
	for my $blk (0 .. $nblocks - 1)
	{
		my ($cbuf, $rbuf);
		read($cf, $cbuf, BLCKSZ) == BLCKSZ or die "short read: $c_file";
		read($rf, $rbuf, BLCKSZ) == BLCKSZ or die "short read: $r_file";
		$stats->{blocks}++;
		next if $cbuf eq $rbuf;

		my ($cmask, $rmask) = ($cbuf, $rbuf);
		substr($cmask, 0, MASKED_HEADER_BYTES) = "\0" x MASKED_HEADER_BYTES;
		substr($rmask, 0, MASKED_HEADER_BYTES) = "\0" x MASKED_HEADER_BYTES;
		if ($cmask eq $rmask)
		{
			$stats->{lsn_only}++;
			next;
		}

		$ndiv++;
		push @$reports,
		  describe_block_diff($rel, $relname, $blk, $cbuf, $rbuf,
			$cmask, $rmask)
		  if @$reports < 50;
	}
	close $cf;
	close $rf;
	return $ndiv;
}

my $c_files = collect_relation_files($c_path);
my $r_files = collect_relation_files($r_path);

my @only_c = grep { !$r_files->{$_} } sort keys %$c_files;
my @only_r = grep { !$c_files->{$_} } sort keys %$r_files;
is(scalar(@only_c) + scalar(@only_r),
	0, 'combined and reference backups contain the same relation files')
  or diag "only in combined: @only_c\nonly in reference: @only_r";

my @common = sort grep { $r_files->{$_} } keys %$c_files;
my %stats = (blocks => 0, lsn_only => 0);
my @reports;
my $ndivergent = 0;

foreach my $rel (@common)
{
	(my $base = $rel) =~ s/_(?:vm|init)//;
	$base =~ s/\.\d+$//;
	my $relname = $relname_by_path{$base} // '?';
	$ndivergent += compare_relation_file("$c_path/$rel", "$r_path/$rel",
		$rel, $relname, \@reports, \%stats);
}

# Guard against the oracle trivially passing because it looked at nothing.
cmp_ok(scalar(@common), '>', 20,
	'compared a meaningful number of relation files (' . scalar(@common) . ')');
cmp_ok($stats{blocks}, '>', 500,
	"compared a meaningful number of blocks ($stats{blocks})");

is($ndivergent, 0,
	'combined backup is block-identical to reference full backup '
	  . "($stats{blocks} blocks in " . scalar(@common) . ' files)')
  or diag join("\n", @reports);
note "$stats{lsn_only} block(s) differed only in masked pd_lsn/pd_checksum"
  if $stats{lsn_only};

done_testing();
