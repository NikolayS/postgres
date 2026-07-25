#!/bin/bash
# Listener-scaling test v2 — hard reset (server restart) between configurations
# usage: listeners2.sh <PGBIN> <PGDATA> <PORT> <LABEL> <OUTDIR>
set -u
PGBIN=$1; PGDATA=$2; PORT=$3; LABEL=$4; OUT=$5
export PATH=$PGBIN:$PATH
export PGPORT=$PORT PGHOST=/tmp PGDATABASE=bench
DUR=${DUR:-8}
RES=$OUT/$LABEL.listeners2.csv

reset_server() {
  pkill -u "$(id -un)" psql 2>/dev/null
  pkill -u "$(id -un)" -f "sleep 100000" 2>/dev/null
  pg_ctl -D "$PGDATA" -m immediate -w stop >/dev/null 2>&1
  rm -f /tmp/lfifo.* 2>/dev/null
  pg_ctl -D "$PGDATA" -l "$OUT/$LABEL.pglog" -w start >/dev/null 2>&1
  psql -U postgres -q -c "alter system set synchronous_commit='off'" -c "select pg_reload_conf()" >/dev/null 2>&1
}

start_listeners() {   # $1 = count, $2 = hot|spread
  local n=$1 mode=$2 ch
  for i in $(seq 1 "$n"); do
    if [ "$mode" = hot ]; then ch=hotchan; else ch="idle$i"; fi
    mkfifo "/tmp/lfifo.$i" 2>/dev/null
    ( psql -U postgres -q -f "/tmp/lfifo.$i" >/dev/null 2>&1 ) &
    ( echo "LISTEN $ch;"; exec sleep 100000 ) > "/tmp/lfifo.$i" &
  done
  sleep 5
}

run() {   # $1 script, $2 clients, $3 tag, $4 listeners
  local live tps
  live=$(psql -U postgres -tAc "select count(*) from pg_stat_activity where backend_type='client backend'" 2>/dev/null)
  tps=$(pgbench -U postgres -n -f "$1" -c "$2" -j 4 -T "$DUR" bench 2>/dev/null \
        | grep -E '^tps' | head -1 | sed -E 's/tps = ([0-9.]+).*/\1/')
  echo "$LABEL,$3,$4,$live,$2,${tps:-ERR}" | tee -a "$RES"
}

reset_server
psql -U postgres -q -c "create table if not exists t(id bigserial primary key, v int, pad text)" >/dev/null 2>&1

cat > /tmp/nr_$LABEL.sql <<'EOF'
\set c random(1, 1000000)
\set ch random(1, 1000)
BEGIN;
INSERT INTO t (v, pad) VALUES (:c, 'abcdefghij');
SELECT pg_notify('cold' || :ch, 'payload');
END;
EOF
cat > /tmp/nh_$LABEL.sql <<'EOF'
\set c random(1, 1000000)
BEGIN;
INSERT INTO t (v, pad) VALUES (:c, 'abcdefghij');
NOTIFY hotchan, 'payload';
END;
EOF

echo "label,workload,listeners_requested,sessions_live,clients,tps" > "$RES"

for L in 0 50 200 500; do
  reset_server
  [ "$L" -gt 0 ] && start_listeners "$L" spread
  run /tmp/nr_$LABEL.sql 8 notify_uninterested "$L"
done

for L in 0 50 200 500; do
  reset_server
  [ "$L" -gt 0 ] && start_listeners "$L" hot
  run /tmp/nh_$LABEL.sql 8 notify_interested "$L"
done

reset_server
echo "DONE $LABEL listeners2"
