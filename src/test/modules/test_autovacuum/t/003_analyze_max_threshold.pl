# Copyright (c) 2026, PostgreSQL Global Development Group

# Test autovacuum_analyze_max_threshold GUC and table storage parameter

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf(
	'postgresql.conf', qq{
autovacuum = off
autovacuum_naptime = '1s'
});
$node->start;

# Verify default GUC value.
is( $node->safe_psql('postgres', 'SHOW autovacuum_analyze_max_threshold'),
	'50000000',
	'default autovacuum_analyze_max_threshold is 50000000');

# Create tables whose uncapped analyze threshold is 50 + 0.5 * 1000 = 550.
$node->safe_psql(
	'postgres', qq{
  CREATE TABLE t_global (i int) WITH (
    autovacuum_analyze_threshold = 50,
    autovacuum_analyze_scale_factor = 0.5
  );
  CREATE TABLE t_per_table (i int) WITH (
    autovacuum_analyze_threshold = 50,
    autovacuum_analyze_scale_factor = 0.5,
    autovacuum_analyze_max_threshold = 80
  );
  CREATE TABLE t_disabled (i int) WITH (
    autovacuum_analyze_threshold = 50,
    autovacuum_analyze_scale_factor = 0.5,
    autovacuum_analyze_max_threshold = -1
  );
  CREATE TABLE t_zero (i int) WITH (
    autovacuum_analyze_threshold = 50,
    autovacuum_analyze_scale_factor = 0.5,
    autovacuum_analyze_max_threshold = 0
  );
  CREATE TABLE t_with_toast (t text);

  INSERT INTO t_global SELECT g FROM generate_series(1, 1000) g;
  INSERT INTO t_per_table SELECT g FROM generate_series(1, 1000) g;
  INSERT INTO t_disabled SELECT g FROM generate_series(1, 1000) g;
  INSERT INTO t_zero SELECT g FROM generate_series(1, 1000) g;
  SELECT pg_stat_force_next_flush();
});

# Analyze in a separate session after insert stats have been flushed so that
# n_mod_since_analyze is cleanly reset to 0 before the updates below.
$node->safe_psql('postgres',
	'ANALYZE t_global, t_per_table, t_disabled, t_zero;');

$node->safe_psql(
	'postgres', qq{
  UPDATE t_global SET i = i + 1 WHERE i <= 100;
  UPDATE t_per_table SET i = i + 1 WHERE i <= 100;
  UPDATE t_disabled SET i = i + 1 WHERE i <= 100;
  UPDATE t_zero SET i = i + 1 WHERE i = 1;
  SELECT pg_stat_force_next_flush();
});

# With default global max threshold (50M):
# - t_global has threshold 550 -> 100 / 550 < 1
# - t_per_table has threshold 80 -> 100 / 80 = 1.25 > 1
# - t_disabled has threshold 550 -> 100 / 550 < 1
# - t_zero has threshold 0 (clamped to 1 in score denominator) -> 1 / 1 = 1
is( $node->safe_psql(
		'postgres', qq{
  SELECT analyze_score < 1 FROM pg_stat_autovacuum_scores
  WHERE relid = 't_global'::regclass
}),
	't',
	'uncapped table analyze_score < 1 under default max threshold');

is( $node->safe_psql(
		'postgres', qq{
  SELECT analyze_score > 1 FROM pg_stat_autovacuum_scores
  WHERE relid = 't_per_table'::regclass
}),
	't',
	'per-table autovacuum_analyze_max_threshold caps threshold and raises analyze_score');

is( $node->safe_psql(
		'postgres', qq{
  SELECT analyze_score = 1 FROM pg_stat_autovacuum_scores
  WHERE relid = 't_zero'::regclass
}),
	't',
	'autovacuum_analyze_max_threshold = 0 avoids division by zero in analyze_score');

# Invalid storage parameter values and toast.* prefix are rejected.
my ($ret, $stdout, $stderr) = $node->psql(
	'postgres',
	'ALTER TABLE t_global SET (autovacuum_analyze_max_threshold = -2)');
isnt($ret, 0, 'autovacuum_analyze_max_threshold = -2 is rejected');

($ret, $stdout, $stderr) = $node->psql(
	'postgres',
	'ALTER TABLE t_with_toast SET (toast.autovacuum_analyze_max_threshold = 100)');
isnt($ret, 0, 'toast.autovacuum_analyze_max_threshold is rejected');

# Lower the global GUC to 80 and reload: t_global is now capped at 80,
# while t_disabled (-1) remains uncapped at 550.
$node->append_conf('postgresql.conf',
	"autovacuum_analyze_max_threshold = 80\n");
$node->reload;

is( $node->safe_psql(
		'postgres', qq{
  SELECT analyze_score > 1 FROM pg_stat_autovacuum_scores
  WHERE relid = 't_global'::regclass
}),
	't',
	'global autovacuum_analyze_max_threshold caps t_global analyze_score');

is( $node->safe_psql(
		'postgres', qq{
  SELECT analyze_score < 1 FROM pg_stat_autovacuum_scores
  WHERE relid = 't_disabled'::regclass
}),
	't',
	'per-table autovacuum_analyze_max_threshold = -1 overrides global cap');

# Enable autovacuum and confirm capped tables are autoanalyzed while
# t_disabled (-1) is not.
$node->append_conf('postgresql.conf', "autovacuum = on\n");
$node->reload;

ok( $node->poll_query_until(
		'postgres', qq{
  SELECT count(*) = 3 FROM pg_stat_all_tables
  WHERE relid IN ('t_global'::regclass, 't_per_table'::regclass, 't_zero'::regclass)
    AND last_autoanalyze IS NOT NULL
}),
	'autoanalyze runs on tables exceeding autovacuum_analyze_max_threshold');

is( $node->safe_psql(
		'postgres', qq{
  SELECT last_autoanalyze IS NULL FROM pg_stat_all_tables
  WHERE relid = 't_disabled'::regclass
}),
	't',
	'autoanalyze does not run on table with autovacuum_analyze_max_threshold = -1');

$node->stop;
done_testing();
