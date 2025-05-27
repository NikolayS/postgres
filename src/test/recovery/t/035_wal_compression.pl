# Test WAL compression functionality with new single-parameter design
use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Test basic functionality of wal_compression parameter with method:level syntax
my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init(allows_streaming => 1);

# Enable WAL compression with ZSTD and compression level
$node->append_conf('postgresql.conf', qq(
wal_compression = 'zstd:9'
));

$node->start;

# Test that the parameter is set correctly
my $result = $node->safe_psql('postgres', 'SHOW wal_compression;');
is($result, 'zstd:9', 'wal_compression is set to zstd:9');

# Test that we can change the compression method and level
$node->safe_psql('postgres', 'ALTER SYSTEM SET wal_compression = \'lz4:5\';');
$node->safe_psql('postgres', 'SELECT pg_reload_conf();');

$result = $node->safe_psql('postgres', 'SHOW wal_compression;');
is($result, 'lz4:5', 'wal_compression changed to lz4:5');

# Test method without level (should use defaults)
$node->safe_psql('postgres', 'ALTER SYSTEM SET wal_compression = \'zstd\';');
$node->safe_psql('postgres', 'SELECT pg_reload_conf();');

$result = $node->safe_psql('postgres', 'SHOW wal_compression;');
is($result, 'zstd', 'wal_compression set to zstd without level');

# Test PGLZ (no levels supported)
$node->safe_psql('postgres', 'ALTER SYSTEM SET wal_compression = \'pglz\';');
$node->safe_psql('postgres', 'SELECT pg_reload_conf();');

$result = $node->safe_psql('postgres', 'SHOW wal_compression;');
is($result, 'pglz', 'wal_compression set to pglz');

# Test that invalid values are rejected
my ($ret, $stdout, $stderr) = $node->psql('postgres', 'SET wal_compression = \'lz4:25\';');
isnt($ret, 0, 'Setting wal_compression to lz4:25 should fail');
like($stderr, qr/LZ4 compression level must be between 1 and 12/, 'Error message mentions LZ4 valid range');

# Test invalid ZSTD level
($ret, $stdout, $stderr) = $node->psql('postgres', 'SET wal_compression = \'zstd:25\';');
isnt($ret, 0, 'Setting wal_compression to zstd:25 should fail');
like($stderr, qr/ZSTD compression level must be between 1 and 22/, 'Error message mentions ZSTD valid range');

# Test PGLZ with level (should fail)
($ret, $stdout, $stderr) = $node->psql('postgres', 'SET wal_compression = \'pglz:5\';');
isnt($ret, 0, 'Setting wal_compression to pglz:5 should fail');
like($stderr, qr/PGLZ compression does not support compression levels/, 'Error message mentions PGLZ no levels');

# Test invalid method
($ret, $stdout, $stderr) = $node->psql('postgres', 'SET wal_compression = \'invalid\';');
isnt($ret, 0, 'Setting wal_compression to invalid method should fail');

# Generate some WAL to ensure compression is working
$node->safe_psql('postgres', qq(
    CREATE TABLE compression_test (id int, data text);
    INSERT INTO compression_test SELECT i, repeat('test', 100) FROM generate_series(1, 1000) i;
    UPDATE compression_test SET data = repeat('updated', 100) WHERE id % 10 = 0;
));

# Test various valid combinations
my @valid_settings = (
    'off',
    'pglz', 
    'lz4',
    'lz4:1',
    'lz4:12',
    'zstd',
    'zstd:1',
    'zstd:22'
);

foreach my $setting (@valid_settings) {
    $node->safe_psql('postgres', "ALTER SYSTEM SET wal_compression = '$setting';");
    $node->safe_psql('postgres', 'SELECT pg_reload_conf();');
    
    $result = $node->safe_psql('postgres', 'SHOW wal_compression;');
    is($result, $setting, "wal_compression successfully set to $setting");
}

# Reset to default
$node->safe_psql('postgres', 'ALTER SYSTEM SET wal_compression = \'off\';');
$node->safe_psql('postgres', 'SELECT pg_reload_conf();');

$result = $node->safe_psql('postgres', 'SHOW wal_compression;');
is($result, 'off', 'wal_compression reset to off');

$node->stop;

done_testing();
