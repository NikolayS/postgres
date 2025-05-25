-- Test script for wal_compression_level feature
-- First, enable WAL compression with ZSTD
ALTER SYSTEM SET wal_compression = 'zstd';
ALTER SYSTEM SET wal_compression_level = 1;
SELECT pg_reload_conf();

-- Force a checkpoint to start fresh
CHECKPOINT;

-- Get initial LSN
SELECT pg_current_wal_lsn() AS initial_lsn;

-- Create a test table and generate some WAL with full page images
CREATE TABLE compression_test (
    id SERIAL PRIMARY KEY,
    data TEXT
);

-- Insert some data to fill pages
INSERT INTO compression_test (data) 
SELECT repeat('A', 1000) FROM generate_series(1, 100);

-- Force full page writes by updating scattered rows
UPDATE compression_test SET data = repeat('B', 1000) WHERE id % 10 = 0;
UPDATE compression_test SET data = repeat('C', 1000) WHERE id % 7 = 0;
UPDATE compression_test SET data = repeat('D', 1000) WHERE id % 5 = 0;

-- Get LSN after level 1 compression
SELECT pg_current_wal_lsn() AS level1_lsn;

-- Now test with higher compression level
ALTER SYSTEM SET wal_compression_level = 9;
SELECT pg_reload_conf();

-- Force checkpoint to apply new settings
CHECKPOINT;

-- Get LSN before level 9 test
SELECT pg_current_wal_lsn() AS before_level9_lsn;

-- Generate similar WAL activity
UPDATE compression_test SET data = repeat('E', 1000) WHERE id % 10 = 1;
UPDATE compression_test SET data = repeat('F', 1000) WHERE id % 7 = 1;
UPDATE compression_test SET data = repeat('G', 1000) WHERE id % 5 = 1;

-- Get final LSN
SELECT pg_current_wal_lsn() AS level9_lsn;

-- Show current settings
SHOW wal_compression;
SHOW wal_compression_level;

-- Clean up
DROP TABLE compression_test; 