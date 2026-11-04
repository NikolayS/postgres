set enable_hashjoin = off; set enable_mergejoin = off;
create table pt (a int not null, b int) partition by list (coalesce(a, b));
create table pt1 partition of pt for values in (1); create table pt2 partition of pt for values in (2);
insert into pt select 1 + g % 2, null from generate_series(1,1000) g; analyze pt;
create index on pt (a);
create table o (x int); insert into o values (2); analyze o;
explain (costs off, analyze, timing off, summary off, buffers off) select count(*) from o join pt on coalesce(pt.a, pt.b) = o.x;
select count(*) from o join pt on coalesce(pt.a, pt.b) = o.x;
