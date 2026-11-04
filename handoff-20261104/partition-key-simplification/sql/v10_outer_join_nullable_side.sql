create table pt (a int not null, b int) partition by list (coalesce(a, b));
create table pt1 partition of pt for values in (1); create table pt2 partition of pt for values in (2);
insert into pt values (1, null), (2, null);
create table o (x int); insert into o values (1), (3);
explain (costs off) select * from o left join pt on pt.a = o.x where coalesce(pt.a, pt.b) is null;
select * from o left join pt on pt.a = o.x where coalesce(pt.a, pt.b) is null;
explain (costs off) select * from o left join pt on true where coalesce(pt.a, pt.b) = 2;
select * from o left join pt on true where coalesce(pt.a, pt.b) = 2 order by 1;
