/* contrib/pg_query_json/pg_query_json--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_query_json" to load this file. \quit

--
-- pg_parse_tree(sql text) returns text
--
-- Parse a SQL statement and return its parse tree in PostgreSQL's
-- internal text format (nodeToString format).
--
CREATE FUNCTION pg_parse_tree(sql text)
RETURNS text
AS 'MODULE_PATHNAME', 'pg_parse_tree'
LANGUAGE C STRICT PARALLEL SAFE;

COMMENT ON FUNCTION pg_parse_tree(text) IS
'Parse SQL and return the parse tree in PostgreSQL internal text format';

--
-- pg_parse_tree_with_locations(sql text) returns text
--
-- Parse a SQL statement and return its parse tree with location
-- information preserved.
--
CREATE FUNCTION pg_parse_tree_with_locations(sql text)
RETURNS text
AS 'MODULE_PATHNAME', 'pg_parse_tree_with_locations'
LANGUAGE C STRICT PARALLEL SAFE;

COMMENT ON FUNCTION pg_parse_tree_with_locations(text) IS
'Parse SQL and return the parse tree with source location information';

--
-- pg_parse_validate(sql text) returns boolean
--
-- Validate the syntax of a SQL statement. Returns true if valid,
-- raises an error if invalid.
--
CREATE FUNCTION pg_parse_validate(sql text)
RETURNS boolean
AS 'MODULE_PATHNAME', 'pg_parse_validate'
LANGUAGE C STRICT PARALLEL SAFE;

COMMENT ON FUNCTION pg_parse_validate(text) IS
'Validate SQL syntax; returns true if valid, raises error if invalid';

--
-- pg_parse_stmt_count(sql text) returns integer
--
-- Count the number of SQL statements in the input string.
--
CREATE FUNCTION pg_parse_stmt_count(sql text)
RETURNS integer
AS 'MODULE_PATHNAME', 'pg_parse_stmt_count'
LANGUAGE C STRICT PARALLEL SAFE;

COMMENT ON FUNCTION pg_parse_stmt_count(text) IS
'Count the number of SQL statements in the input string';
