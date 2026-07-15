-- Heavy-logging workload + sampler storage for the Windows wait-event check.
create or replace function logspam(n int) returns void language plpgsql as $$
declare
  i   int;
  msg text := repeat('X', 8000);
begin
  for i in 1..n loop
    raise log 'logspam iter % payload %', i, msg;
  end loop;
end$$;

create unlogged table if not exists waitsamples(wet text, we text);
truncate waitsamples;
