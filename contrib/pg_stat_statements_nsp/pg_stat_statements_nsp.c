/*-------------------------------------------------------------------------
 *
 * pg_stat_statements_nsp.c
 *		Track statement execution statistics WITHOUT requiring
 *		shared_preload_libraries.
 *
 * This extension demonstrates how to use the DSM Registry (introduced in
 * PostgreSQL 15) to create shared data structures that persist across
 * sessions without needing to be loaded at server startup.
 *
 * Key differences from pg_stat_statements:
 * - Does NOT require shared_preload_libraries
 * - Uses DSM Registry for lazy allocation of shared memory
 * - Can be loaded via LOAD command, session_preload_libraries, or
 *   shared_preload_libraries
 * - Statistics are shared across all sessions once the first session
 *   initializes the shared state
 *
 * Limitations compared to pg_stat_statements:
 * - Statistics don't survive server restart (no persistence to disk)
 * - No GUC parameters for max entries (uses fixed size)
 * - Simplified statistics (no planning stats, WAL stats, etc.)
 *
 * Copyright (c) 2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  contrib/pg_stat_statements_nsp/pg_stat_statements_nsp.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "executor/executor.h"
#include "funcapi.h"
#include "lib/dshash.h"
#include "miscadmin.h"
#include "nodes/queryjumble.h"
#include "storage/dsm_registry.h"
#include "storage/lwlock.h"
#include "tcop/utility.h"
#include "utils/builtins.h"
#include "utils/timestamp.h"

PG_MODULE_MAGIC_EXT(
					.name = "pg_stat_statements_nsp",
					.version = PG_VERSION
);

/* Maximum number of tracked statements */
#define PGSS_NSP_MAX_ENTRIES	1000

/* Name for our DSM Registry entry */
#define PGSS_NSP_HASH_NAME		"pg_stat_statements_nsp"

/*
 * Hash table key - identifies a unique query
 */
typedef struct pgssNspHashKey
{
	Oid			userid;			/* user OID */
	Oid			dbid;			/* database OID */
	int64		queryid;		/* query identifier */
} pgssNspHashKey;

/*
 * Statistics counters for each query
 */
typedef struct pgssNspCounters
{
	int64		calls;			/* number of times executed */
	double		total_time;		/* total execution time in msec */
	double		min_time;		/* minimum execution time in msec */
	double		max_time;		/* maximum execution time in msec */
	int64		rows;			/* total rows retrieved or affected */
} pgssNspCounters;

/*
 * Hash table entry
 */
typedef struct pgssNspEntry
{
	pgssNspHashKey key;			/* hash key - must be first */
	pgssNspCounters counters;	/* statistics counters */
	slock_t		mutex;			/* protects counter updates */
} pgssNspEntry;

/* dshash parameters for our hash table */
static const dshash_parameters pgss_nsp_dsh_params = {
	sizeof(pgssNspHashKey),
	sizeof(pgssNspEntry),
	dshash_memcmp,
	dshash_memhash,
	dshash_memcpy,
	0						/* tranche_id will be assigned by DSM registry */
};

/* Local state */
static dshash_table *pgss_nsp_hash = NULL;
static bool pgss_nsp_initialized = false;

/* Saved hook values */
static ExecutorStart_hook_type prev_ExecutorStart = NULL;
static ExecutorEnd_hook_type prev_ExecutorEnd = NULL;
static ProcessUtility_hook_type prev_ProcessUtility = NULL;

/* Current nesting depth of ExecutorRun calls */
static int	exec_nested_level = 0;

/* Track timing for current query */
static instr_time current_query_start;
static bool query_timing_active = false;

/* Function declarations */
void		_PG_init(void);
static void pgss_nsp_ExecutorStart(QueryDesc *queryDesc, int eflags);
static void pgss_nsp_ExecutorEnd(QueryDesc *queryDesc);
static void pgss_nsp_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
									bool readOnlyTree,
									ProcessUtilityContext context,
									ParamListInfo params,
									QueryEnvironment *queryEnv,
									DestReceiver *dest, QueryCompletion *qc);
static void pgss_nsp_store(int64 queryid, double total_time, uint64 rows);
static void pgss_nsp_ensure_initialized(void);

PG_FUNCTION_INFO_V1(pg_stat_statements_nsp);
PG_FUNCTION_INFO_V1(pg_stat_statements_nsp_reset);

/*
 * Module load callback
 */
void
_PG_init(void)
{
	/*
	 * Unlike pg_stat_statements, we do NOT check
	 * process_shared_preload_libraries_in_progress. This extension works
	 * whether loaded via LOAD, session_preload_libraries, or
	 * shared_preload_libraries.
	 */

	/*
	 * Install hooks.
	 */
	prev_ExecutorStart = ExecutorStart_hook;
	ExecutorStart_hook = pgss_nsp_ExecutorStart;
	prev_ExecutorEnd = ExecutorEnd_hook;
	ExecutorEnd_hook = pgss_nsp_ExecutorEnd;
	prev_ProcessUtility = ProcessUtility_hook;
	ProcessUtility_hook = pgss_nsp_ProcessUtility;

	/*
	 * Request query ID computation if needed.
	 * Note: EnableQueryId() only works when called from shared_preload_libraries.
	 * When loaded later, compute_query_id must already be enabled.
	 */
	if (process_shared_preload_libraries_in_progress)
		EnableQueryId();
}

/*
 * Ensure the shared hash table is initialized and attached.
 *
 * Uses the DSM Registry to create or attach to the shared hash table.
 * This is the key function that enables the extension to work without
 * shared_preload_libraries.
 */
static void
pgss_nsp_ensure_initialized(void)
{
	bool		found;

	if (pgss_nsp_initialized)
		return;

	/*
	 * Use GetNamedDSHash to create or attach to our shared hash table.
	 * The DSM Registry ensures that only one backend creates the table,
	 * and all others attach to it.
	 */
	pgss_nsp_hash = GetNamedDSHash(PGSS_NSP_HASH_NAME,
								   &pgss_nsp_dsh_params,
								   &found);

	pgss_nsp_initialized = true;

	if (!found)
		ereport(LOG,
				(errmsg("pg_stat_statements_nsp: created shared hash table")));
}

/*
 * ExecutorStart hook: start timing the query
 */
static void
pgss_nsp_ExecutorStart(QueryDesc *queryDesc, int eflags)
{
	/* Start timing at top level only */
	if (exec_nested_level == 0)
	{
		INSTR_TIME_SET_CURRENT(current_query_start);
		query_timing_active = true;
	}

	exec_nested_level++;

	/* Call previous hook or standard function */
	if (prev_ExecutorStart)
		prev_ExecutorStart(queryDesc, eflags);
	else
		standard_ExecutorStart(queryDesc, eflags);
}

/*
 * ExecutorEnd hook: record statistics
 */
static void
pgss_nsp_ExecutorEnd(QueryDesc *queryDesc)
{
	int64		queryid;
	double		total_time;
	uint64		rows;
	instr_time	end_time;

	exec_nested_level--;

	/* Only record at top level and if we have a valid query ID */
	if (exec_nested_level == 0 && query_timing_active)
	{
		query_timing_active = false;

		/* Get query ID from the query */
		queryid = queryDesc->plannedstmt->queryId;

		/* Only track queries with valid query IDs */
		if (queryid != UINT64CONST(0))
		{
			INSTR_TIME_SET_CURRENT(end_time);
			INSTR_TIME_SUBTRACT(end_time, current_query_start);
			total_time = INSTR_TIME_GET_MILLISEC(end_time);

			/* Get row count from executor state */
			rows = queryDesc->estate->es_processed;

			pgss_nsp_store(queryid, total_time, rows);
		}
	}

	/* Call previous hook or standard function */
	if (prev_ExecutorEnd)
		prev_ExecutorEnd(queryDesc);
	else
		standard_ExecutorEnd(queryDesc);
}

/*
 * ProcessUtility hook: track utility statements
 */
static void
pgss_nsp_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
						bool readOnlyTree,
						ProcessUtilityContext context,
						ParamListInfo params,
						QueryEnvironment *queryEnv,
						DestReceiver *dest, QueryCompletion *qc)
{
	int64		queryid = 0;
	instr_time	start_time;
	instr_time	end_time;
	double		total_time;
	bool		track_utility = false;

	/* Only track at top level */
	if (exec_nested_level == 0)
	{
		queryid = pstmt->queryId;

		if (queryid != UINT64CONST(0))
		{
			track_utility = true;
			INSTR_TIME_SET_CURRENT(start_time);
		}
	}

	exec_nested_level++;

	PG_TRY();
	{
		if (prev_ProcessUtility)
			prev_ProcessUtility(pstmt, queryString, readOnlyTree,
								context, params, queryEnv, dest, qc);
		else
			standard_ProcessUtility(pstmt, queryString, readOnlyTree,
									context, params, queryEnv, dest, qc);
	}
	PG_FINALLY();
	{
		exec_nested_level--;
	}
	PG_END_TRY();

	if (track_utility)
	{
		INSTR_TIME_SET_CURRENT(end_time);
		INSTR_TIME_SUBTRACT(end_time, start_time);
		total_time = INSTR_TIME_GET_MILLISEC(end_time);

		pgss_nsp_store(queryid, total_time, 0);
	}
}

/*
 * Store or update query statistics
 */
static void
pgss_nsp_store(int64 queryid, double total_time, uint64 rows)
{
	pgssNspHashKey key;
	pgssNspEntry *entry;
	bool		found;

	/* Ensure shared state is initialized */
	pgss_nsp_ensure_initialized();

	/* Set up key */
	memset(&key, 0, sizeof(pgssNspHashKey));
	key.userid = GetUserId();
	key.dbid = MyDatabaseId;
	key.queryid = queryid;

	/* Find or create entry */
	entry = dshash_find_or_insert(pgss_nsp_hash, &key, &found);

	if (!found)
	{
		/* Initialize new entry */
		SpinLockInit(&entry->mutex);
		entry->counters.calls = 1;
		entry->counters.total_time = total_time;
		entry->counters.min_time = total_time;
		entry->counters.max_time = total_time;
		entry->counters.rows = rows;
	}
	else
	{
		/* Update existing entry */
		SpinLockAcquire(&entry->mutex);
		entry->counters.calls++;
		entry->counters.total_time += total_time;
		if (total_time < entry->counters.min_time)
			entry->counters.min_time = total_time;
		if (total_time > entry->counters.max_time)
			entry->counters.max_time = total_time;
		entry->counters.rows += rows;
		SpinLockRelease(&entry->mutex);
	}

	dshash_release_lock(pgss_nsp_hash, entry);
}

/*
 * SQL-callable function to retrieve statistics
 */
Datum
pg_stat_statements_nsp(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	dshash_seq_status status;
	pgssNspEntry *entry;

	/* Ensure shared state is initialized */
	pgss_nsp_ensure_initialized();

	InitMaterializedSRF(fcinfo, MAT_SRF_USE_EXPECTED_DESC);

	/* Iterate through all entries */
	dshash_seq_init(&status, pgss_nsp_hash, false);

	while ((entry = dshash_seq_next(&status)) != NULL)
	{
		Datum		values[8];
		bool		nulls[8] = {0};
		int			i = 0;
		pgssNspCounters counters;

		/* Copy counters under lock */
		SpinLockAcquire(&entry->mutex);
		counters = entry->counters;
		SpinLockRelease(&entry->mutex);

		values[i++] = ObjectIdGetDatum(entry->key.userid);
		values[i++] = ObjectIdGetDatum(entry->key.dbid);
		values[i++] = Int64GetDatum(entry->key.queryid);
		values[i++] = Int64GetDatum(counters.calls);
		values[i++] = Float8GetDatum(counters.total_time);
		values[i++] = Float8GetDatum(counters.min_time);
		values[i++] = Float8GetDatum(counters.max_time);
		values[i++] = Int64GetDatum(counters.rows);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	dshash_seq_term(&status);

	return (Datum) 0;
}

/*
 * SQL-callable function to reset statistics
 */
Datum
pg_stat_statements_nsp_reset(PG_FUNCTION_ARGS)
{
	dshash_seq_status status;
	pgssNspEntry *entry;

	/* Ensure shared state is initialized */
	pgss_nsp_ensure_initialized();

	/* Delete all entries */
	dshash_seq_init(&status, pgss_nsp_hash, true);

	while ((entry = dshash_seq_next(&status)) != NULL)
	{
		dshash_delete_current(&status);
	}

	dshash_seq_term(&status);

	PG_RETURN_VOID();
}
