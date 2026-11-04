/*
 * outer_wait: test module for the "wait events for server logging
 * destination writes" patch (CF 6819).
 *
 * outer_wait_log(secs): publish an extension wait event, ereport(LOG), then
 * keep waiting secs seconds inside the same region, then end the region.
 * Sample pg_stat_activity from another session while it waits.  Unpatched
 * master and v9 show the extension event; v8 shows an empty
 * wait_event_type and wait_event.
 *
 * The email draft prints the event name used in the 2026-09-15 message
 * on the thread.  Rename the string below to match it if you want
 * identical output.
 */
#include "postgres.h"

#include "fmgr.h"
#include "miscadmin.h"
#include "utils/wait_event.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(outer_wait_log);

Datum
outer_wait_log(PG_FUNCTION_ARGS)
{
	int32		secs = PG_GETARG_INT32(0);
	uint32		outer = WaitEventExtensionNew("OuterWait");

	pgstat_report_wait_start(outer);
	ereport(LOG, (errmsg("outer_wait: logging from inside OuterWait")));
	pg_usleep(secs * 1000000L);
	pgstat_report_wait_end();
	PG_RETURN_VOID();
}
