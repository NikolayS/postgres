-- Analysis of WAL compression level test results
-- From the test output:
-- Initial LSN: 0/1750508
-- After level 1 compression: 0/1786728  
-- Before level 9 test: 0/17867F8
-- After level 9 compression: 0/17944D0

-- Convert hex LSNs to decimal for calculation
SELECT 
    '0/1750508'::pg_lsn AS initial_lsn,
    '0/1786728'::pg_lsn AS level1_lsn,
    '0/17867F8'::pg_lsn AS before_level9_lsn,
    '0/17944D0'::pg_lsn AS level9_lsn;

-- Calculate WAL usage for each compression level
SELECT 
    ('0/1786728'::pg_lsn - '0/1750508'::pg_lsn) AS level1_wal_bytes,
    ('0/17944D0'::pg_lsn - '0/17867F8'::pg_lsn) AS level9_wal_bytes;

-- Calculate compression improvement
WITH wal_usage AS (
    SELECT 
        ('0/1786728'::pg_lsn - '0/1750508'::pg_lsn) AS level1_bytes,
        ('0/17944D0'::pg_lsn - '0/17867F8'::pg_lsn) AS level9_bytes
)
SELECT 
    level1_bytes,
    level9_bytes,
    level1_bytes - level9_bytes AS bytes_saved,
    ROUND(((level1_bytes - level9_bytes)::numeric / level1_bytes::numeric) * 100, 2) AS compression_improvement_percent
FROM wal_usage; 