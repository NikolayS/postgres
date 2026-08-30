-- Reproduction script for PostgreSQL 19devel FK fast-path bug
-- ri_FastPathSubXactCallback drops pending FK checks on internal subxact abort
--
-- Tested on: PostgreSQL 19devel (upstream/master commit 84b9d6b)
-- Result: INSERT succeeds, orphan row (a=999) persists despite FK constraint

drop table if exists fk;
drop table if exists pk;

create table pk (
  id int primary key
);

create table fk (
  a int references pk(id),
  tag text
);

insert into pk values (0), (1);

create or replace function fk_after_row_boom() returns trigger
as $$
  begin
  if new.tag = 'boom' then
    begin
      raise exception 'internal subxact abort';
    exception when others then
      null;
    end;
  end if;

  return new;
end;
$$
language plpgsql;

-- Trigger name sorts after RI_ConstraintTrigger*, so RI FK trigger buffers first
create trigger zz_fk_after_row_boom
after insert on fk
for each row
execute function fk_after_row_boom();

-- Expected: ERROR for FK violation on a=999
-- Actual (bug): INSERT 0 3 succeeds, plus resource-leak warnings
insert into fk(a, tag)
values
  (999, 'bad'),
  (0, 'boom'),
  (1, 'ok');

-- Shows orphan row if bug is present
select * from fk order by tag;

-- Orphan detection query
select fk.*
from fk
left join pk on pk.id = fk.a
where pk.id is null;
