# Copyright (c) 2026, PostgreSQL Global Development Group

=pod

=head1 NAME

CombineBackupTest - helper routines for pg_combinebackup TAP tests

=head1 SYNOPSIS

  use FindBin;
  use lib $FindBin::RealBin;
  use CombineBackupTest;

  check_physical_consistency($node, 'some label', 'indexed_table', 'a');

=head1 DESCRIPTION

Physical-consistency checks ("oracle") run against restored clusters.
A logical dump can only see live row contents through sequential scans,
so comparing pg_dumpall output is blind to physical-level problems that
pg_combinebackup could introduce: stale visibility map bits, index
corruption, or other damage to data that a sequential scan does not
consult.  The routines here check those directly.

The individual building blocks (vm_sweep_errors, ios_vs_seqscan) are
also exported so that a negative-control test can assert that the
checks really do fire on corrupted clusters.

=cut

package CombineBackupTest;

use strict;
use warnings FATAL => 'all';

use Exporter 'import';
use Test::More;

our @EXPORT = qw(
  connectable_databases
  vm_sweep_errors
  ios_vs_seqscan
  check_physical_consistency
);

# Return the names of all connectable databases in the cluster.
sub connectable_databases
{
	my ($node) = @_;
	my $datnames = $node->safe_psql('postgres',
		"SELECT datname FROM pg_database WHERE datallowconn ORDER BY datname");
	return split(/\n/, $datnames);
}

# Ask pg_visibility to cross-check the visibility map against the heap for
# every user relation (tables, materialized views, toast tables) in the
# given database. Returns an empty string if no problems were found, else
# one line per corrupt relation listing the number of TIDs flagged by
# pg_check_visible() and pg_check_frozen().
sub vm_sweep_errors
{
	my ($node, $dbname) = @_;

	$node->safe_psql($dbname, 'CREATE EXTENSION IF NOT EXISTS pg_visibility');
	return $node->safe_psql($dbname, q{
		SELECT relation, bad_visible, bad_frozen
		FROM (SELECT c.oid::regclass AS relation,
			  (SELECT count(*) FROM pg_check_visible(c.oid)) AS bad_visible,
			  (SELECT count(*) FROM pg_check_frozen(c.oid)) AS bad_frozen
		      FROM pg_class c
		      WHERE c.relkind IN ('r', 'm', 't')
			AND c.oid >= 16384) s
		WHERE bad_visible > 0 OR bad_frozen > 0
	});
}

# Run the same aggregate over the given table with a forced index-only scan
# (which trusts the visibility map) and a forced sequential scan (which does
# not). Returns the forced index-only-scan plan and both results, so the
# caller can assert that the plan really is an index-only scan and that the
# two results agree (or, in a negative test, disagree).
sub ios_vs_seqscan
{
	my ($node, $dbname, $table, $column) = @_;

	my $query =
	  "SELECT count(*), sum($column), min($column), max($column) FROM $table";
	my $ios_plan = $node->safe_psql(
		$dbname, qq{
		SET enable_seqscan = off;
		SET enable_bitmapscan = off;
		SET enable_indexonlyscan = on;
		EXPLAIN (COSTS OFF) $query;
	});
	my $ios_result = $node->safe_psql(
		$dbname, qq{
		SET enable_seqscan = off;
		SET enable_bitmapscan = off;
		SET enable_indexonlyscan = on;
		$query;
	});
	my $seq_result = $node->safe_psql(
		$dbname, qq{
		SET enable_indexscan = off;
		SET enable_indexonlyscan = off;
		SET enable_bitmapscan = off;
		$query;
	});
	return ($ios_plan, $ios_result, $seq_result);
}

# Run the full set of physical consistency checks against a restored
# cluster:
#
# 1. pg_amcheck over every database, verifying heap and index consistency.
#    --heapallindexed also verifies that every heap tuple is found in the
#    expected indexes.
#
# 2. A pg_visibility sweep over every user relation in every connectable
#    database, asserting that no stale all-visible or all-frozen bits
#    exist. Stale VM bits are invisible to a logical dump but corrupt
#    index-only scan results and can cause future heap corruption once
#    vacuum trusts them.
#
# 3. A forced index-only scan vs forced sequential scan comparison over
#    $ios_table.$ios_column (in database "postgres"), which is the
#    user-visible symptom of stale all-visible bits.
sub check_physical_consistency
{
	my ($node, $label, $ios_table, $ios_column) = @_;
	local $Test::Builder::Level = $Test::Builder::Level + 1;

	$node->command_ok(
		[ 'pg_amcheck', '--all', '--install-missing', '--heapallindexed' ],
		"$label: pg_amcheck reports no corruption");

	foreach my $dbname (connectable_databases($node))
	{
		is(vm_sweep_errors($node, $dbname),
			'', "$label: no stale VM bits in database $dbname");
	}

	my ($ios_plan, $ios_result, $seq_result) =
	  ios_vs_seqscan($node, 'postgres', $ios_table, $ios_column);
	like(
		$ios_plan,
		qr/Index Only Scan/,
		"$label: aggregate query uses an index-only scan when forced");
	is($ios_result, $seq_result,
		"$label: index-only scan and seqscan agree");
	return;
}

1;
