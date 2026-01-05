-- Test pg_query_json extension

CREATE EXTENSION pg_query_json;

-- Test pg_parse_validate
SELECT pg_parse_validate('SELECT 1');
SELECT pg_parse_validate('SELECT * FROM users WHERE id = 1');

-- Test with invalid SQL (should error)
-- SELECT pg_parse_validate('SELCT 1');  -- uncomment to see error

-- Test pg_parse_stmt_count
SELECT pg_parse_stmt_count('SELECT 1');
SELECT pg_parse_stmt_count('SELECT 1; SELECT 2');
SELECT pg_parse_stmt_count('SELECT 1; SELECT 2; INSERT INTO t VALUES (1)');

-- Test pg_parse_tree - basic SELECT
SELECT pg_parse_tree('SELECT 1') IS NOT NULL AS has_tree;

-- Test pg_parse_tree - more complex query
SELECT pg_parse_tree('SELECT * FROM users WHERE id = 1') IS NOT NULL AS has_tree;

-- Test pg_parse_tree_with_locations
SELECT pg_parse_tree_with_locations('SELECT 1') IS NOT NULL AS has_tree;

-- Show actual output format (for documentation purposes)
SELECT pg_parse_tree('SELECT 1');

-- Clean up
DROP EXTENSION pg_query_json;
