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

#include <ctype.h>

#include "fmgr.h"
#include "lib/stringinfo.h"
#include "nodes/nodes.h"
#include "nodes/pg_list.h"
#include "nodes/parsenodes.h"
#include "nodes/value.h"
#include "parser/parser.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#include "utils/jsonb.h"

/* Forward declarations for JSON output */
static void node_to_json(StringInfo str, const void *obj);
static void escape_json_string(StringInfo str, const char *s);

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

/*
 * Helper function to escape a string for JSON output
 */
static void
escape_json_string(StringInfo str, const char *s)
{
	const char *p;

	appendStringInfoChar(str, '"');
	for (p = s; *p; p++)
	{
		switch (*p)
		{
			case '"':
				appendStringInfoString(str, "\\\"");
				break;
			case '\\':
				appendStringInfoString(str, "\\\\");
				break;
			case '\b':
				appendStringInfoString(str, "\\b");
				break;
			case '\f':
				appendStringInfoString(str, "\\f");
				break;
			case '\n':
				appendStringInfoString(str, "\\n");
				break;
			case '\r':
				appendStringInfoString(str, "\\r");
				break;
			case '\t':
				appendStringInfoString(str, "\\t");
				break;
			default:
				if ((unsigned char) *p < 32)
					appendStringInfo(str, "\\u%04x", (unsigned int) *p);
				else
					appendStringInfoChar(str, *p);
				break;
		}
	}
	appendStringInfoChar(str, '"');
}

/*
 * Output a List as a JSON array
 */
static void
list_to_json(StringInfo str, const List *list)
{
	const ListCell *lc;
	bool		first = true;

	appendStringInfoChar(str, '[');
	foreach(lc, list)
	{
		if (!first)
			appendStringInfoChar(str, ',');
		first = false;
		node_to_json(str, lfirst(lc));
	}
	appendStringInfoChar(str, ']');
}

/*
 * Output an IntList as a JSON array
 */
static void
intlist_to_json(StringInfo str, const List *list)
{
	const ListCell *lc;
	bool		first = true;

	appendStringInfoChar(str, '[');
	foreach(lc, list)
	{
		if (!first)
			appendStringInfoChar(str, ',');
		first = false;
		appendStringInfo(str, "%d", lfirst_int(lc));
	}
	appendStringInfoChar(str, ']');
}

/*
 * Output an OidList as a JSON array
 */
static void
oidlist_to_json(StringInfo str, const List *list)
{
	const ListCell *lc;
	bool		first = true;

	appendStringInfoChar(str, '[');
	foreach(lc, list)
	{
		if (!first)
			appendStringInfoChar(str, ',');
		first = false;
		appendStringInfo(str, "%u", lfirst_oid(lc));
	}
	appendStringInfoChar(str, ']');
}

/*
 * Main recursive function to convert a Node to JSON.
 * This handles all the common node types found in parse trees.
 */
static void
node_to_json(StringInfo str, const void *obj)
{
	if (obj == NULL)
	{
		appendStringInfoString(str, "null");
		return;
	}

	switch (nodeTag(obj))
	{
		case T_List:
			list_to_json(str, (const List *) obj);
			break;

		case T_IntList:
			intlist_to_json(str, (const List *) obj);
			break;

		case T_OidList:
			oidlist_to_json(str, (const List *) obj);
			break;

		case T_Integer:
			appendStringInfo(str, "%d", intVal(obj));
			break;

		case T_Float:
			{
				Float *f = (Float *) obj;
				appendStringInfoString(str, f->fval);
			}
			break;

		case T_Boolean:
			appendStringInfoString(str, boolVal(obj) ? "true" : "false");
			break;

		case T_String:
			escape_json_string(str, strVal(obj));
			break;

		case T_BitString:
			{
				BitString *bs = (BitString *) obj;
				escape_json_string(str, bs->bsval);
			}
			break;

		default:
			{
				/*
				 * For all other node types, output the node tag number and
				 * use nodeToString for the details (converted to JSON string)
				 */
				char	   *nodestr = nodeToStringWithLocations(obj);

				appendStringInfoString(str, "{\"node_tag\":");
				appendStringInfo(str, "%d", (int) nodeTag(obj));
				appendStringInfoString(str, ",\"raw\":");
				escape_json_string(str, nodestr);
				appendStringInfoChar(str, '}');
				pfree(nodestr);
			}
			break;
	}
}

/*
 * pg_parse_json - Parse SQL and return JSON representation of parse tree
 *
 * This provides a more accessible format than the internal nodeToString format.
 */
PG_FUNCTION_INFO_V1(pg_parse_json);

Datum
pg_parse_json(PG_FUNCTION_ARGS)
{
	text	   *sql_text = PG_GETARG_TEXT_PP(0);
	char	   *sql;
	List	   *raw_parsetree_list;
	StringInfoData str;
	char	   *result;
	MemoryContext oldcontext;
	MemoryContext parse_context;

	sql = text_to_cstring(sql_text);

	/*
	 * Create a temporary memory context for parsing to ensure proper cleanup.
	 */
	parse_context = AllocSetContextCreate(CurrentMemoryContext,
										  "pg_parse_json context",
										  ALLOCSET_DEFAULT_SIZES);
	oldcontext = MemoryContextSwitchTo(parse_context);

	PG_TRY();
	{
		/* Parse the SQL statement */
		raw_parsetree_list = raw_parser(sql, RAW_PARSE_DEFAULT);

		/* Convert to JSON */
		initStringInfo(&str);
		appendStringInfoString(&str, "{\"version\":");
		appendStringInfo(&str, "%d", PG_VERSION_NUM);
		appendStringInfoString(&str, ",\"stmts\":");
		node_to_json(&str, raw_parsetree_list);
		appendStringInfoChar(&str, '}');

		result = str.data;
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
