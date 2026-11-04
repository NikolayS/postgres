\set VERBOSITY terse
set enable_partitionwise_aggregate = on; set enable_partitionwise_join = on;
create function pf(numeric) returns numeric language sql immutable as 'select $1';
create function vf(varchar) returns varchar language sql immutable as 'select $1';
\echo P1 hash partitioning
create table h (a numeric(10), b numeric(10)) partition by hash ((coalesce(pf(a), b)));
create table h0 partition of h for values with (modulus 2, remainder 0);
create table h1 partition of h for values with (modulus 2, remainder 1);
explain (costs off) select * from h where coalesce(pf(a), b) = 1;
explain (costs off) select coalesce(pf(a), b), count(*) from h group by 1;
\echo P2 range + multi-column key
create table r (a numeric(10), b numeric(10), c int) partition by range ((coalesce(pf(a), b)), c);
create table r1 partition of r for values from (0, 0) to (10, 10);
create table r2 partition of r for values from (10, 10) to (20, 20);
explain (costs off) select * from r where coalesce(pf(a), b) = 15 and c = 15;
explain (costs off) select * from r where coalesce(pf(a), b) < 5;
explain (costs off) select coalesce(pf(a), b), c, count(*) from r group by 1, 2;
\echo P3 exec-time pruning via nested loop param
create table drv (x numeric);
insert into drv values (1);
create table lp (a numeric(10), b numeric(10)) partition by list ((coalesce(pf(a), b)));
create table lp1 partition of lp for values in (1);
create table lp2 partition of lp for values in (2);
insert into lp select 1,1 from generate_series(1,100); insert into lp select 2,2 from generate_series(1,100);
create index on lp1 ((coalesce(pf(a), b))); create index on lp2 ((coalesce(pf(a), b)));
analyze drv, lp;
set enable_hashjoin = off; set enable_mergejoin = off; set enable_seqscan = off;
explain (costs off, analyze, timing off, summary off, buffers off) select * from drv join lp on coalesce(pf(lp.a), lp.b) = drv.x;
reset enable_hashjoin; reset enable_mergejoin; reset enable_seqscan;
\echo P4 collate key
create table ck (a varchar(3), b varchar(3)) partition by list ((coalesce(vf(a), b)) collate "C");
create table ck1 partition of ck for values in ('a');
create table ck2 partition of ck for values in ('b');
explain (costs off) select * from ck where coalesce(vf(a), b) collate "C" = 'a';
explain (costs off) select * from ck where coalesce(vf(a), b) = 'a';
explain (costs off) select coalesce(vf(a), b) collate "C", count(*) from ck group by 1;
explain (costs off) select coalesce(vf(a), b) collate "POSIX", count(*) from ck group by 1;
\echo P5 domain columns
create domain d3 as varchar(3);
create table dk (a d3, b d3) partition by list ((coalesce(vf(a), b)));
create table dk1 partition of dk for values in ('a');
create table dk2 partition of dk for values in ('b');
explain (costs off) select * from dk where coalesce(vf(a), b) = 'a';
\echo P6 CASE and NULLIF keys
create table ca (a numeric(10), b numeric(10)) partition by list ((case when pf(a) is null then b else pf(a) end));
create table ca1 partition of ca for values in (1);
create table ca2 partition of ca for values in (2);
explain (costs off) select * from ca where (case when pf(a) is null then b else pf(a) end) = 1;
create table nu (a numeric(10), b numeric(10)) partition by list ((nullif(pf(a), b)));
create table nu1 partition of nu for values in (1);
create table nu2 partition of nu for values in (2);
explain (costs off) select * from nu where nullif(pf(a), b) = 1;
\echo P7 full join then join (nullable partexprs)
create table fj1 (a varchar(3), b varchar(3)) partition by list ((coalesce(vf(a), b)));
create table fj1a partition of fj1 for values in ('a'); create table fj1b partition of fj1 for values in ('b');
create table fj2 (a varchar(3), b varchar(3)) partition by list ((coalesce(vf(a), b)));
create table fj2a partition of fj2 for values in ('a'); create table fj2b partition of fj2 for values in ('b');
create table fj3 (a varchar(3), b varchar(3)) partition by list ((coalesce(vf(a), b)));
create table fj3a partition of fj3 for values in ('a'); create table fj3b partition of fj3 for values in ('b');
explain (costs off) select * from fj1 full join fj2 on coalesce(vf(fj1.a), fj1.b) = coalesce(vf(fj2.a), fj2.b) join fj3 on coalesce(vf(fj2.a), fj2.b) = coalesce(vf(fj3.a), fj3.b);
\echo P8 pre-existing: text key, group by bpchar cast
create table bp (t text) partition by list (t);
create table bp1 partition of bp for values in ('a'); create table bp2 partition of bp for values in ('a ');
insert into bp values ('a'), ('a ');
select t::bpchar, count(*) from bp group by 1;
