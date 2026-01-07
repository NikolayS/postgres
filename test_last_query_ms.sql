-- Test script for LAST_QUERY_MS feature
-- Run with modified psql: ./src/bin/psql/psql -f test_last_query_ms.sql

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

\echo ''
\echo '=== All tests complete ==='
