
# Copyright (c) 2021-2026, PostgreSQL Global Development Group
#
# Test for recovery_target_time configuration reload without server restart.
# Verifies that changing recovery_target_time via pg_reload_conf() while
# recovery is paused at the target causes replay to resume toward the new
# target.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Initialize primary with WAL archiving
my $node_primary = PostgreSQL::Test::Cluster->new('primary');
$node_primary->init(has_archiving => 1, allows_streaming => 1);
$node_primary->start;

# Create test table and insert initial data (batch 1 -- included in backup)
$node_primary->safe_psql('postgres',
	"CREATE TABLE test_data(id serial, val text, created_at timestamptz DEFAULT now())");
$node_primary->safe_psql('postgres',
	"INSERT INTO test_data(val) SELECT 'batch1_' || g FROM generate_series(1,100) g");

# Take base backup (needed for all standbys)
$node_primary->backup('my_backup');

# Insert batch 2
$node_primary->safe_psql('postgres',
	"INSERT INTO test_data(val) SELECT 'batch2_' || g FROM generate_series(1,100) g");

# Small sleep to ensure distinct timestamps between batches
$node_primary->safe_psql('postgres', "SELECT pg_sleep(1)");

# Capture timestamp T1 (after batch 2, before batch 3)
my $recovery_time_t1 =
  $node_primary->safe_psql('postgres', "SELECT now()");

$node_primary->safe_psql('postgres', "SELECT pg_sleep(1)");

# Insert batch 3
$node_primary->safe_psql('postgres',
	"INSERT INTO test_data(val) SELECT 'batch3_' || g FROM generate_series(1,100) g");

$node_primary->safe_psql('postgres', "SELECT pg_sleep(1)");

# Capture timestamp T2 (after batch 3, before batch 4)
my $recovery_time_t2 =
  $node_primary->safe_psql('postgres', "SELECT now()");

$node_primary->safe_psql('postgres', "SELECT pg_sleep(1)");

# Insert batch 4 (beyond all targets)
$node_primary->safe_psql('postgres',
	"INSERT INTO test_data(val) SELECT 'batch4_' || g FROM generate_series(1,100) g");

# Force WAL switch to ensure archiving completes
$node_primary->safe_psql('postgres', "SELECT pg_switch_wal()");

# Wait for the WAL file to be archived before creating standbys
# that rely on archive recovery.
sleep(2);

###############################################################################
# TEST 1: Pause at T1, advance to T2, verify resume and re-pause
###############################################################################

my $node_standby = PostgreSQL::Test::Cluster->new('standby1');
$node_standby->init_from_backup($node_primary, 'my_backup',
	has_restoring => 1);

$node_standby->append_conf('postgresql.conf', qq(
recovery_target_time = '$recovery_time_t1'
recovery_target_action = 'pause'
));

$node_standby->start;

# Wait for recovery to pause at T1
$node_standby->poll_query_until('postgres',
	"SELECT pg_get_wal_replay_pause_state() = 'paused'")
  or die "Timed out waiting for recovery to pause at T1";

# Verify data: should have batch1 (100) + batch2 (100) = 200 rows
# (batch3 not yet replayed because T1 is between batch2 and batch3)
my $count = $node_standby->safe_psql('postgres',
	"SELECT count(*) FROM test_data");
is($count, '200', 'TEST 1a: correct data at recovery target T1');

# Record log position before reload so we can check for log messages
my $log_offset = -s $node_standby->logfile;

# Now advance target to T2 via config file change and reload
$node_standby->adjust_conf('postgresql.conf', 'recovery_target_time',
	"'$recovery_time_t2'");
$node_standby->reload;

# Wait for the "recovery target time advanced" log message, which confirms
# the recovery process detected the new target and resumed replay.
$node_standby->wait_for_log(
	qr/recovery target time advanced from .* to .*, resuming WAL replay/,
	$log_offset);

# Wait for recovery to pause again (at T2 this time)
$node_standby->poll_query_until('postgres',
	"SELECT pg_get_wal_replay_pause_state() = 'paused'")
  or die "Timed out waiting for recovery to re-pause at T2";

# Verify data: should have batch1 + batch2 + batch3 = 300 rows
$count = $node_standby->safe_psql('postgres',
	"SELECT count(*) FROM test_data");
is($count, '300', 'TEST 1b: correct data after advancing target to T2');

###############################################################################
# TEST 2: Reload with same time -- verify no-op (still paused)
###############################################################################

# We're paused at T2.  Reload with same T2 value.
$node_standby->reload;

# Brief wait to confirm it doesn't resume
sleep(2);
my $pause_state = $node_standby->safe_psql('postgres',
	"SELECT pg_get_wal_replay_pause_state()");
is($pause_state, 'paused',
	'TEST 2a: same target reload is no-op, still paused');

$count = $node_standby->safe_psql('postgres',
	"SELECT count(*) FROM test_data");
is($count, '300', 'TEST 2b: data unchanged after same-target reload');

###############################################################################
# TEST 3: Reload with earlier time -- verify no-op (still paused)
###############################################################################

$node_standby->adjust_conf('postgresql.conf', 'recovery_target_time',
	"'$recovery_time_t1'");
$node_standby->reload;

# Brief wait to confirm it doesn't resume
sleep(2);
$pause_state = $node_standby->safe_psql('postgres',
	"SELECT pg_get_wal_replay_pause_state()");
is($pause_state, 'paused',
	'TEST 3a: earlier target reload is no-op, still paused');

$count = $node_standby->safe_psql('postgres',
	"SELECT count(*) FROM test_data");
is($count, '300', 'TEST 3b: data unchanged after earlier-target reload');

###############################################################################
# TEST 4: pg_wal_replay_resume() while paused at target proceeds to
# promotion, does NOT re-enter replay
###############################################################################

# Reset target back to T2 first (so we're paused at a well-defined point)
$node_standby->adjust_conf('postgresql.conf', 'recovery_target_time',
	"'$recovery_time_t2'");
$node_standby->reload;
sleep(1);

# Call pg_wal_replay_resume() -- this should proceed to promote
$node_standby->safe_psql('postgres', "SELECT pg_wal_replay_resume()");

# Wait for promotion to complete
$node_standby->poll_query_until('postgres',
	"SELECT pg_is_in_recovery() = false")
  or die "Timed out waiting for promotion after pg_wal_replay_resume()";

my $in_recovery = $node_standby->safe_psql('postgres',
	"SELECT pg_is_in_recovery()");
is($in_recovery, 'f',
	'TEST 4: pg_wal_replay_resume() promotes, does not re-enter replay');

$node_standby->stop;

###############################################################################
# TEST 5: Mutual exclusion -- reject recovery_target_time when another
# target type is already set
###############################################################################

my $node_standby5 = PostgreSQL::Test::Cluster->new('standby5');
$node_standby5->init_from_backup($node_primary, 'my_backup',
	has_restoring => 1);

# Set recovery_target_name first, then try to also set recovery_target_time.
# PostgreSQL should reject the startup due to multiple recovery targets.
$node_standby5->append_conf('postgresql.conf', qq(
recovery_target_name = 'does_not_matter'
recovery_target_time = '$recovery_time_t1'
recovery_target_action = 'pause'
));

my $res = run_log(
	[
		'pg_ctl',
		'--pgdata' => $node_standby5->data_dir,
		'--log' => $node_standby5->logfile,
		'start',
	]);
ok(!$res, 'TEST 5a: startup with conflicting recovery targets fails');

my $logfile = slurp_file($node_standby5->logfile());
like(
	$logfile,
	qr/Cannot set recovery_target_time when another recovery target type is already set|multiple recovery targets specified/,
	'TEST 5b: conflicting recovery target types are rejected');

done_testing();
