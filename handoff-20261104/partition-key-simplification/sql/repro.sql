-- PG19: partition pruning lost when the partition key expression
-- can be simplified using a NOT NULL constraint
create table pt (a int not null, b int) partition by list (coalesce(a, b));
create table pt1 partition of pt for values in (1);
create table pt2 partition of pt for values in (2);
explain (costs off) select * from pt where coalesce(a, b) = 1;
explain (costs off) select * from pt where a = 1;
drop table pt;
create table pc (a int not null, b int)
  partition by list ((case when a is null then b else a end));
create table pc1 partition of pc for values in (1);
create table pc2 partition of pc for values in (2);
explain (costs off) select * from pc where (case when a is null then b else a end) = 1;
drop table pc;
