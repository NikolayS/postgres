# Copyright (c) 2025, PostgreSQL Global Development Group

# Test DROP TABLE logging functionality
# This test verifies that DROP TABLE operations are logged with correct LSN values

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Initialize node with logging to stderr (not logging collector)
my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init;
$node->append_conf('postgresql.conf', qq{
log_min_messages = log
logging_collector = off
log_destination = 'stderr'
log_object_drops = on
});
$node->start;

# Track log file position for incremental reading
my $log_offset = 0;

# Cache for current test - stores log content read once per test
my $current_test_log_cache = undef;

# Reset to start a new test - clears cache and updates offset
sub start_new_test
{
	my ($test_name) = @_;
	note($test_name) if defined $test_name;

	$current_test_log_cache = undef;

	# Update offset to current position
	my $logfile = $node->logfile;
	$log_offset = -s $logfile;
}

# Get log content for current test (cached within test)
sub get_test_log_content
{
	return $current_test_log_cache if defined $current_test_log_cache;

	# Read new content since last test started
	my $logfile = $node->logfile;
	my $current_size = -s $logfile;

	# If offset is beyond file size, reset to 0
	$log_offset = 0 if $log_offset > $current_size;

	# Read only new content
	$current_test_log_cache = slurp_file($logfile, $log_offset);

	return $current_test_log_cache;
}

# Count matching log entries in current test
sub count_drop_logs
{
	my ($pattern) = @_;
	my $log = get_test_log_content();
	my @matches = $log =~ /$pattern/g;
	return scalar @matches;
}

# Get matching log lines in current test
sub get_log_lines
{
	my ($pattern) = @_;
	my $log = get_test_log_content();
	my @lines = split /\n/, $log;
	my @matching_lines = grep { /$pattern/ } @lines;
	return @matching_lines;
}

# Helper function to extract LSN from log line
sub extract_lsn
{
	my ($line, $lsn_type) = @_;
	$lsn_type //= 'single';  # Default to single LSN format

	if ($lsn_type eq 'single')
	{
		# For single LSN: "LSN: 0/12345"
		if ($line =~ /LSN: ([0-9A-F]+\/[0-9A-F]+)/)
		{
			return $1;
		}
	}
	elsif ($lsn_type eq 'commit')
	{
		# For commit LSN in future extended format
		if ($line =~ /commit LSN: ([0-9A-F]+\/[0-9A-F]+)/)
		{
			return $1;
		}
	}
	return undef;
}

# Helper function to compare LSNs
sub lsn_less_than
{
	my ($lsn1, $lsn2) = @_;
	my ($seg1, $off1) = split /\//, $lsn1;
	my ($seg2, $off2) = split /\//, $lsn2;
	return (hex($seg1) < hex($seg2)) ||
	       (hex($seg1) == hex($seg2) && hex($off1) < hex($off2));
}

# Build pattern for DROP TABLE log entry
sub drop_table_pattern
{
	my ($schema, $table) = @_;
	return qr/DROP TABLE: relation "$schema\.$table"/;
}

# Build pattern for DROP DATABASE log entry
sub drop_database_pattern
{
	my ($dbname) = @_;
	return qr/DROP DATABASE: database "$dbname"/;
}

# Test helper: Execute SQL and verify drop count
sub test_drop_count
{
	my ($test_name, $sql, $pattern, $expected_count) = @_;

	start_new_test($test_name);
	$node->safe_psql('postgres', $sql);

	my $count = count_drop_logs($pattern);
	is($count, $expected_count, "$test_name: count check");
}

# Test helper: Execute SQL and verify log entry exists with valid LSN
sub test_drop_logged
{
	my ($test_name, $sql, $pattern, $extra_checks) = @_;

	start_new_test($test_name);
	$node->safe_psql('postgres', $sql);

	my @log_lines = get_log_lines($pattern);
	is(scalar @log_lines, 1, "$test_name: entry logged");

	if (@log_lines)
	{
		like($log_lines[0], qr/LSN: [0-9A-F]+\/[0-9A-F]+/,
		     "$test_name: LSN present");
		unlike($log_lines[0], qr/LSN: 0\/0/,
		       "$test_name: LSN not invalid");

		# Execute additional checks if provided
		$extra_checks->($log_lines[0]) if defined $extra_checks;
	}
}

# Test helper: Execute SQL and verify nothing was logged
sub test_drop_not_logged
{
	my ($test_name, $sql, $pattern) = @_;

	start_new_test($test_name);
	$node->safe_psql('postgres', $sql);

	my $count = count_drop_logs($pattern);
	is($count, 0, "$test_name: not logged");
}

# Test helper: Verify multiple drops in one transaction
sub test_multiple_drops
{
	my ($test_name, $sql, @table_specs) = @_;

	start_new_test($test_name);
	$node->safe_psql('postgres', $sql);

	foreach my $spec (@table_specs)
	{
		my ($schema, $table, $expected) = @$spec;
		my $count = count_drop_logs(drop_table_pattern($schema, $table));
		is($count, $expected, "$test_name: $schema.$table");
	}
}

# ==============================================================================
# TESTS START HERE
# ==============================================================================

# Test 1: Simple DROP TABLE (autocommit)
test_drop_logged(
	'Test 1: Simple DROP TABLE in autocommit mode',
	q{
		CREATE TABLE test_simple (id int);
		INSERT INTO test_simple VALUES (1);
		DROP TABLE test_simple;
	},
	drop_table_pattern('public', 'test_simple')
);

# Test 2: DROP TABLE inside transaction
test_drop_logged(
	'Test 2: DROP TABLE inside explicit transaction',
	q{
		BEGIN;
		CREATE TABLE test_in_xact (id int);
		INSERT INTO test_in_xact VALUES (1);
		DROP TABLE test_in_xact;
		COMMIT;
	},
	drop_table_pattern('public', 'test_in_xact')
);

# Test 3: DROP TABLE with ROLLBACK
test_drop_not_logged(
	'Test 3: DROP TABLE with ROLLBACK - should not be logged',
	q{
		CREATE TABLE test_rollback (id int);
		INSERT INTO test_rollback VALUES (1);
		BEGIN;
		DROP TABLE test_rollback;
		ROLLBACK;
	},
	drop_table_pattern('public', 'test_rollback')
);

# Now actually drop the table
test_drop_count(
	'Test 3b: Committed DROP logged',
	q{
		SELECT * FROM test_rollback;
		DROP TABLE test_rollback;
	},
	drop_table_pattern('public', 'test_rollback'),
	1
);

# Test 4: DROP SCHEMA CASCADE
test_multiple_drops(
	'Test 4: DROP SCHEMA CASCADE - all tables logged',
	q{
		CREATE SCHEMA test_schema;
		CREATE TABLE test_schema.table1 (id int);
		CREATE TABLE test_schema.table2 (name text);
		INSERT INTO test_schema.table1 VALUES (1);
		INSERT INTO test_schema.table2 VALUES ('test');
		BEGIN;
		DROP SCHEMA test_schema CASCADE;
		COMMIT;
	},
	['test_schema', 'table1', 1],
	['test_schema', 'table2', 1]
);

# Test 5: DROP TABLE with FK CASCADE
test_drop_count(
	'Test 5: DROP TABLE CASCADE with foreign keys',
	q{
		CREATE TABLE test_parent (id int PRIMARY KEY);
		CREATE TABLE test_child (id int, parent_id int REFERENCES test_parent(id));
		INSERT INTO test_parent VALUES (1);
		INSERT INTO test_child VALUES (1, 1);
		BEGIN;
		DROP TABLE test_parent CASCADE;
		COMMIT;
	},
	drop_table_pattern('public', 'test_parent'),
	1
);

# Test 6: Multiple DROP TABLE in single statement
test_multiple_drops(
	'Test 6: Multiple tables in single DROP statement',
	q{
		CREATE TABLE test_multi1 (id int);
		CREATE TABLE test_multi2 (id int);
		CREATE TABLE test_multi3 (id int);
		BEGIN;
		DROP TABLE test_multi1, test_multi2, test_multi3;
		COMMIT;
	},
	['public', 'test_multi1', 1],
	['public', 'test_multi2', 1],
	['public', 'test_multi3', 1]
);

# Test 7: DROP PARTITIONED TABLE
test_multiple_drops(
	'Test 7: Partitioned table and partitions',
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
	['public', 'test_partitioned', 1],
	['public', 'test_part_2024', 1],
	['public', 'test_part_2025', 1]
);

# Test 8: Mixed operations in one transaction
test_multiple_drops(
	'Test 8: Mixed CREATE and DROP operations in transaction',
	q{
		CREATE SCHEMA mixed_schema;
		BEGIN;
		CREATE TABLE mixed_schema.table1 (id int);
		INSERT INTO mixed_schema.table1 VALUES (1);
		CREATE TABLE mixed_schema.table2 (id int);
		DROP TABLE mixed_schema.table2;
		CREATE TABLE outside_table (id int);
		INSERT INTO outside_table VALUES (1);
		DROP SCHEMA mixed_schema CASCADE;
		DROP TABLE outside_table;
		COMMIT;
	},
	['mixed_schema', 'table1', 1],
	['mixed_schema', 'table2', 1],
	['public', 'outside_table', 1]
);

# Test 9: DROP temporary table
test_drop_count(
	'Test 9: Temporary table',
	q{
		CREATE TEMP TABLE test_temp (id int);
		INSERT INTO test_temp VALUES (1);
		BEGIN;
		DROP TABLE test_temp;
		COMMIT;
	},
	qr/DROP TABLE: relation "pg_temp_\d+\.test_temp"/,
	1
);

# Test 10: DROP VIEW (should not be logged)
start_new_test('Test 10: Views should not be logged');
$node->safe_psql('postgres', q{
	CREATE TABLE test_view_base (id int);
	CREATE VIEW test_view AS SELECT * FROM test_view_base;
	DROP VIEW test_view;
	DROP TABLE test_view_base;
});

my $view_count = count_drop_logs(qr/DROP TABLE: relation "public\.test_view"[^\w]/);
my $view_base_count = count_drop_logs(drop_table_pattern('public', 'test_view_base'));
is($view_count, 0, 'Test 10: VIEW drop not logged');
is($view_base_count, 1, 'Test 10: Base table drop logged');

# Test 11: DROP INDEX (should not be logged)
start_new_test('Test 11: Indexes should not be logged');
$node->safe_psql('postgres', q{
	CREATE TABLE test_index_table (id int);
	CREATE INDEX test_idx ON test_index_table(id);
	DROP INDEX test_idx;
	DROP TABLE test_index_table;
});

my $index_count = count_drop_logs(qr/DROP TABLE: relation "public\.test_idx"/);
my $index_table_count = count_drop_logs(drop_table_pattern('public', 'test_index_table'));
is($index_count, 0, 'Test 11: INDEX drop not logged');
is($index_table_count, 1, 'Test 11: Table drop logged');

# Test 12: Table inheritance hierarchy
test_multiple_drops(
	'Test 12: Inheritance hierarchy',
	q{
		CREATE TABLE parent_inherit (id int);
		CREATE TABLE child_inherit1 () INHERITS (parent_inherit);
		CREATE TABLE child_inherit2 () INHERITS (parent_inherit);
		INSERT INTO parent_inherit VALUES (1);
		INSERT INTO child_inherit1 VALUES (2);
		INSERT INTO child_inherit2 VALUES (3);
		BEGIN;
		DROP TABLE parent_inherit CASCADE;
		COMMIT;
	},
	['public', 'parent_inherit', 1],
	['public', 'child_inherit1', 1],
	['public', 'child_inherit2', 1]
);

# Test 13: Nested transaction with SAVEPOINT
start_new_test('Test 13: SAVEPOINT and ROLLBACK TO');
$node->safe_psql('postgres', q{
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

my $sp1_count = count_drop_logs(drop_table_pattern('public', 'test_savepoint1'));
my $sp2_count = count_drop_logs(drop_table_pattern('public', 'test_savepoint2'));
my $sp3_count = count_drop_logs(drop_table_pattern('public', 'test_savepoint3'));
is($sp1_count, 1, 'Test 13: savepoint1 logged');
is($sp2_count, 0, 'Test 13: savepoint2 NOT logged (rolled back)');
is($sp3_count, 1, 'Test 13: savepoint3 logged');

# Test 14: COMMIT AND CHAIN
start_new_test('Test 14: COMMIT AND CHAIN with multiple cycles');
$node->safe_psql('postgres', q{
	CREATE TABLE chain_test1 (id int);
	CREATE TABLE chain_test2 (id int);
	CREATE TABLE chain_test3 (id int);
	CREATE TABLE chain_test4 (id int);
	BEGIN;
	DROP TABLE chain_test1;
	INSERT INTO chain_test2 VALUES (1);
	DROP TABLE chain_test2;
	COMMIT AND CHAIN;
	DROP TABLE chain_test3;
	COMMIT AND CHAIN;
	DROP TABLE chain_test4;
	COMMIT;
});

my @chain_logs = get_log_lines(qr/DROP TABLE: relation "public\.chain_test[1-4]/);
is(scalar @chain_logs, 4, 'Test 14: Four COMMIT AND CHAIN drops logged');

# Test 15: ROLLBACK AND CHAIN
start_new_test('Test 15: ROLLBACK AND CHAIN');
$node->safe_psql('postgres', q{
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

my $rb_chain1 = count_drop_logs(drop_table_pattern('public', 'rollback_chain1'));
my $rb_chain2 = count_drop_logs(drop_table_pattern('public', 'rollback_chain2'));
my $rb_chain3 = count_drop_logs(drop_table_pattern('public', 'rollback_chain3'));
is($rb_chain1, 0, 'Test 15: rollback_chain1 NOT logged (rolled back)');
is($rb_chain2, 1, 'Test 15: rollback_chain2 logged');
is($rb_chain3, 1, 'Test 15: rollback_chain3 logged');

# Test 16: COMMIT AND CHAIN with SAVEPOINTs
start_new_test('Test 16: COMMIT AND CHAIN combined with SAVEPOINTs');
$node->safe_psql('postgres', q{
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

my $csp1 = count_drop_logs(drop_table_pattern('public', 'chain_sp1'));
my $csp2 = count_drop_logs(drop_table_pattern('public', 'chain_sp2'));
my $csp3 = count_drop_logs(drop_table_pattern('public', 'chain_sp3'));
my $csp4 = count_drop_logs(drop_table_pattern('public', 'chain_sp4'));
is($csp1, 1, 'Test 16: chain_sp1 logged');
is($csp2, 0, 'Test 16: chain_sp2 NOT logged (rolled back)');
is($csp3, 1, 'Test 16: chain_sp3 logged');
is($csp4, 1, 'Test 16: chain_sp4 logged');

# Test 17: Multiple COMMIT AND CHAIN cycles
start_new_test('Test 17: Five consecutive COMMIT AND CHAIN operations');
$node->safe_psql('postgres', q{
	CREATE TABLE cycle1 (id int);
	CREATE TABLE cycle2 (id int);
	CREATE TABLE cycle3 (id int);
	CREATE TABLE cycle4 (id int);
	CREATE TABLE cycle5 (id int);
	BEGIN;
	DROP TABLE cycle1;
	COMMIT AND CHAIN;
	DROP TABLE cycle2;
	COMMIT AND CHAIN;
	DROP TABLE cycle3;
	COMMIT AND CHAIN;
	DROP TABLE cycle4;
	COMMIT AND CHAIN;
	DROP TABLE cycle5;
	COMMIT;
});

my @cycle_logs = get_log_lines(qr/DROP TABLE: relation "public\.cycle\d"/);
is(scalar @cycle_logs, 5, 'Test 17: Five cycle drops logged');

# Test 18: DROP DATABASE
test_drop_logged(
	'Test 18: DROP DATABASE',
	q{
		CREATE DATABASE test_drop_db;
		DROP DATABASE test_drop_db;
	},
	drop_database_pattern('test_drop_db'),
	sub {
		my ($line) = @_;
		like($line, qr/LSN: [0-9A-F]+\/[0-9A-F]+/,
		     'Test 18: DROP DATABASE has single LSN');
	}
);

# Test 19: PL/pgSQL function with EXCEPTION block (subtransaction)
test_drop_logged(
	'Test 19: DROP in PL/pgSQL with EXCEPTION handler',
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
	drop_table_pattern('public', 'plpgsql_test')
);

done_testing();
