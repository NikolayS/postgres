/* contrib/amcheck/amcheck--1.3--1.4.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION amcheck UPDATE TO '1.4'" to load this file. \quit


--
-- gin_index_parent_check()
--
CREATE FUNCTION gin_index_parent_check(index regclass)
RETURNS VOID
AS 'MODULE_PATHNAME', 'gin_index_parent_check'
LANGUAGE C STRICT;

REVOKE ALL ON FUNCTION gin_index_parent_check(regclass) FROM PUBLIC;
