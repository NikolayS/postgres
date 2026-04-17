# Copyright (c) 2026, PostgreSQL Global Development Group

# Check that pg_stat_database.xact_rollback on a logical-replication
# publisher is not inflated by the walsender's internal catalog-cleanup
# aborts.  ReorderBufferProcessTXN() ends each decoded transaction with
# AbortCurrentTransaction(); in the walsender that is a top-level abort
# whose counter increment flushes to shared stats on walsender exit.
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node_publisher = PostgreSQL::Test::Cluster->new('publisher');
$node_publisher->init(allows_streaming => 'logical');
$node_publisher->start;

my $node_subscriber = PostgreSQL::Test::Cluster->new('subscriber');
$node_subscriber->init;
$node_subscriber->start;

$node_publisher->safe_psql('postgres',
	'CREATE TABLE t (id int PRIMARY KEY)');
$node_subscriber->safe_psql('postgres',
	'CREATE TABLE t (id int PRIMARY KEY)');

$node_publisher->safe_psql('postgres', 'CREATE PUBLICATION p FOR TABLE t');

my $publisher_connstr = $node_publisher->connstr . ' dbname=postgres';
$node_subscriber->safe_psql('postgres',
	"CREATE SUBSCRIPTION s CONNECTION '$publisher_connstr' PUBLICATION p");

$node_subscriber->wait_for_subscription_sync($node_publisher, 's');

# Use a baseline-delta rather than pg_stat_reset() to tolerate ambient
# rollback activity.
my $base = $node_publisher->safe_psql('postgres',
	"SELECT xact_rollback FROM pg_stat_database WHERE datname = 'postgres'");
chomp $base;

# Five autocommit INSERTs: each becomes one decoded committed txn on the
# walsender.  Without the fix, that's five spurious rollbacks after DISABLE.
my $n = 5;
$node_publisher->safe_psql('postgres',
	join('', map { "INSERT INTO t VALUES ($_);\n" } 1 .. $n));

$node_publisher->wait_for_catchup('s');

# Disabling the subscription terminates the walsender; its shutdown hook
# flushes pgstat counters to shared stats.
$node_subscriber->safe_psql('postgres', 'ALTER SUBSCRIPTION s DISABLE');

# Wait for this subscription's walsender (filter by application_name).
$node_publisher->poll_query_until(
	'postgres', q{
	SELECT count(*) = 0 FROM pg_stat_activity
	WHERE backend_type = 'walsender' AND application_name = 's'
})
  or die 's walsender did not exit';

my $final = $node_publisher->safe_psql('postgres',
	"SELECT xact_rollback FROM pg_stat_database WHERE datname = 'postgres'");
chomp $final;

cmp_ok(
	$final - $base, '==', 0,
	'walsender does not inflate publisher xact_rollback for decoded transactions'
);

done_testing();
