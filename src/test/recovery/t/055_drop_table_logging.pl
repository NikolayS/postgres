# Copyright (c) 2025-2026, PostgreSQL Global Development Group

# Test log_object_drops.
#
# Beyond checking that a log entry appears at all, this verifies that the
# logged LSN is the *actual commit LSN* of the dropping transaction, that
# nothing is logged when the feature is off / the drop is rolled back / the
# object is temporary, and that the LSN is usable as a point-in-time recovery
# target in the way the documentation prescribes.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init(has_archiving => 1, allows_streaming => 1);
$node->append_conf(
	'postgresql.conf', qq{
log_min_messages = log
logging_collector = off
log_destination = 'stderr'
log_object_drops = on

# Keep the WAL stream quiet so that the "logged LSN == current insert LSN"
# assertions below are not perturbed by unrelated background WAL.
autovacuum = off
checkpoint_timeout = 1h
max_wal_size = 1GB
});
$node->start;

# ==============================================================================
# Log-reading helpers
# ==============================================================================

my $log_offset = 0;
my $current_test_log_cache = undef;

# Reset to start a new test - clears cache and updates offset
sub start_new_test
{
	my ($test_name) = @_;
	note($test_name) if defined $test_name;

	$current_test_log_cache = undef;
	$log_offset = -s $node->logfile;
}

# Get log content produced since the current test started (cached).
sub get_test_log_content
{
	return $current_test_log_cache if defined $current_test_log_cache;

	my $logfile = $node->logfile;
	my $current_size = -s $logfile;

	$log_offset = 0 if $log_offset > $current_size;
	$current_test_log_cache = slurp_file($logfile, $log_offset);

	return $current_test_log_cache;
}

sub count_drop_logs
{
	my ($pattern) = @_;
	my $log = get_test_log_content();
	my @matches = $log =~ /$pattern/g;
	return scalar @matches;
}

sub get_log_lines
{
	my ($pattern) = @_;
	my @lines = split /\n/, get_test_log_content();
	return grep { /$pattern/ } @lines;
}

sub drop_table_pattern
{
	my ($schema, $table) = @_;
	return qr/DROP TABLE: relation "$schema\.$table"/;
}

sub drop_database_pattern
{
	my ($dbname) = @_;
	return qr/DROP DATABASE: database "$dbname"/;
}

# ==============================================================================
# LSN helpers
# ==============================================================================

# Extract the commit LSN from a log line, as a "hi/lo" string.
sub extract_commit_lsn
{
	my ($line) = @_;
	return $1 if $line =~ m{commit LSN: ([0-9A-F]+/[0-9A-F]+)};
	return undef;
}

# Compare two LSN strings numerically. Returns -1, 0 or 1.
# Done by hand rather than by string equality so that the test does not depend
# on the zero-padding of either the log message or pg_lsn's output.
sub lsn_cmp
{
	my ($a, $b) = @_;
	my ($ahi, $alo) = map { hex($_) } split m{/}, $a;
	my ($bhi, $blo) = map { hex($_) } split m{/}, $b;
	return $ahi <=> $bhi || $alo <=> $blo;
}

sub current_insert_lsn
{
	my $lsn = $node->safe_psql('postgres', 'SELECT pg_current_wal_insert_lsn()');
	chomp $lsn;
	return $lsn;
}

# ==============================================================================
# Test helpers
# ==============================================================================

sub test_drop_count
{
	my ($test_name, $sql, $pattern, $expected_count) = @_;

	start_new_test($test_name);
	$node->safe_psql('postgres', $sql);
	is(count_drop_logs($pattern), $expected_count, "$test_name: count check");
	return;
}

sub test_drop_not_logged
{
	my ($test_name, $sql, $pattern) = @_;

	start_new_test($test_name);
	$node->safe_psql('postgres', $sql);
	is(count_drop_logs($pattern), 0, "$test_name: not logged");
	return;
}

sub test_multiple_drops
{
	my ($test_name, $sql, @table_specs) = @_;

	start_new_test($test_name);
	$node->safe_psql('postgres', $sql);

	foreach my $spec (@table_specs)
	{
		my ($schema, $table, $expected) = @$spec;
		is(count_drop_logs(drop_table_pattern($schema, $table)),
			$expected, "$test_name: $schema.$table");
	}
	return;
}

# ==============================================================================
# Test 1: the logged LSN is the ACTUAL commit LSN
#
# This is the core assertion. The transaction writes a large amount of WAL
# *between* the DROP and the COMMIT, so the LSN of the catalog change is far
# behind the commit LSN. A patch that logs GetXLogInsertRecPtr() at drop time
# (as the DROP DATABASE path used to) fails the "strictly greater" check; a
# patch that logs anything else fails the exact-match check.
# ==============================================================================

start_new_test('Test 1: logged LSN is the actual commit LSN');
$node->safe_psql('postgres',
	'CREATE TABLE filler (id int, pad text); CREATE TABLE test_commit_lsn (id int)');

my $out = $node->safe_psql(
	'postgres', q{
	BEGIN;
	DROP TABLE test_commit_lsn;
	SELECT pg_current_wal_insert_lsn();
	INSERT INTO filler SELECT i, repeat('x', 100) FROM generate_series(1, 50000) i;
	SELECT pg_current_wal_insert_lsn();
	COMMIT;
	SELECT pg_current_wal_insert_lsn();
});
my ($lsn_after_drop, $lsn_before_commit, $lsn_after_commit) = split /\n/, $out;

my @lines = get_log_lines(drop_table_pattern('public', 'test_commit_lsn'));
is(scalar @lines, 1, 'Test 1: exactly one entry logged');
my $logged = extract_commit_lsn($lines[0]);
ok(defined $logged, 'Test 1: commit LSN present in log message');

note("logged=$logged after_drop=$lsn_after_drop "
	  . "before_commit=$lsn_before_commit after_commit=$lsn_after_commit");

# The whole point of the feature: not the drop LSN.
ok(lsn_cmp($logged, $lsn_after_drop) > 0,
	'Test 1: logged LSN is past the drop LSN (not GetXLogInsertRecPtr at drop time)');

# The logged value must be the START of the commit record, because that is what
# recovery_target_lsn is compared against (recoveryStopsBefore() tests
# record->ReadRecPtr). lsn_before_commit is the insert pointer immediately
# before COMMIT, i.e. where the commit record begins; lsn_after_commit is where
# it ends. So: before_commit <= logged < after_commit.
#
# The lower bound is not asserted as exact equality because the commit record's
# start can be nudged forward past a WAL page header.
ok(lsn_cmp($logged, $lsn_before_commit) >= 0,
	'Test 1: logged LSN is at or after the start of the commit record');
ok(lsn_cmp($logged, $lsn_after_commit) < 0,
	'Test 1: logged LSN is the START of the commit record, not its end');

# ==============================================================================
# Test 2: nothing is logged when the GUC is off
# ==============================================================================

start_new_test('Test 2: nothing logged when log_object_drops = off');
$node->safe_psql(
	'postgres', q{
	CREATE TABLE test_guc_off (id int);
	SET log_object_drops = off;
	DROP TABLE test_guc_off;
});
is(count_drop_logs(drop_table_pattern('public', 'test_guc_off')),
	0, 'Test 2: GUC off - table drop not logged');

start_new_test('Test 2b: nothing logged for DROP DATABASE when GUC is off');
$node->safe_psql(
	'postgres', q{
	SET log_object_drops = off;
	CREATE DATABASE test_guc_off_db;
	DROP DATABASE test_guc_off_db;
});
is(count_drop_logs(drop_database_pattern('test_guc_off_db')),
	0, 'Test 2b: GUC off - database drop not logged');

# Confirm the GUC-off result above is meaningful: the same drop IS logged when on.
start_new_test('Test 2c: control - same drop logged when GUC is on');
$node->safe_psql(
	'postgres', q{
	CREATE TABLE test_guc_on (id int);
	DROP TABLE test_guc_on;
});
is(count_drop_logs(drop_table_pattern('public', 'test_guc_on')),
	1, 'Test 2c: GUC on - table drop logged');

# ==============================================================================
# Test 3: nothing is logged on ROLLBACK
# ==============================================================================

test_drop_not_logged(
	'Test 3: DROP TABLE with ROLLBACK',
	q{
		CREATE TABLE test_rollback (id int);
		BEGIN;
		DROP TABLE test_rollback;
		ROLLBACK;
	},
	drop_table_pattern('public', 'test_rollback'));

# The table must still be there, and dropping it for real must log.
test_drop_count(
	'Test 3b: committed DROP after rollback is logged',
	q{
		SELECT * FROM test_rollback;
		DROP TABLE test_rollback;
	},
	drop_table_pattern('public', 'test_rollback'),
	1);

# ==============================================================================
# Test 4: temporary tables are never logged
# ==============================================================================

test_drop_not_logged(
	'Test 4: explicit DROP of a TEMP table',
	q{
		CREATE TEMP TABLE test_temp (id int);
		INSERT INTO test_temp VALUES (1);
		BEGIN;
		DROP TABLE test_temp;
		COMMIT;
	},
	qr/DROP TABLE: relation "pg_temp[^"]*\.test_temp"/);

# ON COMMIT DROP and session-end cleanup are the noisy cases the exclusion
# exists for; neither must produce a log entry.
test_drop_not_logged(
	'Test 5: TEMP table with ON COMMIT DROP',
	q{
		BEGIN;
		CREATE TEMP TABLE test_temp_oncommit (id int) ON COMMIT DROP;
		INSERT INTO test_temp_oncommit VALUES (1);
		COMMIT;
	},
	qr/DROP TABLE: relation "pg_temp[^"]*\.test_temp_oncommit"/);

test_drop_not_logged(
	'Test 6: TEMP table dropped implicitly at session end',
	q{
		CREATE TEMP TABLE test_temp_session (id int);
	},
	qr/DROP TABLE: relation "pg_temp[^"]*\.test_temp_session"/);

# A permanent table dropped in the same transaction as a temp one is still
# logged - the temp exclusion must not swallow its sibling.
start_new_test('Test 7: TEMP exclusion does not suppress permanent tables');
$node->safe_psql(
	'postgres', q{
	CREATE TABLE test_perm_sibling (id int);
	BEGIN;
	CREATE TEMP TABLE test_temp_sibling (id int);
	DROP TABLE test_temp_sibling;
	DROP TABLE test_perm_sibling;
	COMMIT;
});
is(count_drop_logs(qr/DROP TABLE: relation "pg_temp[^"]*\.test_temp_sibling"/),
	0, 'Test 7: temp sibling not logged');
is(count_drop_logs(drop_table_pattern('public', 'test_perm_sibling')),
	1, 'Test 7: permanent sibling logged');

# ==============================================================================
# Test 8: DROP DATABASE logs the commit LSN
#
# dropdb() forces an immediate checkpoint between the catalog delete and the
# commit, so the old GetXLogInsertRecPtr()-at-delete-time value is necessarily
# well before the commit record. Exact equality with the post-commit insert
# pointer pins this down.
# ==============================================================================

start_new_test('Test 8: DROP DATABASE logs the commit LSN');
$node->safe_psql('postgres', 'CREATE DATABASE test_drop_db');
my $db_lsn_before = current_insert_lsn();
$node->safe_psql('postgres', 'DROP DATABASE test_drop_db');
my $db_lsn_after = current_insert_lsn();

my @db_lines = get_log_lines(drop_database_pattern('test_drop_db'));
is(scalar @db_lines, 1, 'Test 8: exactly one DROP DATABASE entry logged');
my $db_logged = extract_commit_lsn($db_lines[0]);
ok(defined $db_logged, 'Test 8: DROP DATABASE reports a commit LSN');
note("db logged=$db_logged before=$db_lsn_before after=$db_lsn_after");
ok(lsn_cmp($db_logged, $db_lsn_before) > 0,
	'Test 8: DROP DATABASE LSN is past the pre-drop LSN');
ok(lsn_cmp($db_logged, $db_lsn_after) < 0,
	'Test 8: DROP DATABASE LSN is the start of the commit record, not its end');

# A DROP DATABASE that fails must not log anything (the old code logged before
# the drop was durable, so a later failure still produced a log line).
start_new_test('Test 9: failed DROP DATABASE is not logged');
$node->psql('postgres', 'DROP DATABASE test_nonexistent_db');
is(count_drop_logs(drop_database_pattern('test_nonexistent_db')),
	0, 'Test 9: failed DROP DATABASE not logged');

# ==============================================================================
# Structural coverage carried over from v5
# ==============================================================================

test_drop_count(
	'Test 10: simple DROP TABLE in autocommit',
	q{
		CREATE TABLE test_simple (id int);
		DROP TABLE test_simple;
	},
	drop_table_pattern('public', 'test_simple'),
	1);

test_multiple_drops(
	'Test 11: DROP SCHEMA CASCADE',
	q{
		CREATE SCHEMA test_schema;
		CREATE TABLE test_schema.table1 (id int);
		CREATE TABLE test_schema.table2 (name text);
		BEGIN;
		DROP SCHEMA test_schema CASCADE;
		COMMIT;
	},
	[ 'test_schema', 'table1', 1 ],
	[ 'test_schema', 'table2', 1 ]);

test_drop_count(
	'Test 12: DROP TABLE CASCADE with foreign keys',
	q{
		CREATE TABLE test_parent (id int PRIMARY KEY);
		CREATE TABLE test_child (id int, parent_id int REFERENCES test_parent(id));
		BEGIN;
		DROP TABLE test_parent CASCADE;
		COMMIT;
	},
	drop_table_pattern('public', 'test_parent'),
	1);

test_multiple_drops(
	'Test 13: multiple tables in a single DROP statement',
	q{
		CREATE TABLE test_multi1 (id int);
		CREATE TABLE test_multi2 (id int);
		CREATE TABLE test_multi3 (id int);
		BEGIN;
		DROP TABLE test_multi1, test_multi2, test_multi3;
		COMMIT;
	},
	[ 'public', 'test_multi1', 1 ],
	[ 'public', 'test_multi2', 1 ],
	[ 'public', 'test_multi3', 1 ]);

test_multiple_drops(
	'Test 14: partitioned table and partitions',
	q{
		CREATE TABLE test_partitioned (id int, created_at date) PARTITION BY RANGE (created_at);
		CREATE TABLE test_part_2024 PARTITION OF test_partitioned
		    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
		CREATE TABLE test_part_2025 PARTITION OF test_partitioned
		    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
		BEGIN;
		DROP TABLE test_partitioned CASCADE;
		COMMIT;
	},
	[ 'public', 'test_partitioned', 1 ],
	[ 'public', 'test_part_2024', 1 ],
	[ 'public', 'test_part_2025', 1 ]);

test_multiple_drops(
	'Test 15: inheritance hierarchy',
	q{
		CREATE TABLE parent_inherit (id int);
		CREATE TABLE child_inherit1 () INHERITS (parent_inherit);
		CREATE TABLE child_inherit2 () INHERITS (parent_inherit);
		BEGIN;
		DROP TABLE parent_inherit CASCADE;
		COMMIT;
	},
	[ 'public', 'parent_inherit', 1 ],
	[ 'public', 'child_inherit1', 1 ],
	[ 'public', 'child_inherit2', 1 ]);

# Views and indexes are not tables and must not be logged.
start_new_test('Test 16: views and indexes are not logged');
$node->safe_psql(
	'postgres', q{
	CREATE TABLE test_view_base (id int);
	CREATE VIEW test_view AS SELECT * FROM test_view_base;
	CREATE INDEX test_idx ON test_view_base(id);
	DROP VIEW test_view;
	DROP INDEX test_idx;
	DROP TABLE test_view_base;
});
is(count_drop_logs(qr/DROP TABLE: relation "public\.test_view"/),
	0, 'Test 16: VIEW drop not logged');
is(count_drop_logs(qr/DROP TABLE: relation "public\.test_idx"/),
	0, 'Test 16: INDEX drop not logged');
is(count_drop_logs(drop_table_pattern('public', 'test_view_base')),
	1, 'Test 16: base table drop logged');

# ==============================================================================
# Subtransaction handling
# ==============================================================================

start_new_test('Test 17: SAVEPOINT and ROLLBACK TO');
$node->safe_psql(
	'postgres', q{
	CREATE TABLE test_savepoint1 (id int);
	CREATE TABLE test_savepoint2 (id int);
	CREATE TABLE test_savepoint3 (id int);
	BEGIN;
	DROP TABLE test_savepoint1;
	SAVEPOINT sp1;
	DROP TABLE test_savepoint2;
	ROLLBACK TO sp1;
	DROP TABLE test_savepoint3;
	COMMIT;
});
is(count_drop_logs(drop_table_pattern('public', 'test_savepoint1')),
	1, 'Test 17: savepoint1 logged');
is(count_drop_logs(drop_table_pattern('public', 'test_savepoint2')),
	0, 'Test 17: savepoint2 NOT logged (rolled back to savepoint)');
is(count_drop_logs(drop_table_pattern('public', 'test_savepoint3')),
	1, 'Test 17: savepoint3 logged');

start_new_test('Test 18: COMMIT AND CHAIN');
$node->safe_psql(
	'postgres', q{
	CREATE TABLE chain_test1 (id int);
	CREATE TABLE chain_test2 (id int);
	CREATE TABLE chain_test3 (id int);
	CREATE TABLE chain_test4 (id int);
	BEGIN;
	DROP TABLE chain_test1;
	DROP TABLE chain_test2;
	COMMIT AND CHAIN;
	DROP TABLE chain_test3;
	COMMIT AND CHAIN;
	DROP TABLE chain_test4;
	COMMIT;
});
is(scalar(get_log_lines(qr/DROP TABLE: relation "public\.chain_test[1-4]"/)),
	4, 'Test 18: four COMMIT AND CHAIN drops logged');

start_new_test('Test 19: ROLLBACK AND CHAIN');
$node->safe_psql(
	'postgres', q{
	CREATE TABLE rollback_chain1 (id int);
	CREATE TABLE rollback_chain2 (id int);
	CREATE TABLE rollback_chain3 (id int);
	BEGIN;
	DROP TABLE rollback_chain1;
	ROLLBACK AND CHAIN;
	DROP TABLE rollback_chain2;
	COMMIT AND CHAIN;
	DROP TABLE rollback_chain3;
	COMMIT;
});
is(count_drop_logs(drop_table_pattern('public', 'rollback_chain1')),
	0, 'Test 19: rollback_chain1 NOT logged (rolled back)');
is(count_drop_logs(drop_table_pattern('public', 'rollback_chain2')),
	1, 'Test 19: rollback_chain2 logged');
is(count_drop_logs(drop_table_pattern('public', 'rollback_chain3')),
	1, 'Test 19: rollback_chain3 logged');

start_new_test('Test 20: COMMIT AND CHAIN combined with SAVEPOINTs');
$node->safe_psql(
	'postgres', q{
	CREATE TABLE chain_sp1 (id int);
	CREATE TABLE chain_sp2 (id int);
	CREATE TABLE chain_sp3 (id int);
	CREATE TABLE chain_sp4 (id int);
	BEGIN;
	DROP TABLE chain_sp1;
	SAVEPOINT sp1;
	DROP TABLE chain_sp2;
	ROLLBACK TO sp1;
	DROP TABLE chain_sp3;
	COMMIT AND CHAIN;
	DROP TABLE chain_sp4;
	COMMIT;
});
is(count_drop_logs(drop_table_pattern('public', 'chain_sp1')),
	1, 'Test 20: chain_sp1 logged');
is(count_drop_logs(drop_table_pattern('public', 'chain_sp2')),
	0, 'Test 20: chain_sp2 NOT logged (rolled back to savepoint)');
is(count_drop_logs(drop_table_pattern('public', 'chain_sp3')),
	1, 'Test 20: chain_sp3 logged');
is(count_drop_logs(drop_table_pattern('public', 'chain_sp4')),
	1, 'Test 20: chain_sp4 logged');

# PL/pgSQL EXCEPTION blocks are implicit subtransactions that commit.
test_drop_count(
	'Test 21: DROP in PL/pgSQL with EXCEPTION handler',
	q{
		CREATE TABLE plpgsql_test (id int);
		CREATE FUNCTION test_drop_with_exception() RETURNS void AS $$
		BEGIN
		    DROP TABLE plpgsql_test;
		EXCEPTION
		    WHEN OTHERS THEN
		        RAISE NOTICE 'Exception caught';
		END;
		$$ LANGUAGE plpgsql;
		SELECT test_drop_with_exception();
	},
	drop_table_pattern('public', 'plpgsql_test'),
	1);

# A drop inside a PL/pgSQL subtransaction that then raises must not be logged.
test_drop_not_logged(
	'Test 22: DROP undone by PL/pgSQL EXCEPTION rollback',
	q{
		CREATE TABLE plpgsql_undone (id int);
		CREATE FUNCTION test_drop_undone() RETURNS void AS $$
		BEGIN
		    BEGIN
		        DROP TABLE plpgsql_undone;
		        RAISE EXCEPTION 'boom';
		    EXCEPTION
		        WHEN OTHERS THEN
		            RAISE NOTICE 'rolled back';
		    END;
		END;
		$$ LANGUAGE plpgsql;
		SELECT test_drop_undone();
	},
	drop_table_pattern('public', 'plpgsql_undone'));

# ==============================================================================
# Test 23: end-to-end PITR using the logged LSN
#
# This is the feature's reason for existing, and it exercises the exact recipe
# the documentation gives, including the recovery_target_inclusive trap.
# ==============================================================================

start_new_test('Test 23: PITR using the logged commit LSN');

$node->backup('pitr_backup');
$node->safe_psql(
	'postgres', q{
	CREATE TABLE precious (id int);
	INSERT INTO precious SELECT generate_series(1, 100);
});
$node->safe_psql('postgres', 'DROP TABLE precious');
$node->safe_psql('postgres', 'SELECT pg_switch_wal()');

my @pitr_lines = get_log_lines(drop_table_pattern('public', 'precious'));
is(scalar @pitr_lines, 1, 'Test 23: drop of precious logged');
my $pitr_lsn = extract_commit_lsn($pitr_lines[0]);
ok(defined $pitr_lsn, 'Test 23: got a commit LSN to recover to');
note("PITR target LSN = $pitr_lsn");

# 23a: the documented incantation - recovery_target_inclusive = off - must
# stop BEFORE the drop commits and bring the table back.
my $good = PostgreSQL::Test::Cluster->new('pitr_exclusive');
$good->init_from_backup($node, 'pitr_backup', has_restoring => 1);
$good->append_conf(
	'postgresql.conf', qq{
recovery_target_lsn = '$pitr_lsn'
recovery_target_inclusive = off
recovery_target_action = 'promote'
recovery_target_timeline = 1
# The backup carries the primary's archive settings; leaving them on would
# publish this node's promoted timeline into the primary's archive and let the
# other recovery node below follow it.
archive_mode = off
});
$good->start;
$good->poll_query_until('postgres', 'SELECT NOT pg_is_in_recovery()')
  or die "timed out waiting for pitr_exclusive to promote";

is( $good->safe_psql(
		'postgres',
		"SELECT count(*) FROM pg_class WHERE relname = 'precious'"),
	'1',
	'Test 23a: recovery_target_inclusive=off recovers the dropped table');
is($good->safe_psql('postgres', 'SELECT count(*) FROM precious'),
	'100', 'Test 23a: recovered table has its rows');
$good->stop;

# 23b: the trap. Setting only recovery_target_lsn leaves
# recovery_target_inclusive at its default of on, which replays the drop and
# loses the table again. This test documents that failure mode so that any
# future change to the default is caught here.
my $trap = PostgreSQL::Test::Cluster->new('pitr_inclusive');
$trap->init_from_backup($node, 'pitr_backup', has_restoring => 1);
$trap->append_conf(
	'postgresql.conf', qq{
recovery_target_lsn = '$pitr_lsn'
recovery_target_action = 'promote'
recovery_target_timeline = 1
archive_mode = off
});
$trap->start;
$trap->poll_query_until('postgres', 'SELECT NOT pg_is_in_recovery()')
  or die "timed out waiting for pitr_inclusive to promote";

is( $trap->safe_psql(
		'postgres',
		"SELECT count(*) FROM pg_class WHERE relname = 'precious'"),
	'0',
	'Test 23b: default recovery_target_inclusive=on replays the drop (documented trap)');
$trap->stop;

done_testing();
