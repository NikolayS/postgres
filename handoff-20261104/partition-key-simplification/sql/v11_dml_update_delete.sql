create table pt (a int not null, b int) partition by list (coalesce(a, b));
create table pt1 partition of pt for values in (1); create table pt2 partition of pt for values in (2);
insert into pt values (1, null), (2, null);
explain (costs off) update pt set b = 9 where coalesce(a, b) = 1;
update pt set a = 2 where coalesce(a, b) = 1;
select tableoid::regclass, * from pt order by 1, 2;
explain (costs off) delete from pt where coalesce(a, b) = 2;
delete from pt where coalesce(a, b) = 2 returning *;
