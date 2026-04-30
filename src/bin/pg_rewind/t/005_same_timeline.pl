
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

# Test that pg_rewind correctly rewinds across a TLI mismatch buried in a shared
# prefix of the timeline history.  The target has gone through three timelines
# (TLI 1 -> TLI 2 -> TLI 3) while the source independently promoted from TLI 1
# to what is numerically TLI 2 but with a different UUID (TLI 2').  The deepest
# common ancestor is therefore TLI 1, and pg_rewind must rewind the target all
# the way back to the end of TLI 1.
#
#   origin (TLI 1) --+-- node_x --promote--> TLI 2 -- node_a --promote--> TLI 3
#                    |                                  (target: TLI 1->TLI 2->TLI 3)
#                    +-- node_b --promote--> TLI 2'
#                                            (source: TLI 1->TLI 2')
#
# findCommonAncestorTimeline walks forward: TLI 1 entries match (UUID=0 on
# both sides), then TLI 2 vs TLI 2' match on tli and begin but differ on
# UUID, signalling independent promotions.  The algorithm therefore backs up
# to TLI 1 as the common ancestor and sets the divergence point to the end
# of TLI 1.

my $node_origin2 = PostgreSQL::Test::Cluster->new('origin2');
$node_origin2->init(allows_streaming => 1);
$node_origin2->append_conf('postgresql.conf', "wal_keep_size = 320MB\n");
$node_origin2->start;

$node_origin2->safe_psql('postgres', "CREATE TABLE tbl (val text)");
$node_origin2->safe_psql('postgres', "INSERT INTO tbl VALUES ('origin')");
$node_origin2->safe_psql('postgres', 'CHECKPOINT');

# node_x and node_b both start from the same TLI 1 baseline.
my $node_x = PostgreSQL::Test::Cluster->new('node_x');
$node_origin2->backup('backup_x');
$node_x->init_from_backup($node_origin2, 'backup_x', has_streaming => 1);
$node_x->set_standby_mode();
$node_x->start;

my $node_b2 = PostgreSQL::Test::Cluster->new('node_b2');
$node_origin2->backup('backup_b2');
$node_b2->init_from_backup($node_origin2, 'backup_b2', has_streaming => 1);
$node_b2->set_standby_mode();
$node_b2->start;

# Both standbys must be caught up to the same LSN before origin stops, so
# that TLI 2 and TLI 2' both begin at the same WAL position.
$node_origin2->wait_for_catchup($node_x);
$node_origin2->wait_for_catchup($node_b2);
$node_origin2->stop;

# Promote node_x to TLI 2 (UUID-X) and insert a row.  node_b2 is still on
# TLI 1 and has not yet seen any TLI 2 WAL.
$node_x->promote;
$node_x->safe_psql('postgres', "INSERT INTO tbl VALUES ('x')");

# Build node_a2 as a standby of node_x, then promote it to TLI 3.
my $node_a2 = PostgreSQL::Test::Cluster->new('node_a2');
$node_x->backup('backup_a2');
$node_a2->init_from_backup($node_x, 'backup_a2', has_streaming => 1);
$node_a2->set_standby_mode();
$node_a2->start;

$node_x->wait_for_catchup($node_a2);
$node_x->stop;

$node_a2->promote;

# Now promote node_b2 independently from TLI 1 to TLI 2' (UUID-B, != UUID-X).
$node_b2->promote;
$node_b2->safe_psql('postgres', "INSERT INTO tbl VALUES ('b')");

# Rewind node_a2 (TLI 1->TLI 2->TLI 3) from node_b2 (TLI 1->TLI 2') in
# local mode.  The rewind must reach back to the end of TLI 1.
#
# node_a2 was initialised from a streaming backup of node_x taken after
# node_x had already completed segment 4 of TLI 2; that segment therefore
# does not appear in node_a2's pg_wal.  pg_rewind's backward scan for the
# last checkpoint before the divergence point needs that segment, so we
# point restore_command at node_x's pg_wal and use --restore-target-wal.
#
# Note: no row is inserted on TLI 3.  This is intentional: the only
# post-divergence table modification in the target's WAL is the 'x' INSERT
# on TLI 2.  On unpatched code the WAL scan would start from the TLI 2
# shutdown checkpoint (just before TLI 3), miss that earlier insert, and
# leave 'x' in place instead of replacing it with 'b'.
my $node_x_waldir = $node_x->data_dir . "/pg_wal";
$node_a2->append_conf('postgresql.conf',
	"restore_command = 'cp \"$node_x_waldir/%f\" \"%p\"'\n");

$node_a2->stop;
$node_b2->stop;

my $node_a2_pgdata = $node_a2->data_dir;
my $tmp_folder2 = PostgreSQL::Test::Utils::tempdir;
copy("$node_a2_pgdata/postgresql.conf",
	"$tmp_folder2/node_a2-postgresql.conf.tmp");

command_ok(
	[
		'pg_rewind',
		'--debug',
		'--source-pgdata' => $node_b2->data_dir,
		'--target-pgdata' => $node_a2_pgdata,
		'--no-sync',
		'--restore-target-wal',
		'--config-file' => "$tmp_folder2/node_a2-postgresql.conf.tmp",
	],
	'pg_rewind rewinds across mismatched TLI 2 / TLI 2-prime to TLI 1');

move("$tmp_folder2/node_a2-postgresql.conf.tmp",
	"$node_a2_pgdata/postgresql.conf");

# node_a2 should now mirror node_b2: rows from TLI 2 and TLI 3 are gone,
# replaced by node_b2's TLI 2' row.
$node_a2->start;
my $result2 =
  $node_a2->safe_psql('postgres', "SELECT val FROM tbl ORDER BY val");
is($result2, "b\norigin",
	'rewound node reflects source history, not target TLI 2/TLI 3 data');

$node_a2->teardown_node;
$node_b2->teardown_node;
$node_x->teardown_node;
$node_origin2->teardown_node;

done_testing();
