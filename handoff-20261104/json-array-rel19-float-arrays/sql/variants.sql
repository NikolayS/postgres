\set VERBOSITY terse
create type comp_f as (a float8, b int);
create domain d_f8 as float8;
create table v (f4 float4, f8 float8, b bytea, i int[], tx text[], n numeric[], c comp_f, df d_f8, p point, s text, i1 int, f8a float8[]);
\echo 01 scalar float4
create index on v ((json_array(f4 returning jsonb)));
\echo 02 scalar float8
create index on v ((json_array(f8 returning jsonb)));
\echo 03 scalar bytea
create index on v ((json_array(b returning jsonb)));
\echo 04 int[]
create index on v ((json_array(i returning jsonb)));
\echo 05 text[]
create index on v ((json_array(tx returning jsonb)));
\echo 06 numeric[]
create index on v ((json_array(n returning jsonb)));
\echo 07 composite with float field
create index on v ((json_array(c returning jsonb)));
\echo 08 json_object float value
create index on v ((json_object('k' value f8 returning jsonb)));
\echo 09 json_object float key
create index on v ((json_object(f8::text : f4 returning jsonb)));
\echo 10 nested json_array of float8
create index on v ((json_array(json_array(f8 returning jsonb), i1 returning jsonb)));
\echo 11 scalar domain over float8
create index on v ((json_array(df returning jsonb)));
\echo 12 scalar point
create index on v ((json_array(p returning jsonb)));
\echo 13 text + int
create index on v ((json_object(s value i1 returning jsonb)));
\echo 14 nested json_array(f8a) inside json_array
create index on v ((json_array(json_array(f8a returning jsonb) returning jsonb)));
\echo 15 json_scalar float8 / json_scalar float8 via JSON() 
create index on v ((json_scalar(f8)::jsonb));
\echo 16 generated column float8[]
create table g (f float8[], j jsonb generated always as (json_array(f returning jsonb)) stored);
\echo 17 partition key float8[]
create table pk (f float8[]) partition by list ((json_array(f returning jsonb)));
