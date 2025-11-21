-- Monitoring script to run in a separate session
-- Run this while test_parallel_queue_saturation.sql is executing

\timing on
\watch 2

-- Monitor query state and wait events
select
    pid,
    usename,
    application_name,
    state,
    wait_event_type,
    wait_event,
    backend_type,
    query_start,
    state_change,
    substring(query, 1, 80) as query_snippet
from pg_stat_activity
where (query like '%test_employees%' or backend_type = 'parallel worker')
  and pid != pg_backend_pid()
order by backend_type, pid;

\echo ''
\echo '=== Parallel Worker Details ==='

-- Check specifically for IPC:ParallelFinish
select
    pid,
    backend_type,
    wait_event_type || ':' || wait_event as wait_event,
    state,
    query_start,
    now() - query_start as query_duration
from pg_stat_activity
where backend_type in ('client backend', 'parallel worker')
  and query like '%test_%'
order by backend_type, pid;

\echo ''
\echo '=== Lock Information ==='

-- Check for lock waits
select
    locktype,
    relation::regclass,
    mode,
    granted,
    pid,
    pg_blocking_pids(pid) as blocked_by
from pg_locks
where pid in (
    select pid from pg_stat_activity
    where query like '%test_employees%' or backend_type = 'parallel worker'
)
order by granted, pid;

\echo ''
\echo 'Watching for IPC:ParallelFinish wait event...'
\echo 'Press Ctrl+C to stop monitoring'
