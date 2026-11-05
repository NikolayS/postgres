#!/bin/bash
# Verify the PG_NOTIFY_NOLOCK switch separates the two arms.
set -u
export PATH=/home/user/pg-nolock-inst/bin:$PATH
export PGHOST=/tmp PGPORT=55434 PGDATABASE=bench
D=/home/pgbench/data-nolock

rm -rf $D
initdb -D $D -U postgres --no-sync -A trust >/dev/null 2>&1
cat >> $D/postgresql.conf <<EOF
port = 55434
unix_socket_directories = '/tmp'
listen_addresses = ''
shared_buffers = 1GB
max_connections = 200
fsync = on
synchronous_commit = on
log_min_messages = warning
EOF

cat > /tmp/vn.sql <<'EOF'
\set c random(1, 1000000)
BEGIN;
INSERT INTO t (v, pad) VALUES (:c, 'abcdefghij');
NOTIFY hotchan, 'payload';
END;
EOF

for arm in lock nolock; do
  pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1
  if [ "$arm" = nolock ]; then
    PG_NOTIFY_NOLOCK=1 pg_ctl -D $D -l /home/pgbench/nolock.log -w start >/dev/null 2>&1
  else
    pg_ctl -D $D -l /home/pgbench/nolock.log -w start >/dev/null 2>&1
  fi
  createdb -U postgres bench 2>/dev/null
  psql -U postgres -q -c "create table if not exists t(id bigserial primary key, v int, pad text)" >/dev/null 2>&1

  ( pgbench -U postgres -n -f /tmp/vn.sql -c 16 -j 4 -T 6 bench > /tmp/out.$arm 2>&1 ) &
  bp=$!
  sleep 2
  n=0
  for i in 1 2 3 4 5; do
    c=$(psql -U postgres -tAc "select count(*) from pg_stat_activity where wait_event_type = 'Lock' and wait_event = 'object'" 2>/dev/null)
    c=${c:-0}
    n=$((n + c))
    sleep 0.4
  done
  wait $bp
  printf 'ARM=%-7s lock_object_samples=%-4s %s\n' "$arm" "$n" "$(grep -E '^tps' /tmp/out.$arm | head -1)"
done

pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1
