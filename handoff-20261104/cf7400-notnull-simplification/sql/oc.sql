\set VERBOSITY terse
create function f(varchar) returns varchar language sql immutable as 'select $1';
create function fn(numeric) returns numeric language sql immutable as 'select $1';
create collation ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
create domain dv as varchar(10);
\echo V01 manu
create table t1 (a varchar(20) not null, b varchar(20));
create unique index on t1 ((f((case when a is null then b end)::varchar(3))));
insert into t1 values ('x','y') on conflict ((f((case when a is null then b end)::varchar(3)))) do nothing;
\echo V02 manu const + plain col
create table t2 (a varchar(20) not null, b varchar(20));
create unique index on t2 (b, (f((case when a is null then b else 'abcdef' end)::varchar(3))));
insert into t2 values ('x','y') on conflict (b, (f((case when a is null then b else 'abcdef' end)::varchar(3)))) do nothing;
\echo V03 numeric
create table t3 (a numeric(10) not null, b numeric(10));
create unique index on t3 ((fn((case when a is null then b else 1.234 end)::numeric(5,1))));
insert into t3 values (1,2) on conflict ((fn((case when a is null then b else 1.234 end)::numeric(5,1)))) do nothing;
\echo V04 partial index, predicate with folded const inside an expression
create table t4 (a varchar(20) not null, b varchar(20));
create unique index on t4 (b) where (b || f((case when a is null then b else 'abcdef' end)::varchar(3))) is not null;
insert into t4 values ('x','y') on conflict (b) where (b || f((case when a is null then b else 'abcdef' end)::varchar(3))) is not null do nothing;
\echo V05 partial index, predicate compare to folded const
create table t5 (a varchar(20) not null, b varchar(20));
create unique index on t5 (b) where b <> f((case when a is null then b else 'abcdef' end)::varchar(3));
insert into t5 values ('x','y') on conflict (b) where b <> f((case when a is null then b else 'abcdef' end)::varchar(3)) do nothing;
\echo V06 manu + collate in inference
create table t6 (a varchar(20) not null, b varchar(20));
create unique index on t6 ((f((case when a is null then b end)::varchar(3))) collate "C");
insert into t6 values ('x','y') on conflict ((f((case when a is null then b end)::varchar(3))) collate "C") do nothing;
\echo V07 manu + opclass
create table t7 (a varchar(20) not null, b varchar(20));
create unique index on t7 ((f((case when a is null then b end)::varchar(3))) text_pattern_ops);
insert into t7 values ('x','y') on conflict ((f((case when a is null then b end)::varchar(3))) text_pattern_ops) do nothing;
\echo V08 partitioned
create table t8 (a varchar(20) not null, b varchar(20)) partition by list (a);
create table t8a partition of t8 for values in ('x');
create unique index on t8 (a, (f((case when a is null then b end)::varchar(3))));
insert into t8 values ('x','y') on conflict (a, (f((case when a is null then b end)::varchar(3)))) do nothing;
\echo V09 do update where
create table t9 (a varchar(20) not null, b varchar(20));
create unique index on t9 ((f((case when a is null then b else 'abcdef' end)::varchar(3))));
insert into t9 values ('x','y') on conflict ((f((case when a is null then b else 'abcdef' end)::varchar(3)))) do update set b = excluded.b where t9.b is distinct from 'z';
insert into t9 values ('x','q') on conflict ((f((case when a is null then b else 'abcdef' end)::varchar(3)))) do update set b = excluded.b where t9.b is distinct from 'z' returning *;
\echo V10 fujii coalesce null
create table t10 (a varchar(20) not null, b varchar(20));
create unique index on t10 ((coalesce(null::varchar, a, b)));
insert into t10 values ('x','y') on conflict ((coalesce(null::varchar, a, b))) do nothing;
\echo V11 fujii nullif
create table t11 (a numeric(10) not null);
create unique index on t11 (nullif(fn(a), case when a is null then a end));
insert into t11 values (1) on conflict (nullif(fn(a), case when a is null then a end)) do nothing;
\echo V12 shihao coalesce b ''
create table t12 (b text not null);
create unique index on t12 (coalesce(b, ''));
insert into t12 values ('x') on conflict (coalesce(b, '')) do nothing;
\echo V13 opexpr/saop/distinct
create table t13 (a int not null, b int);
create unique index on t13 ((a + 1), (b = any('{1,2}')), (b is distinct from 3), (nullif(b, 0)));
insert into t13 values (1,1) on conflict ((a + 1), (b = any('{1,2}')), (b is distinct from 3), (nullif(b, 0))) do nothing;
\echo V14 ICU nondeterministic
create table t14 (a text not null, b text collate ci);
create unique index on t14 ((coalesce(b, a collate ci)));
insert into t14 values ('x','Y') on conflict ((coalesce(b, a collate ci))) do nothing;
\echo V15 domain
create table t15 (a dv not null, b dv);
create unique index on t15 ((f((case when a is null then b end)::varchar(3))));
insert into t15 values ('x','y') on conflict ((f((case when a is null then b end)::varchar(3)))) do nothing;
\echo V16 mismatch must fail
insert into t2 values ('x','y') on conflict (b, (f((case when a is null then b else 'abcdef' end)::varchar(4)))) do nothing;
\echo V17 on constraint
create table t17 (a varchar(20) not null, b varchar(20));
alter table t17 add constraint t17u unique (a);
insert into t17 values ('x','y') on conflict on constraint t17u do nothing;
\echo V18 plain dedup in index
create table t18 (a int not null);
create unique index on t18 (a, (a + 0));
insert into t18 values (1) on conflict (a, (a + 0)) do nothing;
\echo V19 alias target
create table t19 (a varchar(20) not null, b varchar(20));
create unique index on t19 ((f((case when a is null then b end)::varchar(3))));
insert into t19 as z values ('x','y') on conflict ((f((case when a is null then b end)::varchar(3)))) do nothing;
\echo V20 view with instead? updatable view target
create table t20 (a varchar(20) not null, b varchar(20));
create unique index on t20 ((f((case when a is null then b end)::varchar(3))));
create view v20 as select 1 as dummy, b, a from t20;
insert into v20 (a,b) values ('x','y') on conflict ((f((case when a is null then b end)::varchar(3)))) do nothing;
