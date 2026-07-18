
# Copyright (c) 2026, PostgreSQL Global Development Group

# Test that CREATE DATABASE ... STRATEGY=WAL_LOG WAL-logs the auxiliary
# relation forks in a way that recovery can reproduce them.
#
# The WAL_LOG strategy copies the template database block by block and
# WAL-logs every page.  Visibility map and free space map pages store
# their entire payload between pd_lower and pd_upper, so they must not be
# logged as standard-layout pages: the full-page-image "hole" optimization
# would elide the payload and replay would zero it, silently emptying the
# copied database's VM and FSM on a standby (or after crash recovery).
# Verify that a standby ends up with the same VM and FSM contents as the
# primary for a database copied with STRATEGY=WAL_LOG.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node_primary = PostgreSQL::Test::Cluster->new('primary');
$node_primary->init(allows_streaming => 1);
# Keep the VM and FSM of the tables involved stable during the test.
$node_primary->append_conf('postgresql.conf', 'autovacuum = off');
$node_primary->start;

# Create a template database whose table has both visibility map bits set
# and free space recorded in the FSM.
$node_primary->safe_psql('postgres', 'CREATE DATABASE src_db');
$node_primary->safe_psql(
	'src_db', qq[
		CREATE EXTENSION pg_visibility;
		CREATE EXTENSION pg_freespacemap;
		CREATE TABLE tab_copied (a int, filler text);
		INSERT INTO tab_copied
			SELECT g, repeat('x', 100) FROM generate_series(1, 5000) g;
		DELETE FROM tab_copied WHERE a % 5 = 0;
	]);
# Set all-visible/all-frozen bits in the VM and record the space freed by
# the deletions in the FSM.
$node_primary->safe_psql('src_db', 'VACUUM (FREEZE) tab_copied');

# Create a standby.
my $backup_name = 'my_backup';
$node_primary->backup($backup_name);
my $node_standby = PostgreSQL::Test::Cluster->new('standby');
$node_standby->init_from_backup($node_primary, $backup_name,
	has_streaming => 1);
$node_standby->start;
$node_primary->wait_for_catchup($node_standby, 'replay');

# Copy the template database using the WAL_LOG strategy and wait for the
# standby to replay the copy.
$node_primary->safe_psql('postgres',
	'CREATE DATABASE dst_db TEMPLATE src_db STRATEGY WAL_LOG');
$node_primary->wait_for_catchup($node_standby, 'replay');

my $vm_query =
  "SELECT all_visible, all_frozen FROM pg_visibility_map_summary('tab_copied')";
my $fsm_query =
  "SELECT count(*), COALESCE(sum(avail), 0) FROM pg_freespace('tab_copied')";

my $primary_vm = $node_primary->safe_psql('dst_db', $vm_query);
my $primary_fsm = $node_primary->safe_psql('dst_db', $fsm_query);

# Sanity checks: the copied table's VM and FSM must have interesting
# contents on the primary, otherwise the comparisons below would pass
# vacuously.
my ($all_visible) = split(/\|/, $primary_vm);
my (undef, $fsm_avail) = split(/\|/, $primary_fsm);
cmp_ok($all_visible, '>', 0,
	'copied table has visibility map bits set on primary');
cmp_ok($fsm_avail, '>', 0, 'copied table has free space recorded on primary');

# The standby must agree with the primary on the copied database's VM and
# FSM contents.
is( $node_standby->safe_psql('dst_db', $vm_query),
	$primary_vm,
	'standby has same visibility map contents as primary after WAL_LOG copy');
is( $node_standby->safe_psql('dst_db', $fsm_query),
	$primary_fsm,
	'standby has same free space map contents as primary after WAL_LOG copy');

done_testing();
