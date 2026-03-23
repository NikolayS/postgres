
# Test: Statistics migration during pg_upgrade from older major versions
#
# Verifies that pg_upgrade preserves planner statistics (relation-level
# and attribute-level) when upgrading from PG16 (and by extension PG17)
# to the current version (PG18+/19devel).
#
# The statistics dump/restore feature was introduced in PG18. It works by
# having the NEW version's pg_dump (with --statistics flag) connect to the
# OLD cluster and dump statistics using pg_restore_relation_stats() and
# pg_restore_attribute_stats() calls. Since these functions exist only in
# the new server, and pg_dump reads stats from standard catalog views
# (pg_stats, pg_class) that exist in all versions, cross-version stats
# migration works for pg16->pg18+, pg17->pg18+, etc.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# This test requires an old PG installation to be available.
# Skip if we can't find one (e.g., in CI without multi-version setup).
# In a real test environment, you'd configure OLD_BINDIR.

my $old_bindir = $ENV{OLD_BINDIR};

if (!defined $old_bindir || !-x "$old_bindir/initdb")
{
	plan skip_all => 'OLD_BINDIR not set or old binaries not found';
}

my $new_bindir = $ENV{NEW_BINDIR} || PostgreSQL::Test::Utils::pg_config()->{bindir};

# Get old version
my $old_version_output = `"$old_bindir/initdb" --version`;
my ($old_major) = $old_version_output =~ /(\d+)/;

note "Testing stats migration from PG$old_major to current version";
note "Old bindir: $old_bindir";
note "New bindir: $new_bindir";

###############################################################################
# Step 1: Create and populate old cluster
###############################################################################

my $old_cluster = PostgreSQL::Test::Cluster->new('old_cluster',
	install_path => $old_bindir);
$old_cluster->init;
$old_cluster->start;

# Create test data and gather statistics
$old_cluster->safe_psql('postgres', q{
    CREATE TABLE test_stats AS
        SELECT generate_series(1, 100000) AS id,
               random()::text AS val;
    CREATE INDEX ON test_stats(id);
    CREATE INDEX ON test_stats(val);
    ANALYZE test_stats;
});

# Record original statistics
my $orig_reltuples = $old_cluster->safe_psql('postgres',
	"SELECT reltuples FROM pg_class WHERE relname = 'test_stats'");
my $orig_relpages = $old_cluster->safe_psql('postgres',
	"SELECT relpages FROM pg_class WHERE relname = 'test_stats'");
my $orig_n_distinct_id = $old_cluster->safe_psql('postgres',
	"SELECT n_distinct FROM pg_stats WHERE tablename = 'test_stats' AND attname = 'id'");
my $orig_avg_width_val = $old_cluster->safe_psql('postgres',
	"SELECT avg_width FROM pg_stats WHERE tablename = 'test_stats' AND attname = 'val'");
my $orig_correlation_id = $old_cluster->safe_psql('postgres',
	"SELECT correlation FROM pg_stats WHERE tablename = 'test_stats' AND attname = 'id'");

note "Original stats: reltuples=$orig_reltuples, relpages=$orig_relpages";
note "Original n_distinct(id)=$orig_n_distinct_id, avg_width(val)=$orig_avg_width_val";

###############################################################################
# Step 2: Test pg_dump --statistics-only from new binary against old cluster
###############################################################################

my $dump_output = `"$new_bindir/pg_dump" -p @{[$old_cluster->port]} -d postgres --statistics-only 2>&1`;
my $dump_rc = $?;

is($dump_rc, 0, "pg_dump --statistics-only succeeds against PG$old_major");
like($dump_output, qr/pg_restore_relation_stats/,
	"dump contains pg_restore_relation_stats calls");
like($dump_output, qr/pg_restore_attribute_stats/,
	"dump contains pg_restore_attribute_stats calls");
like($dump_output, qr/'reltuples'.*'100000'/,
	"dump contains correct reltuples value");

###############################################################################
# Step 3: Full pg_upgrade and verify stats preserved
###############################################################################

$old_cluster->stop;

my $new_cluster = PostgreSQL::Test::Cluster->new('new_cluster');
$new_cluster->init;

# Run pg_upgrade
my $upgrade_dir = PostgreSQL::Test::Utils::tempdir;
my @upgrade_cmd = (
	"$new_bindir/pg_upgrade",
	'--old-bindir' => $old_bindir,
	'--new-bindir' => $new_bindir,
	'--old-datadir' => $old_cluster->data_dir,
	'--new-datadir' => $new_cluster->data_dir,
	'--old-port' => $old_cluster->port,
	'--new-port' => $new_cluster->port,
	'--socketdir' => PostgreSQL::Test::Utils::tempdir,
);

my ($stdout, $stderr);
my $rc = PostgreSQL::Test::Utils::run_log(\@upgrade_cmd, '>', \$stdout, '2>', \$stderr);
is($rc, 0, "pg_upgrade from PG$old_major succeeds");

if ($rc != 0)
{
	diag "pg_upgrade stdout: $stdout";
	diag "pg_upgrade stderr: $stderr";
	BAIL_OUT("pg_upgrade failed, cannot verify statistics");
}

# Start new cluster and verify statistics
$new_cluster->start;

my $new_reltuples = $new_cluster->safe_psql('postgres',
	"SELECT reltuples FROM pg_class WHERE relname = 'test_stats'");
my $new_relpages = $new_cluster->safe_psql('postgres',
	"SELECT relpages FROM pg_class WHERE relname = 'test_stats'");
my $new_n_distinct_id = $new_cluster->safe_psql('postgres',
	"SELECT n_distinct FROM pg_stats WHERE tablename = 'test_stats' AND attname = 'id'");
my $new_avg_width_val = $new_cluster->safe_psql('postgres',
	"SELECT avg_width FROM pg_stats WHERE tablename = 'test_stats' AND attname = 'val'");
my $new_correlation_id = $new_cluster->safe_psql('postgres',
	"SELECT correlation FROM pg_stats WHERE tablename = 'test_stats' AND attname = 'id'");

# Verify relation-level stats
is($new_reltuples, $orig_reltuples,
	"reltuples preserved after upgrade from PG$old_major");
is($new_relpages, $orig_relpages,
	"relpages preserved after upgrade from PG$old_major");

# Verify attribute-level stats
is($new_n_distinct_id, $orig_n_distinct_id,
	"n_distinct preserved after upgrade from PG$old_major");
is($new_avg_width_val, $orig_avg_width_val,
	"avg_width preserved after upgrade from PG$old_major");
is($new_correlation_id, $orig_correlation_id,
	"correlation preserved after upgrade from PG$old_major");

# Also verify index stats survived
my $idx_reltuples = $new_cluster->safe_psql('postgres',
	"SELECT reltuples FROM pg_class WHERE relname = 'test_stats_id_idx'");
is($idx_reltuples, '100000',
	"index reltuples preserved after upgrade from PG$old_major");

$new_cluster->stop;

done_testing();
