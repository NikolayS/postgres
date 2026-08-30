#!/bin/bash
# US-2 via gated archive: standby is fed WAL incrementally. It pauses at the
# end of what's currently accessible (restore_command returns failure when
# the next segment isn't yet in the "released" archive). Slot creation
# happens while standby is naturally at archive-end, NOT inside a
# recovery_target_lsn pause.

set -e

BASE=${BASE:-/tmp/sprint0-us2-gated}
PGBIN=${PGBIN:-/usr/lib/postgresql/18/bin}
PPORT=54397
SPORT=54398
USER=$(id -un)

if [ "$1" = cleanup ]; then
    "$PGBIN/pg_ctl" -D "$BASE/primary" stop -m fast 2>/dev/null || true
    "$PGBIN/pg_ctl" -D "$BASE/standby" stop -m fast 2>/dev/null || true
    rm -rf "$BASE"
    echo "Cleanup done."
    exit 0
fi

PSQL_P="$PGBIN/psql -h $BASE -p $PPORT -U $USER -d postgres -q -v ON_ERROR_STOP=1"
PSQL_S="$PGBIN/psql -h $BASE -p $SPORT -U $USER -d postgres -q -v ON_ERROR_STOP=1"
log() { echo "[$(date +%H:%M:%S)] $*"; }

rm -rf "$BASE"
# Two archive directories: REAL (where primary archives to) and GATED (what standby sees)
mkdir -p "$BASE/archive_real" "$BASE/archive_gated" "$BASE/logs"

log "[prod] initdb primary"
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
$PSQL_P -c "SELECT pg_log_standby_snapshot();" >/dev/null
$PSQL_P -c "SELECT pg_switch_wal();" >/dev/null

log "[prod] take base backup"
"$PGBIN/pg_basebackup" -h "$BASE" -p "$PPORT" -U "$USER" -D "$BASE/backup_t1" -Fp -Xs >/dev/null

# Capture L_start NOW — before any incident-related activity. In the real US-2
# scenario the operator picks L_start with margin ("rewind a few minutes before
# the bad event"), not at the exact instant of the DELETE.
$PSQL_P -c "SELECT pg_log_standby_snapshot();" >/dev/null
$PSQL_P -c "SELECT pg_switch_wal();" >/dev/null
sleep 1
L_START=$($PSQL_P -tA -c "SELECT pg_current_wal_lsn();")
LAST_SEG_AT_LSTART=$(ls "$BASE/archive_real/" | grep -v backup | sort | tail -1)
log "[prod] L_start = $L_START  last archived seg at L_start: $LAST_SEG_AT_LSTART"
log "       (operator picks L_start well before the known-bad event)"

log "[prod] normal business traffic during the [L_start, accident] interval"
for i in 1 2 3 4 5; do
    $PSQL_P -c "INSERT INTO orders (customer, amount) VALUES ('biz-$i', $((i * 100)));" >/dev/null
    $PSQL_P -c "SELECT pg_log_standby_snapshot();" >/dev/null
done
$PSQL_P -c "SELECT pg_switch_wal();" >/dev/null
sleep 1

log "[prod] *** the accident: DELETE FROM orders WHERE amount < 100 ***"
$PSQL_P -c "DELETE FROM orders WHERE amount < 100;"
$PSQL_P -c "SELECT pg_log_standby_snapshot();" >/dev/null
$PSQL_P -c "INSERT INTO orders (customer, amount) VALUES ('post-1', 999);" >/dev/null
$PSQL_P -c "SELECT pg_log_standby_snapshot();" >/dev/null
$PSQL_P -c "SELECT pg_switch_wal();" >/dev/null
sleep 1
L_END=$($PSQL_P -tA -c "SELECT pg_current_wal_lsn();")
log "[prod] L_end = $L_end (after DELETE + post-incident insert)"

# =======  GATED RECOVERY  =======
log ""
log "=========== gated recovery ==========="
log ""

log "[recovery] 1. copy basebackup -> throwaway standby"
cp -r "$BASE/backup_t1" "$BASE/standby"
chmod 0700 "$BASE/standby"

log "[recovery] 2. pre-stage archive: ONLY segments <= LAST_SEG_AT_LSTART"
# Copy all segments whose name is lexically <= LAST_SEG_AT_LSTART
cd "$BASE/archive_real"
for seg in *; do
    if [[ "$seg" < "$LAST_SEG_AT_LSTART" ]] || [[ "$seg" == "$LAST_SEG_AT_LSTART" ]] || [[ "$seg" == *".backup" ]]; then
        cp -p "$seg" "$BASE/archive_gated/"
    fi
done
cd - >/dev/null
echo "  Gated archive contains:"
ls "$BASE/archive_gated/" | sed 's/^/    /'
echo "  Real archive has more:"
ls "$BASE/archive_real/" | sed 's/^/    /'

cat > "$BASE/standby/postgresql.auto.conf" <<CFG
listen_addresses = '127.0.0.1'
port = $SPORT
unix_socket_directories = '$BASE'
shared_buffers = 32MB
max_connections = 20
hot_standby = on
restore_command = 'cp $BASE/archive_gated/%f %p'
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

log "[recovery] 3. start standby — it replays gated archive and waits for more"
"$PGBIN/pg_ctl" -D "$BASE/standby" -l "$BASE/logs/standby-startup.log" -w start >/dev/null
sleep 3
REPLAY_AT_GATED_END=$($PSQL_S -tA -c "SELECT pg_last_wal_replay_lsn();")
log "   replay_lsn at gated-archive end: $REPLAY_AT_GATED_END  (L_start=$L_START)"

log "[recovery] 4. while standby waits for next segment, keep primary producing WAL"
log "             (this feeds snapbuild via BACKGROUND arrival through gated archive)"
# PRIMER runs in background, writing to PRIMARY but gated archive won't have its
# records until we release them. However, to allow snapbuild to reach consistency,
# we need some new WAL to arrive in the gated archive. So we release one more
# segment (post-L_start) to give snapbuild forward visibility.
NEXT_SEG=$(ls "$BASE/archive_real/" | grep -v backup | sort | awk -v last="$LAST_SEG_AT_LSTART" '$0 > last {print; exit}')
if [ -n "$NEXT_SEG" ]; then
    log "   releasing one more segment to gated archive: $NEXT_SEG"
    cp -p "$BASE/archive_real/$NEXT_SEG" "$BASE/archive_gated/"
fi
sleep 2

REPLAY_NOW=$($PSQL_S -tA -c "SELECT pg_last_wal_replay_lsn();")
log "   replay_lsn after releasing next seg: $REPLAY_NOW"

log "[recovery] 5. create slot on the (now quiet) standby"
# Primer on primary to keep fresh running-xacts flowing (even though gated archive limits what arrives)
touch "$BASE/primer.keep"
(
    set +e
    i=0
    while [ -f "$BASE/primer.keep" ]; do
        $PSQL_P -c "INSERT INTO orders (customer, amount) VALUES ('primer-'||$i, 0.01);" >/dev/null 2>&1
        $PSQL_P -c "SELECT pg_log_standby_snapshot();" >/dev/null 2>&1
        i=$((i+1))
        sleep 1
    done
) &
PRIMER_PID=$!
sleep 1

# Release new segments to gated archive periodically in background so snapbuild has forward visibility
touch "$BASE/releaser.keep"
(
    set +e
    while [ -f "$BASE/releaser.keep" ]; do
        for seg in "$BASE/archive_real"/*; do
            bn=$(basename "$seg")
            if [ ! -f "$BASE/archive_gated/$bn" ]; then
                cp -p "$seg" "$BASE/archive_gated/"
            fi
        done
        sleep 1
    done
) &
RELEASER_PID=$!

$PSQL_S -c "SET statement_timeout='60s';
            SELECT * FROM pg_create_logical_replication_slot('recovery_slot','test_decoding');"

SLOT_RESTART=$($PSQL_S -tA -c "SELECT restart_lsn FROM pg_replication_slots WHERE slot_name='recovery_slot';")
SLOT_CATMIN=$($PSQL_S -tA -c "SELECT catalog_xmin FROM pg_replication_slots WHERE slot_name='recovery_slot';")
REPLAY_AT_SLOT=$($PSQL_S -tA -c "SELECT pg_last_wal_replay_lsn();")
CAN_SEE=$($PSQL_S -tA -c "SELECT '$SLOT_RESTART'::pg_lsn <= '$L_START'::pg_lsn;")
log "   slot restart_lsn=$SLOT_RESTART catalog_xmin=$SLOT_CATMIN"
log "   standby replay_lsn at slot creation: $REPLAY_AT_SLOT"
log "   L_start=$L_START  L_end=$L_END"
log "   **can slot decode L_start? restart_lsn <= L_start ? $CAN_SEE**"

log "[recovery] 6. wait for replay past L_end, pause"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    REPLAY=$($PSQL_S -tA -c "SELECT pg_last_wal_replay_lsn();")
    PAST=$($PSQL_S -tA -c "SELECT '$REPLAY'::pg_lsn >= '$L_END'::pg_lsn;")
    log "   [${i}s] replay_lsn=$REPLAY  past L_end? $PAST"
    if [ "$PAST" = "t" ]; then break; fi
done

rm -f "$BASE/primer.keep" "$BASE/releaser.keep"
wait $PRIMER_PID 2>/dev/null || true
wait $RELEASER_PID 2>/dev/null || true
$PSQL_S -c "SELECT pg_wal_replay_pause();" >/dev/null

log "[recovery] 7. drain the slot"
$PSQL_S -c "SELECT lsn, xid, data FROM pg_logical_slot_get_changes('recovery_slot',NULL,NULL) WHERE data LIKE '%public.orders%' ORDER BY lsn;"

log "=========== end ==========="
