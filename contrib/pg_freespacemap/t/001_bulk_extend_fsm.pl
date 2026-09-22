# Copyright (c) 2026, PostgreSQL Global Development Group

# Regression coverage for commit a2fd8d6 ("Include last block in FSM vacuum of
# bulk extended relation").
#
# When a relation is bulk-extended, hio.c records the newly added, not
# immediately used blocks in the free space map and then calls
# FreeSpaceMapVacuumRange() to propagate that free space up the FSM tree so
# other backends can find it.  The end block argument of
# FreeSpaceMapVacuumRange() is *exclusive*, but the code used to pass the number
# of the last added block.  When that last block was the first block covered by
# a brand new FSM leaf page (heap block SlotsPerFSMPage, 2*SlotsPerFSMPage, ...),
# its free space was recorded in the leaf FSM page but never propagated to the
# upper FSM levels, staying invisible to FSM searches until the next full FSM
# vacuum.
#
# The test bulk-extends a relation with COPY (which uses a BulkInsertState, and
# so takes the bulk-extension code path) so that the final extension's last
# block lands exactly on an FSM leaf-page boundary.  It then checks the
# invariant that a2fd8d6 restores: because the bulk extension has already
# propagated the new free space, an immediately following VACUUM must not raise
# any FSM node value.  With the bug present the boundary block's free space is
# missing from the upper FSM levels, so the redundant VACUUM raises the parent
# node from 0, and the test fails.  (pg_freespace() reads the leaf value
# directly and is unaffected by the bug, so it cannot be used to detect it.)

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
# Autovacuum (or any other FSM vacuum) would repair the upper FSM levels and
# mask the bug, so keep it firmly disabled.
$node->append_conf('postgresql.conf', 'autovacuum = off');
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION pg_freespacemap; CREATE EXTENSION pageinspect;');

my $bs = $node->safe_psql('postgres', 'SHOW block_size') + 0;

# SlotsPerFSMPage -- the number of heap blocks covered by one FSM leaf page,
# and thus the first heap block of the second FSM leaf page.  This is only used
# to size the test relation so that a bulk extension lands on the boundary; the
# bug detection below needs no knowledge of the FSM page layout.  See
# src/include/storage/fsm_internals.h: with SizeOfPageHeaderData = 24 and
# offsetof(FSMPageData, fp_nodes) = 4, SlotsPerFSMPage = BLCKSZ/2 - 27.
my $boundary = int($bs / 2) - 27;

# Measure how many of our narrow (single int) tuples fit on a heap page by
# filling more than one page and counting the tuples that landed on block 0,
# which is necessarily full.
$node->safe_psql('postgres',
	'CREATE TABLE probe (c int) WITH (autovacuum_enabled = off);');
$node->safe_psql('postgres',
	'INSERT INTO probe SELECT generate_series(1, 5000);');
my $rpb = $node->safe_psql('postgres',
	"SELECT count(*) FROM probe WHERE (ctid::text::point)[0]::int = 0;") + 0;
ok($rpb > 0, "measured $rpb tuples per heap block");

# Helper: COPY the values 1..$n into an existing table.  safe_psql() feeds the
# script to psql's stdin, so we can inline the COPY data after the command and
# terminate it with a backslash-dot, like a hand-written psql script.  COPY uses
# a BulkInsertState, which is what exercises the bulk-extension code path.
sub bulk_copy
{
	my ($table, $n) = @_;
	my $script = "COPY $table FROM STDIN;\n" . join("\n", 1 .. $n) . "\n\\.\n";
	$node->safe_psql('postgres', $script);
	return;
}

# The relation is extended in chunks; once the extension size saturates at
# MAX_BUFFERS_TO_EXTEND_BY (64) the relation size after a COPY is congruent to a
# fixed value modulo 64, independent of how many rows were copied.  Learn that
# offset with a small COPY into a separately committed table (a table created in
# the same transaction as the COPY would skip the FSM entirely).
$node->safe_psql('postgres',
	'CREATE TABLE grid_probe (c int) WITH (autovacuum_enabled = off);');
bulk_copy('grid_probe', 300 * $rpb);
my $offset =
  ($node->safe_psql('postgres', "SELECT pg_relation_size('grid_probe') / $bs;")
	  + 0) % 64;

# To make the final extension end exactly on the boundary block, shift the
# extension grid by pre-filling some fully packed blocks (committed densely, so
# nothing is left in the FSM), then bulk-extend across the boundary with one
# COPY that leaves the data about 32 blocks short of the boundary.
my $shift = (($boundary + 1) - $offset) % 64;

$node->safe_psql('postgres',
	'CREATE TABLE fsm_boundary (c int) WITH (autovacuum_enabled = off);');
$node->safe_psql('postgres',
	"INSERT INTO fsm_boundary SELECT generate_series(1, $shift * $rpb);")
  if $shift > 0;
bulk_copy('fsm_boundary', ($boundary - 32 - $shift) * $rpb);

# Confirm we built the intended geometry: the relation has exactly boundary + 1
# blocks (the last extended block is the boundary block), and that block is a
# trailing block whose free space was recorded in the leaf FSM page.
my $nblocks = $node->safe_psql('postgres',
	"SELECT pg_relation_size('fsm_boundary') / $bs;") + 0;
is($nblocks, $boundary + 1,
	"relation bulk-extended to the FSM leaf-page boundary ($nblocks blocks)");

my $leaf_avail = $node->safe_psql('postgres',
	"SELECT pg_freespace('fsm_boundary', $boundary);") + 0;
ok($leaf_avail > 0,
	"boundary block $boundary has free space in the leaf FSM page");

# The core regression check.  Snapshot every non-zero FSM node, run a redundant
# VACUUM, and confirm it raised no node value.  A VACUUM legitimately *lowers*
# stale entries for partially filled pages, but it may only *raise* a node if
# the bulk extension failed to propagate free space up the tree -- exactly the
# a2fd8d6 bug.  All of this runs in one psql session so the pre-VACUUM snapshot
# (a temp table) survives, and VACUUM runs outside any transaction block.
my $raised = $node->safe_psql('postgres', qq{
	CREATE TEMP TABLE fsm_before AS
	    SELECT blk,
	           split_part(line, ':', 1)::int AS node,
	           split_part(line, ':', 2)::int AS val
	      FROM generate_series(0, pg_relation_size('fsm_boundary', 'fsm') / $bs - 1) blk,
	           LATERAL regexp_split_to_table(
	               fsm_page_contents(get_raw_page('fsm_boundary', 'fsm', blk)),
	               E'\\n') AS line
	     WHERE line LIKE '%:%' AND line NOT LIKE 'fp_next_slot%';

	VACUUM fsm_boundary;

	SELECT count(*)
	  FROM (SELECT blk,
	               split_part(line, ':', 1)::int AS node,
	               split_part(line, ':', 2)::int AS val
	          FROM generate_series(0, pg_relation_size('fsm_boundary', 'fsm') / $bs - 1) blk,
	               LATERAL regexp_split_to_table(
	                   fsm_page_contents(get_raw_page('fsm_boundary', 'fsm', blk)),
	                   E'\\n') AS line
	         WHERE line LIKE '%:%' AND line NOT LIKE 'fp_next_slot%') AS fsm_after
	  LEFT JOIN fsm_before USING (blk, node)
	 WHERE fsm_after.val > COALESCE(fsm_before.val, 0);
});
is($raised, '0',
	'bulk extension propagated boundary free space: redundant VACUUM raises no FSM node'
);

$node->stop;

done_testing();
