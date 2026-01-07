-- Test script for LAST_QUERY_MS feature
-- Run with modified psql: ./src/bin/psql/psql -f test_last_query_ms.sql

\set ON_ERROR_STOP off

-- Test 1: Verify LAST_QUERY_MS exists and is initialized
\echo '=== Test 1: Initial value ==='
\echo 'LAST_QUERY_MS should be 0 initially:'
\echo :LAST_QUERY_MS

-- Test 2: Run a simple query with timing OFF
\echo ''
\echo '=== Test 2: Timing OFF but LAST_QUERY_MS still set ==='
\timing off
SELECT 1 AS test;
\echo 'LAST_QUERY_MS after SELECT 1 (timing off):'
\echo :LAST_QUERY_MS

-- Test 3: Run a query that takes some time
\echo ''
\echo '=== Test 3: Slower query, timing still OFF ==='
SELECT pg_sleep(0.1);
\echo 'LAST_QUERY_MS after pg_sleep(0.1) - should be ~100ms:'
\echo :LAST_QUERY_MS

-- Test 4: Turn timing on and compare
\echo ''
\echo '=== Test 4: With timing ON ==='
\timing on
SELECT pg_sleep(0.05);
\echo 'LAST_QUERY_MS (should match displayed time ~50ms):'
\echo :LAST_QUERY_MS
\timing off

-- Test 5: Use LAST_QUERY_MS in a conditional
\echo ''
\echo '=== Test 5: Programmatic use ==='
SELECT pg_sleep(0.02);
\if :LAST_QUERY_MS > 10
  \echo 'Query took more than 10ms (as expected)'
\else
  \echo 'Query took less than 10ms'
\endif

-- Test 6: Error query - should still measure time
\echo ''
\echo '=== Test 6: Error query (LAST_QUERY_MS should still be set) ==='
SELECT * FROM nonexistent_table_xyz;
\echo 'LAST_QUERY_MS after error (should be > 0):'
\echo :LAST_QUERY_MS

-- Test 7: Syntax error - should still measure time
\echo ''
\echo '=== Test 7: Syntax error (LAST_QUERY_MS should still be set) ==='
SELEC 1;
\echo 'LAST_QUERY_MS after syntax error (should be > 0):'
\echo :LAST_QUERY_MS

-- Test 8: DDL commands (no result columns)
\echo ''
\echo '=== Test 8: DDL command ==='
CREATE TEMP TABLE test_timing_table (id int);
\echo 'LAST_QUERY_MS after CREATE TABLE:'
\echo :LAST_QUERY_MS

DROP TABLE test_timing_table;
\echo 'LAST_QUERY_MS after DROP TABLE:'
\echo :LAST_QUERY_MS

-- Test 9: \gdesc command (uses DescribeQuery)
\echo ''
\echo '=== Test 9: \\gdesc command ==='
SELECT 1 as col1, 'hello' as col2 \gdesc
\echo 'LAST_QUERY_MS after \\gdesc:'
\echo :LAST_QUERY_MS

-- Test 10: Multiple statements - timing is for last
\echo ''
\echo '=== Test 10: Multiple statements ==='
SELECT pg_sleep(0.01); SELECT pg_sleep(0.02);
\echo 'LAST_QUERY_MS after multiple statements:'
\echo :LAST_QUERY_MS

-- Test 11: Empty result
\echo ''
\echo '=== Test 11: Empty result ==='
SELECT 1 WHERE false;
\echo 'LAST_QUERY_MS after empty result:'
\echo :LAST_QUERY_MS

\echo ''
\echo '=== All tests complete ==='
\echo 'If all LAST_QUERY_MS values are > 0, the patch is working correctly!'
