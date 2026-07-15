-- Server-side sampler: snapshot wait events of other client backends
-- ~6000 times at ~2ms intervals while the logspam workload runs.
truncate waitsamples;
do $$
declare
  k int;
begin
  for k in 1..6000 loop
    insert into waitsamples
      select wait_event_type, wait_event
      from pg_stat_activity
      where wait_event is not null
        and backend_type = 'client backend'
        and pid <> pg_backend_pid();
    perform pg_sleep(0.002);
  end loop;
end$$;
