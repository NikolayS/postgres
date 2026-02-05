-- Test pg_stat_statements_nsp extension
-- This extension works without shared_preload_libraries

-- First, ensure compute_query_id is enabled
SET compute_query_id = on;

-- Load the extension module (this simulates loading via LOAD command)
LOAD 'pg_stat_statements_nsp';

-- Create the extension (installs functions and views)
CREATE EXTENSION pg_stat_statements_nsp;

-- Reset any existing statistics
SELECT pg_stat_statements_nsp_reset();

-- Run some test queries
SELECT 1 AS simple_select;
SELECT 1 + 1 AS addition;
SELECT generate_series(1, 5);

-- Create a test table and run some queries on it
CREATE TABLE test_nsp (id int, val text);
INSERT INTO test_nsp VALUES (1, 'one'), (2, 'two'), (3, 'three');
SELECT * FROM test_nsp WHERE id = 1;
UPDATE test_nsp SET val = 'ONE' WHERE id = 1;
DELETE FROM test_nsp WHERE id = 3;

-- Check that we have recorded statistics
-- Note: We check for non-zero calls rather than exact counts
-- because query IDs might vary across runs
SELECT
    calls > 0 AS has_calls,
    total_time >= 0 AS has_time,
    rows >= 0 AS has_rows
FROM pg_stat_statements_nsp
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
LIMIT 5;

-- Check the view works
SELECT count(*) > 0 AS has_entries FROM pg_stat_statements_nsp;

-- Clean up
DROP TABLE test_nsp;
SELECT pg_stat_statements_nsp_reset();
DROP EXTENSION pg_stat_statements_nsp;
