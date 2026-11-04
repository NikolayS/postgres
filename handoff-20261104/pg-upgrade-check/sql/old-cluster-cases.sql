-- Run each block on a fresh 18 cluster (one case per cluster), then run
-- pg_upgrade --check to 19 and a real upgrade. Unpatched 19: --check says
-- "Clusters are compatible" and the real upgrade fails during restore.
-- Patched 19 (shihao's nocfbot-v4-REL_19): --check fails and names the object.

-- scs_role
create role app login; alter role app set standard_conforming_strings = off;
-- scs_db
create database appdb; alter database appdb set standard_conforming_strings = off;
-- scs_func
create function f() returns int language sql set standard_conforming_strings = off as 'select 1';
-- esw_role
create role app login; alter role app set escape_string_warning = off;
-- esw_db
create database appdb; alter database appdb set escape_string_warning = on;
-- esw_func
create function f() returns int language sql set escape_string_warning = off as 'select 1';
-- cast
create cast (uuid as bytea) with function uuid_send(uuid);
-- clean (control)
create table t (a int); insert into t values (1);
