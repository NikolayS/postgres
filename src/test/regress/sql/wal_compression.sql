--
-- Test WAL compression functionality with method:level syntax
--

-- Test basic parameter existence and default value
SHOW wal_compression;

-- Test setting compression methods without levels
SET wal_compression = 'off';
SHOW wal_compression;

SET wal_compression = 'pglz';
SHOW wal_compression;

SET wal_compression = 'lz4';
SHOW wal_compression;

SET wal_compression = 'zstd';
SHOW wal_compression;

-- Test setting compression methods with levels
SET wal_compression = 'lz4:1';
SHOW wal_compression;

SET wal_compression = 'lz4:9';
SHOW wal_compression;

-- Note: LZ4HC levels (10-12) are not tested here because their availability
-- depends on build configuration (HAVE_LZ4HC_H). On builds without LZ4HC,
-- these levels are rejected at SET time with appropriate error messages.

SET wal_compression = 'zstd:1';
SHOW wal_compression;

SET wal_compression = 'zstd:9';
SHOW wal_compression;

SET wal_compression = 'zstd:22';
SHOW wal_compression;

-- Test invalid compression levels (should fail)
SET wal_compression = 'lz4:0';
SET wal_compression = 'lz4:13';
SET wal_compression = 'zstd:0';
SET wal_compression = 'zstd:23';

-- Test PGLZ with levels (should fail)
SET wal_compression = 'pglz:1';

-- Test invalid compression methods (should fail)
SET wal_compression = 'invalid';
SET wal_compression = 'gzip';

-- Test malformed syntax (should fail)
SET wal_compression = 'lz4:';
SET wal_compression = 'lz4:abc';
SET wal_compression = ':5';

-- Reset to default
SET wal_compression = 'off';
SHOW wal_compression;
