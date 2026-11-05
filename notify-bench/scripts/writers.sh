#!/bin/bash
# Writer-side test: control vs notify with ZERO listeners (isolates the commit lock)
# usage: writers.sh <PGBIN> <PGDATA> <PORT> <LABEL> <OUTDIR> [initdb]
set -u
PGBIN=$1; PGDATA=$2; PORT=$3; LABEL=$4; OUT=$5; DOINIT=${6:-no}
export PATH=$PGBIN:$PATH
export PGPORT=$PORT PGHOST=/tmp PGDATABASE=bench
DUR=${DUR:-8}
RES=$OUT/$LABEL.writers.csv
mkdir -p "$OUT"

if [ "$DOINIT" = initdb ]; then
  rm -rf "$PGDATA"
  initdb -D "$PGDATA" -U postgres --no-sync -A trust >/dev/null 2>&1
  cat >> "$PGDATA/postgresql.conf" <<EOF
port = $PORT
unix_socket_directories = '/tmp'
listen_addresses = ''
shared_buffers = 2GB
max_connections = 1000
max_wal_size = 8GB
checkpoint_timeout = 30min
autovacuum = off
fsync = on
log_min_messages = warning
EOF
  pg_ctl -D "$PGDATA" -l "$OUT/$LABEL.pglog" -w start >/dev/null 2>&1
  createdb -U postgres bench 2>/dev/null
  psql -U postgres -q -c "create table t(id bigserial primary key, v int, pad text)" 2>/dev/null
else
  pg_ctl -D "$PGDATA" status >/dev/null 2>&1 || pg_ctl -D "$PGDATA" -l "$OUT/$LABEL.pglog" -w start >/dev/null 2>&1
fi

cat > /tmp/c_$LABEL.sql <<'EOF'
\set c random(1, 1000000)
BEGIN;
INSERT INTO t (v, pad) VALUES (:c, 'abcdefghij');
END;
EOF
cat > /tmp/n_$LABEL.sql <<'EOF'
\set c random(1, 1000000)
BEGIN;
INSERT INTO t (v, pad) VALUES (:c, 'abcdefghij');
NOTIFY hotchan, 'payload';
END;
EOF

run() {  # script clients tag sc
  local tps
  tps=$(pgbench -U postgres -n -f "$1" -c "$2" -j "$(( $2 > 4 ? 4 : $2 ))" -T "$DUR" bench 2>/dev/null \
        | grep -E '^tps' | head -1 | sed -E 's/tps = ([0-9.]+).*/\1/')
  echo "$LABEL,$3,$4,0,$2,${tps:-ERR}" | tee -a "$RES"
}

echo "label,workload,sync_commit,listeners,clients,tps" > "$RES"
for sc in on off; do
  psql -U postgres -q -c "alter system set synchronous_commit='$sc'" -c "select pg_reload_conf()" >/dev/null
  for c in 1 2 4 8 16 32 64; do
    run /tmp/c_$LABEL.sql "$c" control "$sc"
    run /tmp/n_$LABEL.sql "$c" notify  "$sc"
  done
done

# wait-event sampling at 32 clients, sync on
psql -U postgres -q -c "alter system set synchronous_commit='on'" -c "select pg_reload_conf()" >/dev/null
for pair in "n_$LABEL.sql notify32" "c_$LABEL.sql control32"; do
  set -- $pair
  ( pgbench -U postgres -n -f "/tmp/$1" -c 32 -j 4 -T 12 bench >/dev/null 2>&1 ) &
  bp=$!
  sleep 2
  for i in $(seq 1 20); do
    psql -U postgres -tAF, -c "select '$2', coalesce(wait_event_type,'CPU'), coalesce(wait_event,'-'), count(*) from pg_stat_activity where backend_type='client backend' and pid <> pg_backend_pid() and state='active' group by 1,2,3" >> "$OUT/$LABEL.waits.csv" 2>/dev/null
    sleep 0.4
  done
  wait $bp
done

echo "DONE $LABEL writers"
