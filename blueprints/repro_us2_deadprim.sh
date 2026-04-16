#!/bin/bash
# Can US-2 succeed WITHOUT a live primary during recovery?
#
# Key idea: gate archive to stop BEFORE the segment containing the
# quiet-moment running_xacts record. standby replays to archive end,
# restart_lsn lands BEFORE the record. Then release L_QUIET's segment
# during slot creation so snapbuild's forward read finds it.

set -e

BASE=${BASE:-/tmp/sprint0-deadprim}
PGBIN=${PGBIN:-/usr/lib/postgresql/18/bin}
PPORT=54403
SPORT=54404
USER=$(id -un)
WINDOW_SECONDS=${WINDOW_SECONDS:-30}

if [ "$1" = cleanup ]; then
    "$PGBIN/pg_ctl" -D "$BASE/primary" stop -m fast 2>/dev/null || true
    "$PGBIN/pg_ctl" -D "$BASE/standby" stop -m fast 2>/dev/null || true
    rm -f "$BASE"/*.keep
    rm -rf "$BASE"
    echo "Cleanup done."
    exit 0
fi

PSQL_P="$PGBIN/psql -h $BASE -p $PPORT -U $USER -d postgres -q -v ON_ERROR_STOP=1"
PSQL_S="$PGBIN/psql -h $BASE -p $SPORT -U $USER -d postgres -q -v ON_ERROR_STOP=1"
log() { echo "[$(date +%H:%M:%S)] $*"; }

rm -rf "$BASE"
mkdir -p "$BASE/archive_real" "$BASE/archive_gated" "$BASE/logs"

log "[prod] setup primary"
"$PGBIN/initdb" -D "$BASE/primary" --locale=C --auth=trust --username="$USER" >/dev/null
cat > "$BASE/primary/postgresql.auto.conf" <<CFG
listen_addresses = '127.0.0.1'
port = $PPORT
unix_socket_directories = '$BASE'
shared_buffers = 32MB
max_connections = 20
max_wal_senders = 5
max_replication_slots = 5
wal_level = logical
archive_mode = on
archive_command = 'cp %p $BASE/archive_real/%f'
archive_timeout = 3s
wal_retrieve_retry_interval = 1s
fsync = off
synchronous_commit = off
full_page_writes = off
autovacuum = on
logging_collector = on
log_directory = '$BASE/logs'
log_filename = 'primary.log'
CFG
"$PGBIN/pg_ctl" -D "$BASE/primary" -l "$BASE/logs/primary-startup.log" -w start >/dev/null

$PSQL_P -c "CREATE TABLE orders (id serial PRIMARY KEY, customer text, amount numeric);"
$PSQL_P -c "ALTER TABLE orders REPLICA IDENTITY FULL;"
$PSQL_P -c "INSERT INTO orders (customer, amount) VALUES
    ('alice',100),('bob',250.5),('carol',9.99),('dave',4500),('erin',75);"

log "[prod] take base backup"
"$PGBIN/pg_basebackup" -h "$BASE" -p "$PPORT" -U "$USER" -D "$BASE/backup_t1" -Fp -Xs >/dev/null

log "[prod] FORCE a pg_switch_wal BEFORE the quiet-moment snapshot so seg boundary is clean"
$PSQL_P -c "SELECT pg_switch_wal();" >/dev/null
sleep 2   # let bgwriter/idle settle
PRE_QUIET_SEG=$(ls "$BASE/archive_real/" | grep -v backup | sort | tail -1)

log "[prod] *** quiet-moment pg_log_standby_snapshot — this lands INSIDE next segment"
$PSQL_P -c "SELECT pg_log_standby_snapshot();" >/dev/null
QUIET_LSN=$($PSQL_P -tA -c "SELECT pg_current_wal_lsn();")
$PSQL_P -c "SELECT pg_switch_wal();" >/dev/null
sleep 1
L_QUIET_END=$($PSQL_P -tA -c "SELECT pg_current_wal_lsn();")
QUIET_SEG=$(ls "$BASE/archive_real/" | grep -v backup | sort | awk -v prev="$PRE_QUIET_SEG" '$0"" > prev"" {print; exit}')
log "[prod] PRE_QUIET_SEG=$PRE_QUIET_SEG  QUIET_LSN=$QUIET_LSN  QUIET_SEG=$QUIET_SEG"
log "       dump of QUIET_SEG to confirm path-(a) record:"
"$PGBIN/pg_waldump" "$BASE/archive_real/$QUIET_SEG" 2>&1 | grep RUNNING_XACTS | head -2

# ============  HEAVY OLTP AFTER QUIET SNAPSHOT  ============
log "[prod] HEAVY OLTP — ${WINDOW_SECONDS}s"
touch "$BASE/prod.keep"
(
    set +e
    i=0
    END=$(( $(date +%s) + WINDOW_SECONDS ))
    while [ -f "$BASE/prod.keep" ] && [ "$(date +%s)" -lt "$END" ]; do
        $PSQL_P -c "INSERT INTO orders (customer, amount) VALUES ('busy-'||$i, $((i * 17)) % 1000);" >/dev/null 2>&1
        i=$((i+1))
    done
) > "$BASE/logs/prod-workload.log" 2>&1 &
PROD_PID=$!
sleep $WINDOW_SECONDS
rm -f "$BASE/prod.keep"
wait $PROD_PID 2>/dev/null || true

log "[prod] *** the accident ***"
$PSQL_P -c "DELETE FROM orders WHERE amount < 50;" >/dev/null
$PSQL_P -c "INSERT INTO orders (customer, amount) VALUES ('post-accident', 1);" >/dev/null
$PSQL_P -c "SELECT pg_switch_wal();" >/dev/null
sleep 1
L_END=$($PSQL_P -tA -c "SELECT pg_current_wal_lsn();")
log "[prod] L_end = $L_END"

# ============  KILL THE PRIMARY (simulate dead primary) ============
log "[prod] >>> PRIMARY KILLED — operator only has archive + base backup"
"$PGBIN/pg_ctl" -D "$BASE/primary" stop -m fast >/dev/null
sleep 1

# ============  RECOVERY: gate BEFORE the L_QUIET segment ============
log ""
log "=========== recovery with DEAD primary ==========="
log ""

log "[recovery] 1. restore base backup"
cp -r "$BASE/backup_t1" "$BASE/standby"
chmod 0700 "$BASE/standby"

log "[recovery] 2. pre-stage archive up to PRE_QUIET_SEG ($PRE_QUIET_SEG) — NOT including QUIET_SEG"
for seg in "$BASE/archive_real"/*; do
    bn=$(basename "$seg")
    if [[ "$bn" < "$PRE_QUIET_SEG" ]] || [ "$bn" = "$PRE_QUIET_SEG" ] || [[ "$bn" == *".backup" ]]; then
        cp -p "$seg" "$BASE/archive_gated/"
    fi
done
echo "  gated archive (should stop at $PRE_QUIET_SEG):"
ls "$BASE/archive_gated/" | sed 's/^/    /'

cat > "$BASE/standby/postgresql.auto.conf" <<CFG
listen_addresses = '127.0.0.1'
port = $SPORT
unix_socket_directories = '$BASE'
shared_buffers = 32MB
max_connections = 20
hot_standby = on
restore_command = 'cp $BASE/archive_gated/%f %p'
wal_retrieve_retry_interval = 1s
max_slot_wal_keep_size = -1
archive_mode = off
wal_level = logical
fsync = off
synchronous_commit = off
full_page_writes = off
logging_collector = on
log_directory = '$BASE/logs'
log_filename = 'standby.log'
log_min_messages = debug1
CFG
touch "$BASE/standby/standby.signal"

log "[recovery] 3. start standby — replay stops BEFORE L_QUIET segment"
"$PGBIN/pg_ctl" -D "$BASE/standby" -l "$BASE/logs/standby-startup.log" -w start >/dev/null
sleep 3
REPLAY_AT_GATE=$($PSQL_S -tA -c "SELECT pg_last_wal_replay_lsn();")
log "   replay_lsn at gate: $REPLAY_AT_GATE  (QUIET_LSN=$QUIET_LSN)"

log "[recovery] 4. start slot creation (will block), release L_QUIET segment in parallel"
# Launch slot creation in background
(
    $PSQL_S -c "SET statement_timeout='120s';
                SELECT * FROM pg_create_logical_replication_slot('recovery_slot','test_decoding');"
) > "$BASE/logs/slot-create.log" 2>&1 &
SLOTJOB=$!

sleep 3

log "[recovery] 5. release QUIET_SEG to gated archive — standby should pick it up"
cp -p "$BASE/archive_real/$QUIET_SEG" "$BASE/archive_gated/"

# Release remaining segments too so we can drain window later
for seg in "$BASE/archive_real"/*; do
    bn=$(basename "$seg")
    if [ ! -f "$BASE/archive_gated/$bn" ]; then
        cp -p "$seg" "$BASE/archive_gated/"
    fi
done

# Wait for slot creation to finish
wait $SLOTJOB 2>/dev/null || true

log "[recovery] 6. slot creation result:"
cat "$BASE/logs/slot-create.log"
echo "---"

$PSQL_S -c "SELECT slot_name, catalog_xmin, restart_lsn, confirmed_flush_lsn, wal_status, conflicting, invalidation_reason FROM pg_replication_slots;"

SLOT_RESTART=$($PSQL_S -tA -c "SELECT restart_lsn FROM pg_replication_slots WHERE slot_name='recovery_slot';" 2>/dev/null || echo "none")
if [ "$SLOT_RESTART" = "none" ] || [ -z "$SLOT_RESTART" ]; then
    log "RESULT: slot NOT created (dead-primary US-2 not viable even with gating trick)"
else
    log "RESULT: slot created, restart_lsn=$SLOT_RESTART"
    log "[recovery] 7. wait for replay past L_end, pause"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        REPLAY=$($PSQL_S -tA -c "SELECT pg_last_wal_replay_lsn();")
        PAST=$($PSQL_S -tA -c "SELECT '$REPLAY'::pg_lsn >= '$L_END'::pg_lsn;")
        if [ "$PAST" = "t" ]; then log "   replay past L_end: $REPLAY"; break; fi
    done
    $PSQL_S -c "SELECT pg_wal_replay_pause();" >/dev/null
    log "[recovery] 8. drain slot"
    $PSQL_S -c "SELECT count(*) AS total, count(*) FILTER (WHERE data LIKE '%DELETE%') AS deletes
                FROM pg_logical_slot_peek_changes('recovery_slot',NULL,NULL);"
    $PSQL_S -c "SELECT lsn, xid, substring(data, 1, 120) FROM pg_logical_slot_peek_changes('recovery_slot',NULL,NULL)
                WHERE data LIKE '%DELETE%' ORDER BY lsn LIMIT 5;"
fi

log "Cleanup: $0 cleanup"
