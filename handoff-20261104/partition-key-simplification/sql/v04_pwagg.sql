set enable_partitionwise_aggregate = on;
create table t1 (a int not null, b int) partition by list (coalesce(a, b));
create table t1_1 partition of t1 for values in (1); create table t1_2 partition of t1 for values in (2);
insert into t1 select 1 + g % 2, g from generate_series(1,100) g; analyze t1;
explain (costs off) select a, count(*) from t1 group by a;
select a, count(*) from t1 group by a order by 1;
explain (costs off) select coalesce(a,b), count(*) from t1 group by 1;
select coalesce(a,b), count(*) from t1 group by 1 order by 1;
