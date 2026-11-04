CREATE FUNCTION pf(numeric) RETURNS numeric
  LANGUAGE sql IMMUTABLE AS 'SELECT $1';
CREATE TABLE pc (a numeric(10), b numeric(10))
  PARTITION BY LIST ((COALESCE(pf(a), b)));
CREATE TABLE pc1 PARTITION OF pc FOR VALUES IN (1);
CREATE TABLE pc2 PARTITION OF pc FOR VALUES IN (2);
EXPLAIN (COSTS OFF) SELECT * FROM pc WHERE COALESCE(pf(a), b) = 1;
set enable_partitionwise_aggregate = on;
explain (costs off) select coalesce(pf(a), b), count(*) from pc group by 1;
