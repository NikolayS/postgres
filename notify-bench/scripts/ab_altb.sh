#!/bin/bash
# A/B test isolating the NOTIFY commit lock.
#
# Same binary throughout. The instrumented build skips
# LockSharedObject() in PreCommit_Notify() iff PG_NOTIFY_NOLOCK is set in the
# postmaster environment, so the ONLY difference between the "notify" and
# "notify_nolock" arms is that one lock. Everything else NOTIFY costs
# (XID assignment, SLRU writes, extra WAL, signalling) is present in both.
#
# NOTE: the nolock arm breaks the commit-order guarantee. It is a measurement
# device, not a proposed behaviour.
#
# usage: ab_lock.sh <PGBIN> <PGDATA> <PORT> <OUTDIR>
set -u
PGBIN=$1; PGDATA=$2; PORT=$3; OUT=$4
export PATH=$PGBIN:$PATH
export PGPORT=$PORT PGHOST=/tmp PGDATABASE=bench
DUR=${DUR:-10}
REPS=${REPS:-3}
CLIENTS=${CLIENTS:-"1 4 16 64"}
RES=$OUT/ab_altb.csv
mkdir -p "$OUT"

start_server() {   # $1 = "lock" | "nolock"
  pg_ctl -D "$PGDATA" -m immediate -w stop >/dev/null 2>&1
  if [ "$1" = nolock ]; then
    PG_NOTIFY_NOLOCK=1 pg_ctl -D "$PGDATA" -l "$OUT/ab.pglog" -w start >/dev/null 2>&1
  else
    unset PG_NOTIFY_NOLOCK
    pg_ctl -D "$PGDATA" -l "$OUT/ab.pglog" -w start >/dev/null 2>&1
  fi
  psql -U postgres -q -c "alter system set synchronous_commit='on'" -c "select pg_reload_conf()" >/dev/null 2>&1
}

init() {
  rm -rf "$PGDATA"
  initdb -D "$PGDATA" -U postgres --no-sync -A trust >/dev/null 2>&1
  cat >> "$PGDATA/postgresql.conf" <<EOF
port = $PORT
unix_socket_directories = '/tmp'
listen_addresses = ''
shared_buffers = 2GB
max_connections = 1000
max_wal_size = 16GB
checkpoint_timeout = 60min
autovacuum = off
fsync = on
synchronous_commit = on
log_min_messages = warning
EOF
  pg_ctl -D "$PGDATA" -l "$OUT/ab.pglog" -w start >/dev/null 2>&1
  createdb -U postgres bench 2>/dev/null
  psql -U postgres -q -c "create table t(id bigserial primary key, v int, pad text)" 2>/dev/null
}

cat > /tmp/ab_control.sql <<'EOF'
\set c random(1, 1000000)
BEGIN;
INSERT INTO t (v, pad) VALUES (:c, 'abcdefghij');
END;
EOF
cat > /tmp/ab_notify.sql <<'EOF'
\set c random(1, 1000000)
BEGIN;
INSERT INTO t (v, pad) VALUES (:c, 'abcdefghij');
NOTIFY hotchan, 'payload';
END;
EOF

# verify the env switch is actually in effect: with the lock, concurrent
# notifiers must show Lock/object waits; without it, they must not.
verify_arm() {   # $1 = expected arm
  ( pgbench -U postgres -n -f /tmp/ab_notify.sql -c 16 -j 4 -T 6 bench >/dev/null 2>&1 ) &
  local bp=$! n=0
  sleep 2
  for i in 1 2 3 4 5; do
    n=$((n + $(psql -U postgres -tAc "select count(*) from pg_stat_activity where wait_event_type='Lock' and wait_event='object'" 2>/dev/null)))
    sleep 0.3
  done
  wait $bp
  echo "verify,$1,lock_object_samples,$n" | tee -a "$RES"
}

run() {   # $1 script, $2 clients, $3 tag, $4 rep
  local o tps lat
  o=$(pgbench -U postgres -n -f "$1" -c "$2" -j "$(( $2 > 4 ? 4 : $2 ))" -T "$DUR" bench 2>/dev/null)
  tps=$(echo "$o" | grep -E '^tps' | head -1 | sed -E 's/tps = ([0-9.]+).*/\1/')
  lat=$(echo "$o" | grep -E 'latency average' | head -1 | sed -E 's/.*= ([0-9.]+) ms.*/\1/')
  echo "$3,$2,$4,${tps:-ERR},${lat:-ERR}" | tee -a "$RES"
}

echo "workload,clients,rep,tps,latency_ms" > "$RES"
init

# ---- arm 1: stock behaviour (lock present)
start_server lock
verify_arm lock
pgbench -U postgres -n -f /tmp/ab_notify.sql -c 8 -j 4 -T 5 bench >/dev/null 2>&1   # warmup
for c in $CLIENTS; do
  for r in $(seq 1 $REPS); do
    run /tmp/ab_control.sql "$c" control "$r"
    run /tmp/ab_notify.sql  "$c" notify_altb "$r"
  done
done

pg_ctl -D "$PGDATA" -m immediate -w stop >/dev/null 2>&1
echo "DONE ab_altb"
