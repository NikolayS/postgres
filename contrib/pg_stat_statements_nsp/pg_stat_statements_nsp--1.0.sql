/* contrib/pg_stat_statements_nsp/pg_stat_statements_nsp--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_stat_statements_nsp" to load this file. \quit

-- Register the function to retrieve statistics
CREATE FUNCTION pg_stat_statements_nsp(
    OUT userid oid,
    OUT dbid oid,
    OUT queryid bigint,
    OUT calls bigint,
    OUT total_time double precision,
    OUT min_time double precision,
    OUT max_time double precision,
    OUT rows bigint
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'pg_stat_statements_nsp'
LANGUAGE C STRICT VOLATILE PARALLEL SAFE;

-- Register the function to reset statistics
CREATE FUNCTION pg_stat_statements_nsp_reset()
RETURNS void
AS 'MODULE_PATHNAME', 'pg_stat_statements_nsp_reset'
LANGUAGE C STRICT VOLATILE PARALLEL SAFE;

-- Create a view for convenient access
CREATE VIEW pg_stat_statements_nsp AS
SELECT
    s.userid,
    s.dbid,
    s.queryid,
    s.calls,
    s.total_time,
    s.min_time,
    s.max_time,
    CASE WHEN s.calls > 0 THEN s.total_time / s.calls ELSE 0 END AS mean_time,
    s.rows
FROM pg_stat_statements_nsp() s;

-- Grant access to pg_read_all_stats role (like pg_stat_statements does)
GRANT SELECT ON pg_stat_statements_nsp TO pg_read_all_stats;
GRANT EXECUTE ON FUNCTION pg_stat_statements_nsp() TO pg_read_all_stats;
