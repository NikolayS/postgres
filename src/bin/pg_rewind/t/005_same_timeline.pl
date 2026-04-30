
# Copyright (c) 2021-2026, PostgreSQL Global Development Group

#
# Test that running pg_rewind with the source and target clusters
# on the same timeline runs successfully.
#
use strict;
use warnings FATAL => 'all';
use File::Copy;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use RewindTest;

RewindTest::setup_cluster();
RewindTest::start_primary();
RewindTest::create_standby();
RewindTest::run_pg_rewind('local');
RewindTest::clean_rewind_test();

# Test that pg_rewind detects and handles two standbys that independently
# promoted to the same timeline ID.  Before the UUID-based divergence check,
# pg_rewind's same-TLI shortcut would incorrectly skip the rewind in this
# case, leaving the target's diverged WAL intact.
#
#   origin (TLI 1)
#       |
#       +--- node_a (TLI 1) --promote--> TLI 2, UUID-A  (target)
#       |
#       +--- node_b (TLI 1) --promote--> TLI 2, UUID-B  (source)
#
# pg_rewind must detect the UUID mismatch and rewind node_a to match node_b.

my $node_origin = PostgreSQL::Test::Cluster->new('origin');
$node_origin->init(allows_streaming => 1);
$node_origin->append_conf('postgresql.conf', "wal_keep_size = 320MB\n");
$node_origin->start;

$node_origin->safe_psql('postgres', "CREATE TABLE tbl (val text)");
$node_origin->safe_psql('postgres', "INSERT INTO tbl VALUES ('initial')");
$node_origin->safe_psql('postgres', 'CHECKPOINT');

# Create node_a and node_b from separate backups of origin so that each
# has its own data directory and will generate an independent UUID on promotion.
my $node_a = PostgreSQL::Test::Cluster->new('node_a');
$node_origin->backup('backup_a');
$node_a->init_from_backup($node_origin, 'backup_a', has_streaming => 1);
$node_a->set_standby_mode();
$node_a->start;

my $node_b = PostgreSQL::Test::Cluster->new('node_b');
$node_origin->backup('backup_b');
$node_b->init_from_backup($node_origin, 'backup_b', has_streaming => 1);
$node_b->set_standby_mode();
$node_b->start;

# Wait for both standbys to catch up to origin, then stop origin.  After
# this point the two standbys are isolated and will promote independently.
$node_origin->wait_for_catchup($node_a);
$node_origin->wait_for_catchup($node_b);
$node_origin->stop;

# Promote both standbys.  Each lands on TLI 2 but generates a distinct UUID,
# so the resulting clusters are diverged even though they share a timeline ID.
$node_a->promote;
$node_b->promote;

# Insert a divergent row on each so the rewind has visible work to do.
$node_a->safe_psql('postgres', "INSERT INTO tbl VALUES ('in A')");
$node_b->safe_psql('postgres', "INSERT INTO tbl VALUES ('in B')");

# Stop both nodes; rewind node_a (target) from node_b (source) in local mode.
$node_a->stop;
$node_b->stop;

my $node_a_pgdata = $node_a->data_dir;
my $tmp_folder = PostgreSQL::Test::Utils::tempdir;
copy("$node_a_pgdata/postgresql.conf",
	"$tmp_folder/node_a-postgresql.conf.tmp");

command_ok(
	[
		'pg_rewind',
		'--debug',
		'--source-pgdata' => $node_b->data_dir,
		'--target-pgdata' => $node_a_pgdata,
		'--no-sync',
		'--config-file' => "$tmp_folder/node_a-postgresql.conf.tmp",
	],
	'pg_rewind handles independent same-TLI promotion');

move("$tmp_folder/node_a-postgresql.conf.tmp",
	"$node_a_pgdata/postgresql.conf");

# node_a should now mirror node_b: it has 'initial' and 'in B', not 'in A'.
$node_a->start;
my $result =
  $node_a->safe_psql('postgres', "SELECT val FROM tbl ORDER BY val");
is($result, "in B\ninitial",
	'rewound node has source data, not its own divergent data');

$node_a->teardown_node;
$node_b->teardown_node;
$node_origin->teardown_node;

done_testing();
