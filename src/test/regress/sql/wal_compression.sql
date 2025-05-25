--
-- Test WAL compression level functionality
--

-- Test basic parameter existence and default value
SHOW wal_compression_level;

-- Test setting valid compression levels
SET wal_compression_level = 0;
SHOW wal_compression_level;

SET wal_compression_level = 1;
SHOW wal_compression_level;

SET wal_compression_level = 9;
SHOW wal_compression_level;

SET wal_compression_level = 22;
SHOW wal_compression_level;

-- Test invalid compression levels (should fail)
SET wal_compression_level = -1;
SET wal_compression_level = 23;

-- Test with different compression algorithms
-- Note: These tests check parameter validation, not actual compression
-- since compression effectiveness depends on the specific workload

-- Test ZSTD compression levels
SET wal_compression = 'zstd';
SET wal_compression_level = 1;
SHOW wal_compression;
SHOW wal_compression_level;

SET wal_compression_level = 22;
SHOW wal_compression_level;

-- Test LZ4 compression levels  
SET wal_compression = 'lz4';
SET wal_compression_level = 1;
SHOW wal_compression;
SHOW wal_compression_level;

SET wal_compression_level = 12;
SHOW wal_compression_level;

-- Test PGLZ (compression level should be accepted but ignored)
SET wal_compression = 'pglz';
SET wal_compression_level = 5;
SHOW wal_compression;
SHOW wal_compression_level;

-- Reset to defaults
SET wal_compression = 'off';
SET wal_compression_level = 0;
SHOW wal_compression;
SHOW wal_compression_level; 