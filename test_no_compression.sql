-- Test WAL size without compression
ALTER SYSTEM SET wal_compression = 'off';
SELECT pg_reload_conf();

CHECKPOINT;

-- Get initial LSN
SELECT pg_current_wal_lsn() AS initial_lsn_no_compression;

-- Create the same test scenario
CREATE TABLE compression_test_no_comp (
    id SERIAL PRIMARY KEY,
    data TEXT
);

-- Insert same data
INSERT INTO compression_test_no_comp (data) 
SELECT repeat('A', 1000) FROM generate_series(1, 100);

-- Same updates to generate FPIs
UPDATE compression_test_no_comp SET data = repeat('B', 1000) WHERE id % 10 = 0;
UPDATE compression_test_no_comp SET data = repeat('C', 1000) WHERE id % 7 = 0;
UPDATE compression_test_no_comp SET data = repeat('D', 1000) WHERE id % 5 = 0;

-- Get final LSN
SELECT pg_current_wal_lsn() AS final_lsn_no_compression;

-- Calculate uncompressed WAL size
SELECT 
    ('0/1750508'::pg_lsn) AS baseline_lsn,
    pg_current_wal_lsn() AS current_lsn,
    (pg_current_wal_lsn() - '0/1750508'::pg_lsn) AS uncompressed_wal_bytes;

-- Clean up
DROP TABLE compression_test_no_comp; 