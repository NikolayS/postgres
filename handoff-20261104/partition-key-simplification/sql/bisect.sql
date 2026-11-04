create table pc (a int not null, b int) partition by list (coalesce(a, b));
create table pc1 partition of pc for values in (1); create table pc2 partition of pc for values in (2);
explain (costs off) select * from pc where coalesce(a, b) = 1;
create table pk (a int not null, b int) partition by list ((case when a is null then b else a end));
create table pk1 partition of pk for values in (1); create table pk2 partition of pk for values in (2);
explain (costs off) select * from pk where (case when a is null then b else a end) = 1;
