-- Test script to reproduce IPC:ParallelFinish hang via queue saturation
-- PostgreSQL 16.3
-- Theory: Fill 16KB error queues to cause workers to block indefinitely

\timing on
\set VERBOSITY verbose

-- Setup: Create test environment
drop table if exists test_employees cascade;
drop table if exists test_users cascade;
drop table if exists test_user_roles cascade;

-- Create tables matching production schema
create table test_users (
    user_id bigint primary key generated always as identity,
    email text not null
);

create table test_employees (
    employee_id bigint primary key generated always as identity,
    properties jsonb
);

create table test_user_roles (
    user_id bigint,
    role_id int,
    entity_id bigint
);

-- Insert data to match production scale
-- ~10M employees, similar to production
insert into test_employees (properties)
select jsonb_build_object(
    'osv', jsonb_build_object(
        'home_email', 'user' || i || '@example.com',
        'work_email', 'work' || i || '@company.com'
    )
)
from generate_series(1, 1000000) i;

-- Create indexes matching production
create index idx_test_employees_lower_osv_home_email
    on test_employees(lower((properties->'osv'->>'home_email')));
create index idx_test_employees_lower_osv_work_email
    on test_employees(lower((properties->'osv'->>'work_email')));

-- Insert user_roles data
insert into test_user_roles (user_id, role_id, entity_id)
select i, 1, i from generate_series(1, 500000) i;

-- Create dead tuples to match production (252K dead tuples)
-- This is critical - it matches the production bloat scenario
begin;
update test_employees set properties = properties || '{"updated": true}'::jsonb
where employee_id % 4 = 0;  -- Update 25% = 250K rows
commit;

-- Now delete them to create dead tuples
-- Don't vacuum - we want dead tuples to accumulate
delete from test_employees where employee_id % 4 = 0;

-- Verify dead tuples exist
select
    schemaname,
    tablename,
    n_dead_tup,
    n_live_tup,
    n_dead_tup::float / nullif(n_live_tup, 0) as dead_ratio
from pg_stat_user_tables
where tablename = 'test_employees';

-- Create a function that generates many NOTICE messages
-- This simulates workers generating lots of error queue messages
create or replace function flood_error_queue(text) returns boolean as $$
declare
    i int;
    msg text;
begin
    -- Generate 50 notices with large payloads
    -- Each notice with context could be ~500-1000 bytes
    -- 50 messages * 800 bytes = 40KB (exceeds 16KB queue)
    for i in 1..50 loop
        msg := 'Processing email: ' || $1 ||
               ' | Iteration: ' || i ||
               ' | Context: ' || repeat('X', 600) ||
               ' | Stack trace simulation';
        raise notice '%', msg;
    end loop;
    return true;
exception when others then
    raise notice 'Error in flood_error_queue: %', sqlerrm;
    return false;
end;
$$ language plpgsql;

-- Configure for parallel execution matching production
set max_parallel_workers_per_gather = 2;
set parallel_setup_cost = 0;
set parallel_tuple_cost = 0.001;
set min_parallel_table_scan_size = 0;
set parallel_leader_participation = on;

-- Force parallel bitmap heap scan like production
set enable_seqscan = off;
set enable_indexscan = off;
set enable_indexonlyscan = off;

-- Show the plan - should match production (parallel bitmap heap scan)
explain (costs off, verbose)
select ur.user_id
from test_user_roles ur
join test_employees e on e.employee_id = ur.entity_id
where (e.properties->'osv'->>'home_email' is not null
       and lower(e.properties->'osv'->>'home_email') = 'user12345@example.com'
       and flood_error_queue(e.properties->'osv'->>'home_email'))
   or (e.properties->'osv'->>'work_email' is not null
       and lower(e.properties->'osv'->>'work_email') = 'user12345@example.com'
       and flood_error_queue(e.properties->'osv'->>'work_email'));

\echo 'Starting query that may hang...'
\echo 'If this hangs with IPC:ParallelFinish, the theory is confirmed'
\echo 'Check pg_stat_activity in another session for wait_event'

-- The actual query that should trigger the issue
-- Each worker will call flood_error_queue() many times
-- This should fill the 16KB error queue rapidly
select count(*)
from test_user_roles ur
join test_employees e on e.employee_id = ur.entity_id
where (e.properties->'osv'->>'home_email' is not null
       and lower(e.properties->'osv'->>'home_email') like 'user%'
       and flood_error_queue(e.properties->'osv'->>'home_email'))
   or (e.properties->'osv'->>'work_email' is not null
       and lower(e.properties->'osv'->>'work_email') like 'user%'
       and flood_error_queue(e.properties->'osv'->>'work_email'));

\echo 'Query completed successfully - issue not reproduced'
\echo 'Trying more aggressive version...'

-- Even more aggressive: call the function on every row in bitmap scan
select count(*)
from test_employees e
where lower(e.properties->'osv'->>'home_email') like 'user%'
  and flood_error_queue(e.properties->'osv'->>'home_email');
