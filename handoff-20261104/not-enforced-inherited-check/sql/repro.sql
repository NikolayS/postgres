-- Reproducer from the 2026-09-13 report. Unpatched master, REL_19_STABLE and
-- REL_18_STABLE: case 1 succeeds with conenforced t, convalidated t over a
-- violating row; case 2 also sets convalidated t. Patched: case 1 fails with
-- "violated by some row"; case 2 leaves convalidated f.
-- case 1: ADD CONSTRAINT (enforced) merged into inherited NOT ENFORCED
create table p (a int constraint ck check (a > 0) not enforced);
create table c () inherits (p);
insert into c values (-1);
alter table c add constraint ck check (a > 0);
select conenforced, convalidated from pg_constraint
where conrelid = 'c'::regclass and conname = 'ck';
-- case 2: same with NOT VALID
create table p2 (a int constraint ck check (a > 0) not enforced);
create table c2 () inherits (p2);
insert into c2 values (-1);
alter table c2 add constraint ck check (a > 0) not valid;
select conenforced, convalidated from pg_constraint
where conrelid = 'c2'::regclass and conname = 'ck';
-- the violating row is still there
select * from c union all select * from c2;
