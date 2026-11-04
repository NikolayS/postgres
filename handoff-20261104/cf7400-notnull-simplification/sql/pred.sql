-- Blocking case for v4 (partial unique index predicate). 18.6: both INSERTs
-- succeed. REL_19 + Richard v2, and REL_19 + v4: ERROR: there is no unique or
-- exclusion constraint matching the ON CONFLICT specification.
\set VERBOSITY terse
create function f(varchar) returns varchar language sql immutable as 'select $1';
create function g(varchar, varchar) returns bool language plpgsql immutable as 'begin return $1 <> $2; end';
create table t (a varchar(20) not null, b varchar(20));
create unique index t_b_pred on t (b) where g(b, f((case when a is null then b else 'abcdef' end)::varchar(3)));
insert into t values ('x','y') on conflict (b) where g(b, f((case when a is null then b else 'abcdef' end)::varchar(3))) do nothing;
create table t2 (a varchar(20) not null, b varchar(20));
create unique index t2_b_pred on t2 (b) where g(b, f((case when a is null then b end)::varchar(3)));
insert into t2 values ('x','y') on conflict (b) where g(b, f((case when a is null then b end)::varchar(3))) do nothing;
