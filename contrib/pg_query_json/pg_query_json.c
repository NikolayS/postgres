/*-------------------------------------------------------------------------
 *
 * pg_query_json.c
 *	  PostgreSQL extension to expose SQL parsing to SQL level
 *
 * This extension provides functions to parse SQL statements and return
 * the parse tree in various formats (text, JSON).
 *
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  contrib/pg_query_json/pg_query_json.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "fmgr.h"
#include "lib/stringinfo.h"
#include "nodes/nodes.h"
#include "nodes/pg_list.h"
#include "nodes/parsenodes.h"
#include "parser/parser.h"
#include "utils/builtins.h"
#include "utils/memutils.h"

PG_MODULE_MAGIC_EXT(
	.name = "pg_query_json",
	.version = PG_VERSION
);

/*
 * pg_parse_tree - Parse SQL and return internal text representation
 *
 * This function takes a SQL statement and returns the parse tree
 * in PostgreSQL's internal text format (nodeToString format).
 */
PG_FUNCTION_INFO_V1(pg_parse_tree);

Datum
pg_parse_tree(PG_FUNCTION_ARGS)
{
	text	   *sql_text = PG_GETARG_TEXT_PP(0);
	char	   *sql;
	List	   *raw_parsetree_list;
	char	   *result;
	MemoryContext oldcontext;
	MemoryContext parse_context;

	sql = text_to_cstring(sql_text);

	/*
	 * Create a temporary memory context for parsing to ensure proper cleanup.
	 */
	parse_context = AllocSetContextCreate(CurrentMemoryContext,
										  "pg_parse_tree context",
										  ALLOCSET_DEFAULT_SIZES);
	oldcontext = MemoryContextSwitchTo(parse_context);

	PG_TRY();
	{
		/* Parse the SQL statement */
		raw_parsetree_list = raw_parser(sql, RAW_PARSE_DEFAULT);

		/* Convert to string representation */
		result = nodeToString(raw_parsetree_list);
	}
	PG_FINALLY();
	{
		MemoryContextSwitchTo(oldcontext);
	}
	PG_END_TRY();

	/* Copy result to caller's memory context */
	result = MemoryContextStrdup(oldcontext, result);
	MemoryContextDelete(parse_context);

	PG_RETURN_TEXT_P(cstring_to_text(result));
}

/*
 * pg_parse_tree_with_locations - Parse SQL and return internal text
 * representation with location information preserved.
 */
PG_FUNCTION_INFO_V1(pg_parse_tree_with_locations);

Datum
pg_parse_tree_with_locations(PG_FUNCTION_ARGS)
{
	text	   *sql_text = PG_GETARG_TEXT_PP(0);
	char	   *sql;
	List	   *raw_parsetree_list;
	char	   *result;
	MemoryContext oldcontext;
	MemoryContext parse_context;

	sql = text_to_cstring(sql_text);

	/*
	 * Create a temporary memory context for parsing to ensure proper cleanup.
	 */
	parse_context = AllocSetContextCreate(CurrentMemoryContext,
										  "pg_parse_tree context",
										  ALLOCSET_DEFAULT_SIZES);
	oldcontext = MemoryContextSwitchTo(parse_context);

	PG_TRY();
	{
		/* Parse the SQL statement */
		raw_parsetree_list = raw_parser(sql, RAW_PARSE_DEFAULT);

		/* Convert to string representation with locations */
		result = nodeToStringWithLocations(raw_parsetree_list);
	}
	PG_FINALLY();
	{
		MemoryContextSwitchTo(oldcontext);
	}
	PG_END_TRY();

	/* Copy result to caller's memory context */
	result = MemoryContextStrdup(oldcontext, result);
	MemoryContextDelete(parse_context);

	PG_RETURN_TEXT_P(cstring_to_text(result));
}

/*
 * pg_parse_validate - Validate SQL syntax without returning the tree
 *
 * Returns true if the SQL is valid, raises an error otherwise.
 * This is useful for syntax validation.
 */
PG_FUNCTION_INFO_V1(pg_parse_validate);

Datum
pg_parse_validate(PG_FUNCTION_ARGS)
{
	text	   *sql_text = PG_GETARG_TEXT_PP(0);
	char	   *sql;
	MemoryContext oldcontext;
	MemoryContext parse_context;

	sql = text_to_cstring(sql_text);

	/*
	 * Create a temporary memory context for parsing to ensure proper cleanup.
	 */
	parse_context = AllocSetContextCreate(CurrentMemoryContext,
										  "pg_parse_validate context",
										  ALLOCSET_DEFAULT_SIZES);
	oldcontext = MemoryContextSwitchTo(parse_context);

	PG_TRY();
	{
		/* Parse the SQL statement - will throw on syntax error */
		(void) raw_parser(sql, RAW_PARSE_DEFAULT);
	}
	PG_FINALLY();
	{
		MemoryContextSwitchTo(oldcontext);
		MemoryContextDelete(parse_context);
	}
	PG_END_TRY();

	PG_RETURN_BOOL(true);
}

/*
 * pg_parse_stmt_count - Count the number of statements in a SQL string
 */
PG_FUNCTION_INFO_V1(pg_parse_stmt_count);

Datum
pg_parse_stmt_count(PG_FUNCTION_ARGS)
{
	text	   *sql_text = PG_GETARG_TEXT_PP(0);
	char	   *sql;
	List	   *raw_parsetree_list;
	int			count;
	MemoryContext oldcontext;
	MemoryContext parse_context;

	sql = text_to_cstring(sql_text);

	/*
	 * Create a temporary memory context for parsing to ensure proper cleanup.
	 */
	parse_context = AllocSetContextCreate(CurrentMemoryContext,
										  "pg_parse_stmt_count context",
										  ALLOCSET_DEFAULT_SIZES);
	oldcontext = MemoryContextSwitchTo(parse_context);

	PG_TRY();
	{
		/* Parse the SQL statement */
		raw_parsetree_list = raw_parser(sql, RAW_PARSE_DEFAULT);
		count = list_length(raw_parsetree_list);
	}
	PG_FINALLY();
	{
		MemoryContextSwitchTo(oldcontext);
		MemoryContextDelete(parse_context);
	}
	PG_END_TRY();

	PG_RETURN_INT32(count);
}
