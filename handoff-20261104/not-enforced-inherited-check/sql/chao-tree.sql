-- Chao Li tree from the 2026-09-14 review. With v3 the first validating add on
-- c1 fails with the "conflicts with NOT VALID constraint on child table" error
-- from 0b12a5a7435a; after validating c2 it succeeds. The tail of this file has
-- extra probes (local NOT ENFORCED constraint, partitions) that give
-- "already exists" on all builds.
-- Chao Li case: P(not enforced, not valid) -> c1(not enforced, not valid) -> c2(enforced, not valid)
create table p (a int);
create table c1 () inherits (p);
create table c2 () inherits (c1);
insert into c2 values (-1);
alter table p add constraint cc check (a > 0) not enforced;
alter table c2 add constraint cc check (a > 0) not valid;
select conrelid::regclass, conenforced, convalidated, coninhcount, conislocal from pg_constraint where conname='cc' order by 1::text;
alter table c1 add constraint cc check (a > 0);
delete from c2;
alter table c1 add constraint cc check (a > 0);
alter table c2 validate constraint cc;
alter table c1 add constraint cc check (a > 0);
select conrelid::regclass, conenforced, convalidated, coninhcount, conislocal from pg_constraint where conname='cc' order by 1::text;
-- comment 1: local NOT ENFORCED constraint, no inheritance parent constraint
create table t (a int, constraint ck check (a > 0) not enforced);
insert into t values (-1);
alter table t add constraint ck check (a > 0);
select conenforced, convalidated, coninhcount, conislocal from pg_constraint where conrelid='t'::regclass;
-- partitioned
create table pp (a int) partition by list (a);
create table pp1 partition of pp for values in (-1);
alter table pp add constraint ck check (a > 0) not enforced;
insert into pp1 values (-1);
alter table pp1 add constraint ck check (a > 0);
select conrelid::regclass, conenforced, convalidated, coninhcount, conislocal from pg_constraint where conname='ck' and conrelid::regclass::text like 'pp%' order by 1::text;
