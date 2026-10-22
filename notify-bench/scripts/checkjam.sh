#!/bin/bash
# Does a psql listener reading from a FIFO actually drain notifications,
# or does it jam in ClientWrite once the socket buffer fills?
set -u
export PATH=/home/user/pg-master/bin:$PATH
export PGHOST=/tmp PGPORT=55432 PGDATABASE=bench
D=/home/pgbench/data-master

pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1
pg_ctl -D $D -l /home/pgbench/jam.log -w start >/dev/null 2>&1
psql -U postgres -q -c "create table if not exists t(id bigserial primary key, v int, pad text)" >/dev/null 2>&1

for i in $(seq 1 50); do
  mkfifo /tmp/jf.$i 2>/dev/null
  ( psql -U postgres -q -f /tmp/jf.$i >/dev/null 2>&1 ) &
  ( echo "LISTEN hotchan;"; exec sleep 100000 ) > /tmp/jf.$i &
done
sleep 4
echo "listeners connected: $(psql -U postgres -tAc "select count(*) from pg_stat_activity where backend_type='client backend'")"

cat > /tmp/jam.sql <<'EOF'
\set c random(1, 1000000)
BEGIN;
INSERT INTO t (v, pad) VALUES (:c, 'abcdefghij');
NOTIFY hotchan, 'payload';
END;
EOF

( pgbench -U postgres -n -f /tmp/jam.sql -c 8 -j 4 -T 12 bench >/tmp/jam.out 2>&1 ) &
bp=$!
sleep 3
echo "--- listener backend wait events during sustained notify load ---"
for s in 1 2 3; do
  psql -U postgres -tAF'|' -c "
    select coalesce(wait_event_type,'CPU'), coalesce(wait_event,'-'), state, count(*)
    from pg_stat_activity
    where backend_type='client backend' and query like 'LISTEN%'
    group by 1,2,3 order by 4 desc"
  sleep 2
done
echo "--- queue usage (tail pinned?) ---"
psql -U postgres -tAc "select pg_notification_queue_usage()"
wait $bp
grep -E '^tps' /tmp/jam.out

pkill -u "$(id -un)" psql 2>/dev/null
pkill -u "$(id -un)" -f "sleep 100000" 2>/dev/null
rm -f /tmp/jf.* 2>/dev/null
pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1
