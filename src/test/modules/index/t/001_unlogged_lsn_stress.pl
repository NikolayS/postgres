# Copyright (c) 2026, PostgreSQL Global Development Group

# Concurrency stress for unlogged hash and GiST indexes: scans running
# concurrently with split-heavy insert workloads must return correct
# results, cross-checked against WAL-logged twin tables holding identical
# data.
#
# Unlogged indexes rely on fake LSNs (XLogGetFakeLSN) for the LSN-based
# split-detection interlocks that logged relations get from real WAL
# insertions: GiST scans compare the LSN they saw on a parent page with a
# child page's NSN to detect concurrent page splits, and the hash AM
# stamps every atomic action's pages with an LSN likewise.  A missed or
# stale fake-LSN assignment (such as the one fixed in hash's
# log_split_page() for unlogged relations) cannot be noticed by purely
# serial tests, so exercise scans while inserts drive bucket/page splits
# in another session.
#
# The interleaving of the two sessions is not controlled (there are no
# injection points in the hash/GiST split paths through which the
# isolation tester could pin down a mid-split scan), so this is a bounded
# stress test: a fixed number of scan iterations runs while the writer's
# bulk inserts execute.  Pass/fail is nonetheless deterministic: the test
# fails only if a scan returns incorrect results or a backend fails.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $scan_iterations = 100;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;

# Reader session, kept across a whole phase so that planner GUCs stick.
# Force index scans; both the plain and bitmap scan paths go through the
# AM's split-detection logic, but plain index scans exercise the
# pin-and-resume machinery harder.
my $reader = $node->background_psql('postgres');
$reader->query_safe(
	q(SET enable_seqscan = off;
	  SET enable_bitmapscan = off;));

# Run one phase of the stress test: with the given setup already done,
# start $writer_sql in a background session and, while it runs, execute
# $probe_sql (which must return expected|expected) a fixed number of
# times in the reader session.
sub run_phase
{
	my ($phase, $writer_sql, $probe_sql, $expected) = @_;

	my $writer = $node->background_psql('postgres');

	# The \echo lets query_until return as soon as the session is up,
	# while the inserts keep running in the background.
	$writer->query_until(qr/writer_running/,
		"\\echo writer_running\n" . $writer_sql);

	my $mismatches = 0;
	foreach my $i (1 .. $scan_iterations)
	{
		my $result = $reader->query_safe($probe_sql);
		if ($result ne $expected)
		{
			$mismatches++;
			diag("$phase scan $i returned '$result', expected '$expected'");
		}
	}
	is($mismatches, 0, "$phase: all concurrent scans returned correct results");

	# Wait for the writer to complete; a failed insert makes psql exit
	# with a nonzero status due to ON_ERROR_STOP.
	ok($writer->quit, "$phase: writer completed");

	# The scans must still be correct once the dust has settled.
	is($reader->query_safe($probe_sql),
		$expected, "$phase: scans correct after writer completed");
	return;
}

# ================================================================
# Phase 1: hash — concurrent bucket splits vs. equality scans
# ================================================================

# Identical preloaded data (keys 1..200, 20 copies each) in an unlogged
# table and a logged twin; those rows must always be found.  The writer
# then inserts a large batch of disjoint keys (> 1000), driving a long
# series of bucket splits that move the preloaded index tuples between
# buckets while the reader probes them.
$node->safe_psql(
	'postgres', q(
	CREATE UNLOGGED TABLE hash_unlogged (k int4);
	CREATE TABLE hash_logged (k int4);
	CREATE INDEX hash_unlogged_idx ON hash_unlogged USING hash (k);
	CREATE INDEX hash_logged_idx ON hash_logged USING hash (k);
	INSERT INTO hash_unlogged SELECT (i % 200) + 1 FROM generate_series(0, 3999) i;
	INSERT INTO hash_logged SELECT (i % 200) + 1 FROM generate_series(0, 3999) i;
));

my $hash_writer_sql = q(
INSERT INTO hash_unlogged SELECT (i % 20000) + 1001 FROM generate_series(1, 200000) i;
INSERT INTO hash_logged SELECT (i % 20000) + 1001 FROM generate_series(1, 200000) i;
);

# 200 index probes per table and iteration; 20 matches per key.
my $hash_probe_sql = q(
SELECT (SELECT sum(c)::text FROM generate_series(1, 200) g,
        LATERAL (SELECT count(*) AS c FROM hash_unlogged WHERE k = g) p)
       || '|' ||
       (SELECT sum(c)::text FROM generate_series(1, 200) g,
        LATERAL (SELECT count(*) AS c FROM hash_logged WHERE k = g) p);
);

run_phase('hash', $hash_writer_sql, $hash_probe_sql, '4000|4000');

# Finally, both tables must contain exactly the same rows.
is( $node->safe_psql(
		'postgres', q(
		SELECT count(*)
		FROM ((TABLE hash_unlogged EXCEPT ALL TABLE hash_logged)
		      UNION ALL
		      (TABLE hash_logged EXCEPT ALL TABLE hash_unlogged)) diff;)),
	'0',
	'hash: unlogged table and logged twin contain identical data');

# ================================================================
# Phase 2: GiST — concurrent page splits vs. bounding-box scans
# ================================================================

# Preloaded points on a 50x40 grid (ids 0..1999) in an unlogged table and
# a logged twin.  The writer inserts many more points into the very same
# region (ids >= 100000), splitting the leaf pages that hold the
# preloaded points, while the reader runs a bounding-box query that must
# always find exactly the 2000 preloaded points.  This is the
# parent-LSN/child-NSN interlock: with a zero or stale NSN, a scan could
# miss tuples moved right by a concurrent page split.
$node->safe_psql(
	'postgres', q(
	CREATE UNLOGGED TABLE gist_unlogged (id int4, p point);
	CREATE TABLE gist_logged (id int4, p point);
	CREATE INDEX gist_unlogged_idx ON gist_unlogged USING gist (p);
	CREATE INDEX gist_logged_idx ON gist_logged USING gist (p);
	INSERT INTO gist_unlogged SELECT i, point(i % 50, i / 50) FROM generate_series(0, 1999) i;
	INSERT INTO gist_logged SELECT i, point(i % 50, i / 50) FROM generate_series(0, 1999) i;
));

my $gist_writer_sql = q(
INSERT INTO gist_unlogged SELECT 100000 + i, point((i % 1000) / 20.0, (i % 800) / 20.0) FROM generate_series(1, 50000) i;
INSERT INTO gist_logged SELECT 100000 + i, point((i % 1000) / 20.0, (i % 800) / 20.0) FROM generate_series(1, 50000) i;
);

my $gist_probe_sql = q(
SELECT (SELECT count(*)::text FROM gist_unlogged
        WHERE p <@ '(49,39),(0,0)'::box AND id < 100000)
       || '|' ||
       (SELECT count(*)::text FROM gist_logged
        WHERE p <@ '(49,39),(0,0)'::box AND id < 100000);
);

run_phase('gist', $gist_writer_sql, $gist_probe_sql, '2000|2000');

# (point has no equality operator, so compare the coordinates)
is( $node->safe_psql(
		'postgres', q(
		SELECT count(*)
		FROM ((SELECT id, p[0], p[1] FROM gist_unlogged
		       EXCEPT ALL
		       SELECT id, p[0], p[1] FROM gist_logged)
		      UNION ALL
		      (SELECT id, p[0], p[1] FROM gist_logged
		       EXCEPT ALL
		       SELECT id, p[0], p[1] FROM gist_unlogged)) diff;)),
	'0',
	'gist: unlogged table and logged twin contain identical data');

$reader->quit;
$node->stop;

done_testing();
