# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Negative control for the physical-consistency oracle used by
# 002_compare_backups.pl and 012_vm_consistency.pl (CombineBackupTest.pm):
# prove that the checks really do fire on a corrupted cluster. Restore a
# combined (full + incremental) backup into a scratch cluster, verify the
# oracle passes there, then fabricate stale all-visible/all-frozen bits by
# writing directly into the table's visibility map fork and assert that
# both the pg_visibility sweep and the index-only-scan-vs-seqscan
# comparison detect the damage. Finally, overwrite part of a btree page
# and assert that pg_amcheck detects that as well.
#
# Only the scratch restored cluster is ever corrupted; nothing here
# touches the clusters used for real comparisons in the other tests.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use CombineBackupTest;

my $mode = $ENV{PG_TEST_PG_COMBINEBACKUP_MODE} || '--copy';

note "testing using mode $mode";

# Data checksums must be disabled: we fabricate stale VM bits by writing
# directly into the VM fork without recomputing page checksums, which is
# also how a hypothetical pg_combinebackup bug would manifest (a valid
# page image whose bits are simply wrong).
my $primary = PostgreSQL::Test::Cluster->new('primary');
$primary->init(allows_streaming => 1, no_data_checksums => 1);
$primary->append_conf('postgresql.conf', <<EOF);
summarize_wal = on
autovacuum = off
EOF
$primary->start;

# A thousand rows, vacuum-frozen so the VM bits are set and an index-only
# scan will consult them. Table t is the corruption target; t_control is
# an identical table used for the intact-cluster sanity checks. The two
# must be distinct: an index(-only) scan over t before its VM is
# corrupted would heap-fetch the dead tuples and set LP_DEAD kill bits on
# their index entries, after which later index-only scans would skip them
# regardless of the (corrupted) visibility map.
$primary->safe_psql('postgres', q{
	CREATE TABLE t (id int PRIMARY KEY, val text);
	INSERT INTO t SELECT g, 'row ' || g FROM generate_series(1, 1000) g;
	VACUUM (FREEZE) t;
	CREATE TABLE t_control (id int PRIMARY KEY, val text);
	INSERT INTO t_control SELECT g, 'row ' || g FROM generate_series(1, 1000) g;
	VACUUM (FREEZE) t_control;
});

# Take a full backup.
my $full_path = $primary->backup_dir . '/full';
$primary->command_ok(
	[
		'pg_basebackup', '--no-sync',
		'--pgdata' => $full_path,
		'--checkpoint' => 'fast',
	],
	'full backup');

# Delete some rows, clearing the VM bits of every affected heap page and
# leaving dead tuples behind that are still present in the index. The
# "% 10" predicate is not indexable, so this cannot set index kill bits.
$primary->safe_psql('postgres', 'DELETE FROM t WHERE id % 10 = 0');
$primary->safe_psql('postgres', 'DELETE FROM t_control WHERE id % 10 = 0');

# Take an incremental backup containing those changes.
my $incr_path = $primary->backup_dir . '/incr';
$primary->command_ok(
	[
		'pg_basebackup', '--no-sync',
		'--pgdata' => $incr_path,
		'--checkpoint' => 'fast',
		'--incremental' => $full_path . '/backup_manifest',
	],
	'incremental backup');

# Restore the combined backup into a scratch cluster.
my $restored = PostgreSQL::Test::Cluster->new('restored');
$restored->init_from_backup(
	$primary, 'incr',
	combine_with_prior => ['full'],
	combine_mode => $mode);
$restored->append_conf('postgresql.conf', 'autovacuum = off');
$restored->start;

# Sanity check: on the intact restored cluster, the oracle passes. Note
# that the index-only-scan check runs on t_control, not t, to avoid
# setting index kill bits on t (see above).
is(vm_sweep_errors($restored, 'postgres'),
	'', 'no stale VM bits on intact restored cluster');
my ($ios_plan, $ios_result, $seq_result) =
  ios_vs_seqscan($restored, 'postgres', 't_control', 'id');
like(
	$ios_plan,
	qr/Index Only Scan/,
	'aggregate query uses an index-only scan when forced');
is($ios_result, $seq_result,
	'index-only scan and seqscan agree on intact restored cluster');

# Now fabricate stale VM bits: mark the first 16 heap pages all-visible
# and all-frozen by setting the first four bytes of the VM data area
# (which follows the standard 24-byte page header). The table's heap is
# smaller than 16 pages, so this covers every page, including the ones
# holding dead tuples.
my $relpath =
  $restored->safe_psql('postgres', "SELECT pg_relation_filepath('t')");
my $vmfile = $restored->data_dir . '/' . $relpath . '_vm';
ok(-f $vmfile, 'visibility map fork exists');

$restored->stop;
open my $vmfh, '+<:raw', $vmfile or die "open $vmfile: $!";
seek($vmfh, 24, 0) or die "seek $vmfile: $!";
print $vmfh "\xff" x 4;
close $vmfh or die "close $vmfile: $!";
$restored->start;

# The pg_visibility sweep must now report corruption ...
my $vm_errors = vm_sweep_errors($restored, 'postgres');
isnt($vm_errors, '', 'pg_visibility sweep detects the stale VM bits');
note "vm sweep reported: $vm_errors";

# ... and the index-only scan must diverge from the seqscan, since it
# now trusts all-visible bits covering dead tuples.
($ios_plan, $ios_result, $seq_result) =
  ios_vs_seqscan($restored, 'postgres', 't', 'id');
isnt($ios_result, $seq_result,
	'index-only scan diverges from seqscan with stale VM bits');
note "index-only scan returned [$ios_result], seqscan [$seq_result]";

# Also prove the pg_amcheck leg of the oracle: overwrite part of a btree
# page and assert pg_amcheck fails. (pg_amcheck by itself does not detect
# stale VM bits, which is why the pg_visibility sweep above is needed.)
my $idxpath =
  $restored->safe_psql('postgres', "SELECT pg_relation_filepath('t_pkey')");
my $idxfile = $restored->data_dir . '/' . $idxpath;

$restored->stop;
open my $idxfh, '+<:raw', $idxfile or die "open $idxfile: $!";
seek($idxfh, 8192 + 100, 0) or die "seek $idxfile: $!";
print $idxfh "\xde\xad\xbe\xef" x 25;
close $idxfh or die "close $idxfile: $!";
$restored->start;

$restored->command_fails(
	[ 'pg_amcheck', '--all', '--install-missing', '--heapallindexed' ],
	'pg_amcheck detects the corrupted btree page');

$restored->stop;
$primary->stop;

done_testing();
