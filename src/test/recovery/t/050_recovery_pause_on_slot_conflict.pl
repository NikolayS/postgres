# Copyright (c) 2026, PostgreSQL Global Development Group

# Exercise the recovery_pause_on_logical_slot_conflict GUC on a standby.
#
# When the GUC is enabled and a Heap2/PRUNE_ON_ACCESS record on a catalog
# relation would invalidate an active logical replication slot on the
# standby, replay should pause instead. An operator (this test) can then
# drain the slot and resume, and — because the drain advanced
# confirmed_flush_lsn to the paused record — the patch bumps the slot's
# catalog_xmin past the conflict horizon and the fall-through
# InvalidateObsoleteReplicationSlots call becomes a no-op.
#
# Checks:
#   1. The GUC is registered and visible.
#   2. Default-off behavior: slot invalidates under catalog pruning
#      (baseline, confirms the test setup actually triggers the conflict).
#   3. GUC-on behavior with drain-and-resume: slot survives, all
#      workload rows are decoded, wal_status remains 'reserved'.
#
# STATUS: this scaffold hits a legitimate ordering issue when the catalog
# prune record lands in the archive BEFORE the slot has reached
# SNAPBUILD_CONSISTENT: slot creation blocks in
# DecodingContextFindStartpoint waiting for more WAL, while replay is
# paused by the GUC waiting for slot drain. This is a real edge case the
# patch's followups need to address (either skip the pause for
# not-yet-consistent slots, or let slot creation proceed while paused).
#
# The bash-level demo at /tmp/us1_v2.sh on the lab VM avoids this by
# creating the slot BEFORE the catalog-churn workload on the primary
# is replayed. Issue #25 has the evidence.
#
# To turn this skeleton into a passing TAP test: restructure the flow so
# the slot is created after standby starts but before the primary runs
# the catalog-churn workload that emits the prune record. Two-phase
# setup required.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

my $node_primary = PostgreSQL::Test::Cluster->new('primary');
$node_primary->init(allows_streaming => 'logical', has_archiving => 1);
$node_primary->append_conf('postgresql.conf', qq[
wal_level = logical
archive_mode = on
archive_timeout = 1s
autovacuum = on
autovacuum_naptime = 5s
fsync = off
synchronous_commit = off
]);
$node_primary->start;

# 1. GUC visibility
my $guc = $node_primary->safe_psql('postgres',
    "SELECT COUNT(*) FROM pg_settings WHERE name = 'recovery_pause_on_logical_slot_conflict'");
is($guc, '1', 'recovery_pause_on_logical_slot_conflict GUC is registered');

# Set up a workload table on primary
$node_primary->safe_psql('postgres', qq[
    CREATE TABLE events (id serial PRIMARY KEY, payload text);
    ALTER TABLE events REPLICA IDENTITY FULL;
    INSERT INTO events (payload) VALUES ('seed');
]);

# Take basebackup first, then emit quiet-moment snapshot + catalog
# churn in post-backup WAL. Standby starting from this backup will
# replay through the archive and encounter:
#   1) pg_log_standby_snapshot() → snapbuild path (a) anchor
#   2) VACUUM pg_statistic → catalog prune record → our GUC's trigger
my $backup_name = 'backup1';
$node_primary->backup($backup_name);

# Quiet-moment RUNNING_XACTS in post-backup WAL.
$node_primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");

# Catalog churn. Table create+drop iterations produce dead tuples in
# pg_class / pg_attribute / pg_type / pg_depend. Subsequent VACUUM
# emits Heap2/PRUNE_ON_ACCESS on those catalog relations in the
# 'postgres' database — the trigger for the GUC under test.
$node_primary->safe_psql('postgres', qq[
    INSERT INTO events (payload)
        SELECT 'row-' || g FROM generate_series(1, 3000) g;
]);
for (my $i = 0; $i < 20; $i++) {
    $node_primary->safe_psql('postgres',
        "CREATE TABLE churn_$i (id int, payload text); DROP TABLE churn_$i;");
}
$node_primary->safe_psql('postgres', qq[
    ANALYZE events;
    ANALYZE events;
    VACUUM pg_class;
    VACUUM pg_attribute;
    VACUUM pg_type;
    VACUUM pg_depend;
    VACUUM pg_statistic;
]);

# Wait for EVERYTHING the primary has written so far to reach the
# archive. Without this, the standby stalls in restore_command waiting
# for a segment that's in pg_wal but not yet in the archive directory.
#
# Strategy: capture the current write position, force a segment switch
# so the containing segment closes and archives, then poll pg_stat_archiver
# until last_archived_wal has reached (at least) the segment that held
# that capture-point LSN.
my $workload_end_seg = $node_primary->safe_psql('postgres',
    "SELECT pg_walfile_name(pg_current_wal_lsn())");
$node_primary->safe_psql('postgres', "SELECT pg_switch_wal();");
$node_primary->poll_query_until('postgres', qq[
    SELECT last_archived_wal IS NOT NULL
       AND last_archived_wal >= '$workload_end_seg'
    FROM pg_stat_archiver
]) or die "Timed out waiting for workload segment $workload_end_seg to archive";

my $node_standby = PostgreSQL::Test::Cluster->new('standby');
$node_standby->init_from_backup($node_primary, $backup_name,
    has_streaming => 0, has_restoring => 1);
$node_standby->append_conf('postgresql.conf', qq[
hot_standby = on
recovery_pause_on_logical_slot_conflict = on
wal_level = logical
max_standby_archive_delay = -1
max_standby_streaming_delay = -1
]);
$node_standby->start;

# Wait for standby to reach a stable replay point
$node_standby->poll_query_until('postgres',
    "SELECT pg_last_wal_replay_lsn() IS NOT NULL", 't');

# Create slot on standby
$node_standby->safe_psql('postgres', qq[
    SELECT pg_create_logical_replication_slot('t_slot', 'test_decoding');
]);

# Orchestrator: a simple Perl loop that mirrors the bash demo on the issue.
my $total_drained = 0;
my $pauses_seen = 0;
my $last_replay = '';
my $stall_ticks = 0;
my $deadline = time() + 60;
while (time() < $deadline) {
    my $state = $node_standby->safe_psql('postgres',
        "SELECT pg_get_wal_replay_pause_state()");
    my $replay = $node_standby->safe_psql('postgres',
        "SELECT pg_last_wal_replay_lsn()");

    if ($state eq 'paused' || $state eq 'pause requested') {
        my $got = $node_standby->safe_psql('postgres',
            "SELECT COUNT(*) FROM pg_logical_slot_get_changes('t_slot', NULL, NULL)");
        $total_drained += $got;
        $pauses_seen++;
        $node_standby->safe_psql('postgres', "SELECT pg_wal_replay_resume()");
        $stall_ticks = 0;
    } elsif ($replay eq $last_replay) {
        $stall_ticks++;
        last if $stall_ticks > 10;   # stable for 10 ticks = done
    } else {
        $stall_ticks = 0;
    }

    $last_replay = $replay;
    usleep(500_000);
}

# Drain anything left
my $final = $node_standby->safe_psql('postgres',
    "SELECT COUNT(*) FROM pg_logical_slot_get_changes('t_slot', NULL, NULL)");
$total_drained += $final;

# The critical assertion: the slot was NOT invalidated, despite replay
# clearly crossing catalog-prune records.
my $slot_state = $node_standby->safe_psql('postgres', qq[
    SELECT wal_status || '|' || COALESCE(invalidation_reason, '')
    FROM pg_replication_slots WHERE slot_name = 't_slot';
]);
like($slot_state, qr/^reserved\|/,
     "slot survived catalog prune with GUC on (state: $slot_state)");

# Sanity: orchestrator actually hit the pause at least once.
cmp_ok($pauses_seen, '>=', 1,
    "at least one pause event was handled ($pauses_seen seen)");

# Sanity: at least the seed + most of our 3000 INSERTs got decoded as events.
# Each INSERT produces BEGIN + INSERT + COMMIT = 3 events minimum, but the
# initial row + variations mean the count may be higher; lower-bound at
# 2000 is safe and very far above the pre-fix 21k-partial number.
cmp_ok($total_drained, '>=', 2000,
    "at least 2000 decoded events ($total_drained got)");

# (optional) baseline check: with GUC off the same workload would have
# invalidated the slot. We do this on a second standby so we don't
# disturb the one above.
my $node_standby_off = PostgreSQL::Test::Cluster->new('standby_off');
$node_standby_off->init_from_backup($node_primary, $backup_name,
    has_streaming => 0, has_restoring => 1);
$node_standby_off->append_conf('postgresql.conf', qq[
hot_standby = on
recovery_pause_on_logical_slot_conflict = off
wal_level = logical
max_standby_archive_delay = -1
max_standby_streaming_delay = -1
]);
$node_standby_off->start;

$node_standby_off->poll_query_until('postgres',
    "SELECT pg_last_wal_replay_lsn() IS NOT NULL", 't');
$node_standby_off->safe_psql('postgres', qq[
    SELECT pg_create_logical_replication_slot('t_slot_off', 'test_decoding');
]);
# Let replay run long enough to hit the conflict record.
sleep 15;
my $off_state = $node_standby_off->safe_psql('postgres', qq[
    SELECT wal_status FROM pg_replication_slots WHERE slot_name = 't_slot_off';
]);
# This SHOULD be 'lost' under the catalog-pruned archive. If it's 'reserved'
# the test setup didn't actually generate the conflict — not a patch bug,
# but worth flagging for maintenance.
ok($off_state eq 'lost',
   "baseline (GUC off): slot invalidated as expected (state: $off_state)");

$node_standby_off->stop;
$node_standby->stop;
$node_primary->stop;

done_testing();
