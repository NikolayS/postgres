-- Alternative approaches to reproduce IPC:ParallelFinish hang
-- Try these if test_parallel_queue_saturation.sql doesn't reproduce the issue

\timing on
\set VERBOSITY verbose

\echo '========================================='
\echo 'Alternative Test 1: Even More Messages'
\echo '========================================='

-- Create function that generates HUGE volume of messages
create or replace function mega_flood_error_queue(text) returns boolean as $$
declare
    i int;
    msg text;
begin
    -- Generate 200 notices (vs 50 in original)
    -- This should definitely exceed 16KB queue
    for i in 1..200 loop
        msg := 'FLOODING: ' || $1 ||
               ' | Iter: ' || i ||
               ' | Payload: ' || repeat('ABCDEFGHIJ', 100);  -- 1000 chars
        raise notice '%', msg;
    end loop;
    return true;
end;
$$ language plpgsql;

-- Test with mega flood
set max_parallel_workers_per_gather = 2;
set parallel_setup_cost = 0;
set parallel_tuple_cost = 0.001;
set min_parallel_table_scan_size = 0;

\echo 'Attempting query with mega flood function...'

select count(*)
from test_employees e
where lower(e.properties->'osv'->>'home_email') like 'user%'
  and mega_flood_error_queue(e.properties->'osv'->>'home_email');

\echo 'Test 1 completed'
\echo ''

\echo '========================================='
\echo 'Alternative Test 2: More Workers'
\echo '========================================='

-- More workers = more error queues to fill
set max_parallel_workers_per_gather = 4;

\echo 'Attempting with 4 workers...'

select count(*)
from test_employees e
where lower(e.properties->'osv'->>'home_email') like 'user%'
  and mega_flood_error_queue(e.properties->'osv'->>'home_email');

\echo 'Test 2 completed'
\echo ''

\echo '========================================='
\echo 'Alternative Test 3: Slow Leader'
\echo '========================================='

-- Create function that tries to slow down the leader
-- while workers are generating messages
create or replace function slow_leader() returns void as $$
begin
    -- This runs in the leader process
    perform pg_sleep(0.1);
end;
$$ language plpgsql;

\echo 'Attempting with slow leader (calls pg_sleep)...'

-- Leader calls slow_leader which delays message processing
with slow as (
    select slow_leader()
)
select count(*)
from test_employees e
where lower(e.properties->'osv'->>'home_email') like 'user%'
  and mega_flood_error_queue(e.properties->'osv'->>'home_email');

\echo 'Test 3 completed'
\echo ''

\echo '========================================='
\echo 'Alternative Test 4: With Autovacuum'
\echo '========================================='

-- Run vacuum in another session to simulate production condition
-- In a separate terminal, run:
-- psql test -c "VACUUM VERBOSE test_employees;"

\echo 'Starting query - manually run VACUUM VERBOSE test_employees in another session NOW'
\echo 'Waiting 5 seconds for you to start vacuum...'
select pg_sleep(5);

select count(*)
from test_employees e
where lower(e.properties->'osv'->>'home_email') like 'user%'
  and mega_flood_error_queue(e.properties->'osv'->>'home_email');

\echo 'Test 4 completed'
\echo ''

\echo '========================================='
\echo 'Alternative Test 5: Exception Handling'
\echo '========================================='

-- Workers generating errors (not just notices) might fill queue differently
create or replace function generate_errors(text) returns boolean as $$
declare
    i int;
begin
    for i in 1..20 loop
        begin
            -- Try to cause an error but catch it
            perform 1/0;
        exception when division_by_zero then
            raise notice 'Caught error % for value: % | Context: %',
                i, $1, repeat('ERROR_CTX_', 80);
        end;
    end loop;
    return true;
end;
$$ language plpgsql;

\echo 'Attempting with error generation...'

select count(*)
from test_employees e
where lower(e.properties->'osv'->>'home_email') like 'user%'
  and generate_errors(e.properties->'osv'->>'home_email');

\echo 'Test 5 completed'
\echo ''

\echo '========================================='
\echo 'Alternative Test 6: DEBUG Messages'
\echo '========================================='

-- Enable debug messages which might generate more output
set client_min_messages = debug1;
set debug_print_plan = on;

create or replace function debug_flood(text) returns boolean as $$
begin
    -- These RAISE DEBUG might generate more internal messages
    for i in 1..50 loop
        raise debug 'Debug message % for %: %', i, $1, repeat('DEBUG_', 100);
    end loop;
    return true;
end;
$$ language plpgsql;

\echo 'Attempting with debug messages...'

select count(*)
from test_employees e
where lower(e.properties->'osv'->>'home_email') like 'user%'
  and debug_flood(e.properties->'osv'->>'home_email');

set client_min_messages = notice;
set debug_print_plan = off;

\echo 'Test 6 completed'
\echo ''

\echo '========================================='
\echo 'Alternative Test 7: Combined Stress'
\echo '========================================='

-- Combine multiple factors:
-- 1. Many workers
-- 2. Large messages
-- 3. Dead tuples
-- 4. Complex query

set max_parallel_workers_per_gather = 4;

\echo 'Final combined stress test...'

select count(distinct ur.user_id)
from test_user_roles ur
join test_employees e on e.employee_id = ur.entity_id
where (
    (e.properties->'osv'->>'home_email' is not null
     and lower(e.properties->'osv'->>'home_email') like 'user%'
     and mega_flood_error_queue(e.properties->'osv'->>'home_email'))
    or
    (e.properties->'osv'->>'work_email' is not null
     and lower(e.properties->'osv'->>'work_email') like 'work%'
     and mega_flood_error_queue(e.properties->'osv'->>'work_email'))
)
and exists (
    select 1 from test_employees e2
    where e2.employee_id = e.employee_id
    and mega_flood_error_queue(e2.properties->'osv'->>'home_email')
);

\echo 'Test 7 completed'
\echo ''

\echo '========================================='
\echo 'All Tests Completed'
\echo '========================================='
\echo 'If none of these tests reproduced the hang, possible reasons:'
\echo '1. PostgreSQL message queue handling is more robust than theorized'
\echo '2. Additional conditions needed (specific timing, autovacuum interaction)'
\echo '3. Issue may be related to different theory (buffer pins, locks, etc.)'
\echo '4. Production-specific factors not captured in synthetic test'
