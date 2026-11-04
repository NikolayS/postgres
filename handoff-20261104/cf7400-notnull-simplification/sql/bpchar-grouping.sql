-- Separate lead, pre-existing on 18.6 and on 19 (not caused or fixed by
-- this series). Partitionwise aggregate on a text list key, grouping by a
-- bpchar cast, splits groups that are equal under bpchar comparison.
set enable_partitionwise_aggregate = on;
create table bp (t text) partition by list (t);
create table bp1 partition of bp for values in ('a');
create table bp2 partition of bp for values in ('a ');
insert into bp values ('a'), ('a ');
select t::bpchar, count(*) from bp group by 1;   -- 2 groups
set enable_partitionwise_aggregate = off;
select t::bpchar, count(*) from bp group by 1;   -- 1 group
