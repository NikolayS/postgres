# Copyright (c) 2026, PostgreSQL Global Development Group

# Exercise the recovery_pause_on_logical_slot_conflict GUC on a standby.
#
# Two-phase flow so the slot is fully consistent BEFORE any catalog-
# prune WAL record is replayed — otherwise slot creation would block
# inside DecodingContextFindStartpoint while replay pauses on the
# prune, and we would deadlock. (Fix #1, bbd5d4e13bc, narrows the
# window but doesn't remove it; keeping the two-phase flow explicit
# makes the test robust.)
#
# Phase 1 — bring up a consistent logical slot on the standby from a
# quiet primary archive:
#   * take basebackup
#   * pg_log_standby_snapshot() → snapbuild path (a) anchor
#   * wait for the snapshot's segment to archive
#   * start standby, let replay catch up, create slot (quick — no
#     prune records in the archive yet).
#
# Phase 2 — churn the primary's catalog so the standby's replay
# eventually hits a catalog-prune record that would invalidate the
# slot:
#   * run CREATE / DROP of transient tables (pg_class churn)
#   * run ANALYZE x2 + VACUUM pg_statistic / pg_class (HOT prune on
#     catalog relations in db=postgres)
#   * wait for those segments to archive
#   * orchestrator loop on the standby: when
#     pg_get_wal_replay_pause_state() returns paused, drain the slot
#     via pg_logical_slot_get_changes, call pg_wal_replay_resume,
#     continue.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

# Build the primary, seed the workload table, take a basebackup, and
# produce a "clean" archive: one that contains a standby snapshot but
# no catalog-prune WAL yet. Returns ($node_primary, $backup_name).
sub setup_primary_with_clean_archive
{
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

    $node_primary->safe_psql('postgres', qq[
        CREATE TABLE events (id serial PRIMARY KEY, payload text);
        ALTER TABLE events REPLICA IDENTITY FULL;
        INSERT INTO events (payload) VALUES ('seed');
    ]);

    my $backup_name = 'backup1';
    $node_primary->backup($backup_name);

    # Quiet-moment RUNNING_XACTS in post-backup WAL — provides path (a)
    # anchor for snapbuild.
    $node_primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");

    # Force the segment containing that anchor to archive so the standby
    # can see it via restore_command. Switch TWICE: first switch closes
    # the segment with the snapshot record; second switch gives
    # snapbuild the forward WAL it needs to decide the slot is
    # consistent. Without the second switch,
    # DecodingContextFindStartpoint blocks on 'waiting for WAL to
    # become available at seg N+1' — flaky slot creation.
    my $phase1_seg = $node_primary->safe_psql('postgres',
        "SELECT pg_walfile_name(pg_current_wal_lsn())");
    $node_primary->safe_psql('postgres', "SELECT pg_switch_wal();");
    $node_primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");
    $node_primary->safe_psql('postgres', "SELECT pg_switch_wal();");
    $node_primary->poll_query_until('postgres', qq[
        SELECT last_archived_wal IS NOT NULL
           AND last_archived_wal >= '$phase1_seg'
        FROM pg_stat_archiver
    ]) or die "Timed out waiting for phase-1 segment $phase1_seg to archive";

    return ($node_primary, $backup_name);
}

# Bring up an archive-only standby from $backup_name on $node_primary
# with recovery_pause_on_logical_slot_conflict set to $guc_value. Waits
# for replay to catch up, then returns the node.
sub create_archive_standby
{
    my ($node_primary, $backup_name, $name, $guc_value) = @_;

    my $standby = PostgreSQL::Test::Cluster->new($name);
    $standby->init_from_backup($node_primary, $backup_name,
        has_streaming => 0, has_restoring => 1);
    $standby->append_conf('postgresql.conf', qq[
hot_standby = on
recovery_pause_on_logical_slot_conflict = $guc_value
wal_level = logical
max_standby_archive_delay = -1
max_standby_streaming_delay = -1
]);
    $standby->start;
    $standby->poll_query_until('postgres',
        "SELECT pg_last_wal_replay_lsn() IS NOT NULL", 't');

    return $standby;
}

# Churn the primary's catalog enough to emit catalog-prune WAL records,
# then force and wait for those records to reach the archive.
sub run_catalog_churn
{
    my ($node_primary) = @_;

    # Transient tables exercise pg_class / pg_attribute / pg_type / pg_depend.
    $node_primary->safe_psql('postgres', qq[
        INSERT INTO events (payload)
            SELECT 'row-' || g FROM generate_series(1, 3000) g;
    ]);
    for (my $i = 0; $i < 20; $i++) {
        $node_primary->safe_psql('postgres',
            "CREATE TABLE churn_$i (id int, payload text); DROP TABLE churn_$i;");
    }
    # Two ANALYZE calls make first-generation pg_statistic rows dead by
    # overwriting them; VACUUM then emits Heap2/PRUNE_ON_ACCESS.
    $node_primary->safe_psql('postgres', qq[
        ANALYZE events;
        ANALYZE events;
        VACUUM pg_class;
        VACUUM pg_attribute;
        VACUUM pg_type;
        VACUUM pg_depend;
        VACUUM pg_statistic;
    ]);

    my $phase2_seg = $node_primary->safe_psql('postgres',
        "SELECT pg_walfile_name(pg_current_wal_lsn())");
    $node_primary->safe_psql('postgres', "SELECT pg_switch_wal();");
    $node_primary->poll_query_until('postgres', qq[
        SELECT last_archived_wal IS NOT NULL
           AND last_archived_wal >= '$phase2_seg'
        FROM pg_stat_archiver
    ]) or die "Timed out waiting for phase-2 segment $phase2_seg to archive";

    return;
}

# Orchestrator loop for the GUC-on standby: when replay pauses, drain
# the slot via pg_logical_slot_get_changes and call
# pg_wal_replay_resume(). Exits when replay stops advancing or when
# $deadline_seconds have passed. Returns ($pauses_seen, $total_drained)
# and includes a final drain of anything left on the slot.
sub drain_and_resume_loop
{
    my ($standby, $slot_name, $deadline_seconds) = @_;

    my $total_drained = 0;
    my $pauses_seen = 0;
    my $last_replay = '';
    my $stall_ticks = 0;
    my $deadline = time() + $deadline_seconds;

    while (time() < $deadline) {
        my $state = $standby->safe_psql('postgres',
            "SELECT pg_get_wal_replay_pause_state()");
        my $replay = $standby->safe_psql('postgres',
            "SELECT pg_last_wal_replay_lsn()");

        if ($state eq 'paused' || $state eq 'pause requested') {
            my $got = $standby->safe_psql('postgres',
                "SELECT COUNT(*) FROM pg_logical_slot_get_changes('$slot_name', NULL, NULL)");
            $total_drained += $got;
            $pauses_seen++;
            $standby->safe_psql('postgres', "SELECT pg_wal_replay_resume()");
            $stall_ticks = 0;
        } elsif ($replay eq $last_replay) {
            $stall_ticks++;
            last if $stall_ticks > 10;
        } else {
            $stall_ticks = 0;
        }

        $last_replay = $replay;
        usleep(500_000);
    }

    my $final = $standby->safe_psql('postgres',
        "SELECT COUNT(*) FROM pg_logical_slot_get_changes('$slot_name', NULL, NULL)");
    $total_drained += $final;

    return ($pauses_seen, $total_drained);
}

# Poll until $standby reports replay as paused, up to ~30 seconds.
# Returns 1 on success, 0 on timeout.
sub wait_for_replay_paused
{
    my ($standby) = @_;

    for (my $i = 0; $i < 60; $i++) {
        my $s = $standby->safe_psql('postgres',
            "SELECT pg_get_wal_replay_pause_state()");
        return 1 if $s eq 'paused';
        usleep(500_000);
    }
    return 0;
}

# Models an operator who issued an explicit pg_wal_replay_pause() that
# must survive the GUC's auto-resume. On entry replay is parked at a
# pre-conflict LSN with the operator pause already in effect. Each tick we
# nudge replay forward (pg_wal_replay_resume()) and then immediately
# re-assert the operator pause (pg_wal_replay_pause()), so that when the
# startup process reaches the catalog-prune record the operator pause is
# already pending — i.e. GetRecoveryPauseState() != RECOVERY_NOT_PAUSED
# at the moment MaybePauseOnLogicalSlotConflict() captures it. We then
# drain the slot so the GUC's auto-resume re-scan finds nothing blocking.
# With the fix the operator's pause is preserved; without it the
# unconditional SetRecoveryPause(false) would clear it.
#
# Returns the total number of changes drained.
sub drain_holding_user_pause
{
    my ($standby, $slot_name, $deadline_seconds) = @_;

    my $total_drained = 0;
    my $deadline = time() + $deadline_seconds;

    while (time() < $deadline) {
        # Drain whatever the slot currently holds.
        my $got = $standby->safe_psql('postgres',
            "SELECT COUNT(*) FROM pg_logical_slot_get_changes('$slot_name', NULL, NULL)");
        $total_drained += $got;

        # Stop once the slot is fully drained and replay has advanced past
        # the conflict (nothing left to decode and no longer pause-looping
        # on the GUC). A short tail of zero-change drains confirms we are
        # done.
        last if $got == 0 && $total_drained > 0;

        # Nudge replay forward, then immediately re-pause so the operator
        # pause is pending again when the next conflict record is applied.
        $standby->safe_psql('postgres', "SELECT pg_wal_replay_resume()");
        $standby->safe_psql('postgres', "SELECT pg_wal_replay_pause()");

        usleep(500_000);
    }

    return $total_drained;
}

# ---------------------------------------------------------------------
# Main script
# ---------------------------------------------------------------------

# 1. GUC visibility.
my ($node_primary, $backup_name) = setup_primary_with_clean_archive();

my $guc = $node_primary->safe_psql('postgres',
    "SELECT COUNT(*) FROM pg_settings WHERE name = 'recovery_pause_on_logical_slot_conflict'");
is($guc, '1', 'recovery_pause_on_logical_slot_conflict GUC is registered');

# 2. Phase 1: bring up the standbys (GUC-on, GUC-off, and a second
# GUC-on "user-pause" standby) while the archive still contains only the
# quiet-moment snapshot — no prune records yet. Slot creation reaches
# SNAPBUILD_CONSISTENT quickly on all of them. Later, when Phase 2 ships
# the prune records, the standbys diverge: the GUC-on ones pause and
# drain; the GUC-off one invalidates. The user-pause standby additionally
# checks that an operator's explicit pause survives the GUC auto-resume.
my $node_standby = create_archive_standby($node_primary, $backup_name,
    'standby', 'on');
my $node_standby_off = create_archive_standby($node_primary, $backup_name,
    'standby_off', 'off');
my $node_standby_up = create_archive_standby($node_primary, $backup_name,
    'standby_userpause', 'on');

$node_standby->safe_psql('postgres', qq[
    SELECT pg_create_logical_replication_slot('t_slot', 'test_decoding');
]);
$node_standby_off->safe_psql('postgres', qq[
    SELECT pg_create_logical_replication_slot('t_slot_off', 'test_decoding');
]);
$node_standby_up->safe_psql('postgres', qq[
    SELECT pg_create_logical_replication_slot('up_slot', 'test_decoding');
]);

my $slot_ready = $node_standby->safe_psql('postgres', qq[
    SELECT wal_status FROM pg_replication_slots WHERE slot_name = 't_slot'
]);
is($slot_ready, 'reserved', "slot created cleanly in Phase 1 (state: $slot_ready)");

my $off_slot_ready = $node_standby_off->safe_psql('postgres', qq[
    SELECT wal_status FROM pg_replication_slots WHERE slot_name = 't_slot_off'
]);
is($off_slot_ready, 'reserved',
   "baseline slot created cleanly in Phase 1 (state: $off_slot_ready)");

my $up_slot_ready = $node_standby_up->safe_psql('postgres', qq[
    SELECT wal_status FROM pg_replication_slots WHERE slot_name = 'up_slot'
]);
is($up_slot_ready, 'reserved',
   "user-pause slot created cleanly in Phase 1 (state: $up_slot_ready)");

# Operator pauses recovery on the user-pause standby NOW, while the
# archive still only holds the clean Phase-1 snapshot and the catalog-
# prune conflict has not been replayed yet. This parks replay at a
# pre-conflict LSN with an explicit operator pause in effect — the exact
# precondition for the user-pause-clobber bug.
$node_standby_up->safe_psql('postgres', "SELECT pg_wal_replay_pause()");
ok(wait_for_replay_paused($node_standby_up),
   "user-pause standby parks on operator pg_wal_replay_pause() before conflict");

# 3. Phase 2: catalog churn on primary, then wait for archive.
run_catalog_churn($node_primary);

# 4. Orchestrator loop on the GUC-on standby.
my ($pauses_seen, $total_drained) =
    drain_and_resume_loop($node_standby, 't_slot', 60);

my $slot_state = $node_standby->safe_psql('postgres', qq[
    SELECT wal_status || '|' || COALESCE(invalidation_reason, '')
    FROM pg_replication_slots WHERE slot_name = 't_slot';
]);
like($slot_state, qr/^reserved\|/,
     "slot survived catalog prune with GUC on (state: $slot_state)");

cmp_ok($pauses_seen, '>=', 1,
    "at least one pause event was handled ($pauses_seen seen)");

cmp_ok($total_drained, '>=', 2000,
    "at least 2000 decoded events ($total_drained got)");

# 5. Baseline assertion: the GUC-off standby, faced with the exact same
# Phase-2 archive, should invalidate its slot. This confirms the test
# setup actually triggers the conflict AND that GUC-off behavior is
# unchanged from upstream — if this ever starts passing with state
# "reserved", either the test stopped reproducing the trigger or the
# GUC-off path accidentally benefits from our patch.
my $off_state = 'reserved';
for (my $i = 0; $i < 60; $i++) {
    $off_state = $node_standby_off->safe_psql('postgres', qq[
        SELECT wal_status FROM pg_replication_slots WHERE slot_name = 't_slot_off';
    ]);
    last if $off_state eq 'lost';
    usleep(500_000);
}

is($off_state, 'lost',
   "baseline (GUC off): slot invalidates as expected under catalog prune");

# 6. Promote-during-pause: bring up a third standby, get it paused by
# the GUC, then call pg_promote() and assert promotion actually
# completes (rather than stalling until someone also runs
# pg_wal_replay_resume). Guards the CheckForStandbyTrigger() escape
# path in the wait loop.
my $node_standby_p = create_archive_standby($node_primary, $backup_name,
    'standby_promote', 'on');
$node_standby_p->safe_psql('postgres',
    "SELECT pg_create_logical_replication_slot('promote_slot', 'test_decoding')");

# Phase-2 archive is already shipped so a pause will happen within a
# few seconds.
my $paused = wait_for_replay_paused($node_standby_p);
ok($paused, "promote-test standby reached paused state before promotion");

# Call pg_promote with a short wait. Without the CheckForStandbyTrigger
# escape in the wait loop, this stalls for the full wait_seconds and
# returns false; with the fix, it returns true in ~1 second.
my $t0 = time();
my $promoted = $node_standby_p->safe_psql('postgres',
    "SELECT pg_promote(wait => true, wait_seconds => 30)");
my $elapsed = time() - $t0;
is($promoted, 't', "pg_promote returned true while standby was paused by GUC");
cmp_ok($elapsed, '<', 10,
    "pg_promote completed in under 10s (actual: ${elapsed}s)");

$node_standby_p->stop;

# 7. User-pause survives auto-resume. The operator paused recovery with
# pg_wal_replay_pause() before the conflict record was replayed (done in
# section 2). drain_holding_user_pause nudges replay into the conflict
# while keeping that operator pause pending, then drains the slot so the
# GUC's auto-resume re-scan finds nothing blocking. The fix in
# MaybePauseOnLogicalSlotConflict() must then leave the operator's pause
# in place rather than clearing it with an unconditional
# SetRecoveryPause(false), so:
#   - with the fix: replay stays 'paused' after the conflict resolves;
#   - without the fix: auto-resume clears the pause and replay proceeds.
my $up_drained = drain_holding_user_pause($node_standby_up, 'up_slot', 60);

cmp_ok($up_drained, '>=', 2000,
    "user-pause standby drained the slot under operator pause ($up_drained got)");

# The slot must have survived (drained, not invalidated) just like the
# plain GUC-on standby.
my $up_slot_state = $node_standby_up->safe_psql('postgres', qq[
    SELECT wal_status || '|' || COALESCE(invalidation_reason, '')
    FROM pg_replication_slots WHERE slot_name = 'up_slot';
]);
like($up_slot_state, qr/^reserved\|/,
     "user-pause slot survived catalog prune (state: $up_slot_state)");

# The crux: recovery is STILL paused because the operator's pause was not
# cleared by the GUC's auto-resume.
my $up_pause_state = $node_standby_up->safe_psql('postgres',
    "SELECT pg_get_wal_replay_pause_state()");
is($up_pause_state, 'paused',
   "operator pause survived GUC auto-resume (state: $up_pause_state)");

# Now the operator resumes and replay must proceed past the pause.
my $up_lsn_before = $node_standby_up->safe_psql('postgres',
    "SELECT pg_last_wal_replay_lsn()");
$node_standby_up->safe_psql('postgres', "SELECT pg_wal_replay_resume()");
$node_standby_up->poll_query_until('postgres',
    "SELECT pg_get_wal_replay_pause_state() = 'not paused'")
    or die "replay did not leave paused state after operator resume";
ok($node_standby_up->poll_query_until('postgres',
    "SELECT pg_last_wal_replay_lsn() >= '$up_lsn_before'::pg_lsn"),
   "replay proceeds after operator pg_wal_replay_resume()");

$node_standby_up->stop;
$node_standby_off->stop;
$node_standby->stop;
$node_primary->stop;

done_testing();
