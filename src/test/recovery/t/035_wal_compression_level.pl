# Test WAL compression level functionality
use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Test basic functionality of wal_compression_level parameter
my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init(allows_streaming => 1);

# Enable WAL compression with ZSTD and set compression level
$node->append_conf('postgresql.conf', qq(
wal_compression = 'zstd'
wal_compression_level = 9
));

$node->start;

# Test that the parameter is set correctly
my $result = $node->safe_psql('postgres', 'SHOW wal_compression_level;');
is($result, '9', 'wal_compression_level is set to 9');

# Test that we can change the compression level
$node->safe_psql('postgres', 'ALTER SYSTEM SET wal_compression_level = 1;');
$node->safe_psql('postgres', 'SELECT pg_reload_conf();');

$result = $node->safe_psql('postgres', 'SHOW wal_compression_level;');
is($result, '1', 'wal_compression_level changed to 1');

# Test with LZ4 compression
$node->safe_psql('postgres', 'ALTER SYSTEM SET wal_compression = \'lz4\';');
$node->safe_psql('postgres', 'ALTER SYSTEM SET wal_compression_level = 5;');
$node->safe_psql('postgres', 'SELECT pg_reload_conf();');

$result = $node->safe_psql('postgres', 'SHOW wal_compression;');
is($result, 'lz4', 'wal_compression changed to lz4');

$result = $node->safe_psql('postgres', 'SHOW wal_compression_level;');
is($result, '5', 'wal_compression_level set to 5 with lz4');

# Test that invalid values are rejected
my ($ret, $stdout, $stderr) = $node->psql('postgres', 'SET wal_compression_level = 25;');
isnt($ret, 0, 'Setting wal_compression_level to 25 should fail');
like($stderr, qr/outside the valid range/, 'Error message mentions valid range');

# Generate some WAL to ensure compression is working
$node->safe_psql('postgres', qq(
    CREATE TABLE compression_test (id int, data text);
    INSERT INTO compression_test SELECT i, repeat('test', 100) FROM generate_series(1, 1000) i;
    UPDATE compression_test SET data = repeat('updated', 100) WHERE id % 10 = 0;
));

# Reset to defaults
$node->safe_psql('postgres', 'ALTER SYSTEM SET wal_compression = \'off\';');
$node->safe_psql('postgres', 'ALTER SYSTEM SET wal_compression_level = 0;');
$node->safe_psql('postgres', 'SELECT pg_reload_conf();');

$result = $node->safe_psql('postgres', 'SHOW wal_compression;');
is($result, 'off', 'wal_compression reset to off');

$result = $node->safe_psql('postgres', 'SHOW wal_compression_level;');
is($result, '0', 'wal_compression_level reset to 0');

$node->stop;

done_testing(); 