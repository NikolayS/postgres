-- JSON_ARRAY() expression index over float8[] goes stale on
-- REL_19_STABLE with v5 (float8out is still IMMUTABLE on 19).
-- Expected: 18 rejects the CREATE INDEX; 19 + v5 accepts it and the
-- index scan returns 0 while a seq scan returns 1; 19 + v5 + the
-- nocfbot patch rejects the CREATE INDEX.
-- The first block up to the first select is the SQL from the email,
-- run as-is. The seq-scan select after it was added for the hand-off.
create table t (f float8[]);
insert into t values ('{0.30000000000000004}');
create index t_i on t ((json_array(f returning jsonb)));
set extra_float_digits = 0;
set enable_seqscan = off;
select count(*) from t where json_array(f returning jsonb) = '[[0.3]]';
reset enable_seqscan;
set enable_indexscan = off;
set enable_bitmapscan = off;
select count(*) from t where json_array(f returning jsonb) = '[[0.3]]';
reset all;
drop table t;

-- Same with bytea[] and bytea_output = escape. We confirmed this case
-- (index 0, seq 1 on 19 + v5) with an equivalent script; this exact
-- block was written for the hand-off and was not run as-is.
create table tb (b bytea[]);
insert into tb values (array['\x01'::bytea]);
create index tb_i on tb ((json_array(b returning jsonb)));
set bytea_output = escape;
set enable_seqscan = off;
select count(*) from tb where json_array(b returning jsonb) = json_array(array['\x01'::bytea] returning jsonb);
reset enable_seqscan;
set enable_indexscan = off;
set enable_bitmapscan = off;
select count(*) from tb where json_array(b returning jsonb) = json_array(array['\x01'::bytea] returning jsonb);
reset all;
drop table tb;
