create table pt (a int, b int) partition by list (coalesce(a, b));
create table pt1 partition of pt for values in (1); create table pt2 partition of pt for values in (2);
insert into pt values (null, 1), (2, null);
alter table pt add constraint a_nn not null a not valid;
explain (costs off) select * from pt where coalesce(a, b) = 1;
select * from pt where coalesce(a, b) = 1;
