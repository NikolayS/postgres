#!/bin/bash
# Minimal reproducer for blueprints/LOGICAL_DECODING_ARCHIVED_WALS.md Sprint 0 G3.
#
# Demonstrates: a logical slot on an archive-only PostgreSQL 18 standby is
# invalidated by replay of Heap2/PRUNE_ON_ACCESS WAL records against the
# pg_statistic catalog relation whose snapshotConflictHorizon crosses the
# slot's catalog_xmin. Trigger: autoanalyze (implicit or explicit ANALYZE)
# producing dead tuples in pg_statistic, then VACUUM pruning them.
#
# Requires: PostgreSQL 18 server + client (PGDG apt pkgs are fine), sudo NOT
# needed, runs entirely as an unprivileged user under $BASE.
# Runtime: ~1-2 minutes end-to-end.
# Cleanup: $0 cleanup

set -e

BASE=${BASE:-/tmp/sprint0-repro}
PGBIN=${PGBIN:-/usr/lib/postgresql/18/bin}
PPORT=54391
SPORT=54392
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
mkdir -p "$BASE/archive" "$BASE/logs"

log "1. initdb primary"
"$PGBIN/initdb" -D "$BASE/primary" --locale=C --encoding=UTF8 \
    --auth=trust --username="$USER" >/dev/null

cat > "$BASE/primary/postgresql.auto.conf" <<CFG
listen_addresses = '127.0.0.1'
port = $PPORT
unix_socket_directories = '$BASE'
shared_buffers = 32MB
wal_buffers = 1MB
max_connections = 20
max_wal_senders = 5
max_replication_slots = 5
wal_level = logical
archive_mode = on
archive_command = 'cp %p $BASE/archive/%f'
archive_timeout = 5s
fsync = off
synchronous_commit = off
full_page_writes = off
autovacuum = on
logging_collector = on
log_directory = '$BASE/logs'
log_filename = 'primary.log'
CFG

log "2. start primary, seed table"
"$PGBIN/pg_ctl" -D "$BASE/primary" -l "$BASE/logs/primary-startup.log" -w start >/dev/null
$PSQL_P -c "CREATE TABLE t (id serial PRIMARY KEY, payload text);"
$PSQL_P -c "INSERT INTO t (payload) SELECT 'seed-' || g FROM generate_series(1,10) g;"
$PSQL_P -c "SELECT pg_log_standby_snapshot();" >/dev/null
$PSQL_P -c "SELECT pg_switch_wal();" >/dev/null

log "3. pg_basebackup -> standby"
"$PGBIN/pg_basebackup" -h "$BASE" -p "$PPORT" -U "$USER" \
    -D "$BASE/standby" -Fp -Xs >/dev/null
chmod 0700 "$BASE/standby"

cat > "$BASE/standby/postgresql.auto.conf" <<CFG
listen_addresses = '127.0.0.1'
port = $SPORT
unix_socket_directories = '$BASE'
shared_buffers = 32MB
wal_buffers = 1MB
max_connections = 20
hot_standby = on
restore_command = 'cp $BASE/archive/%f %p'
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

log "4. start archive-fed standby (no walreceiver)"
"$PGBIN/pg_ctl" -D "$BASE/standby" -l "$BASE/logs/standby-startup.log" -w start >/dev/null
$PSQL_S -c "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn();"

log "5. create logical slot on standby (force running-xacts first)"
$PSQL_P -c "SELECT pg_log_standby_snapshot();" >/dev/null
$PSQL_P -c "INSERT INTO t (payload) VALUES ('pre-slot');" >/dev/null
$PSQL_P -c "SELECT pg_log_standby_snapshot();" >/dev/null
$PSQL_P -c "SELECT pg_switch_wal();" >/dev/null
sleep 2
$PSQL_S -c "SET statement_timeout='60s';
            SELECT * FROM pg_create_logical_replication_slot('decoder','test_decoding');"
SLOT_INFO=$($PSQL_S -tA -c "SELECT slot_name || ' catalog_xmin=' || catalog_xmin || ' restart_lsn=' || restart_lsn FROM pg_replication_slots WHERE slot_name='decoder';")
log "   slot state: $SLOT_INFO"

log "6. trigger G3 by generating pg_statistic dead tuples + VACUUM"
# Drive inserts + repeated ANALYZE to rewrite pg_statistic rows (creating dead tuples)
for i in $(seq 1 30); do
    $PSQL_P -c "INSERT INTO t (payload) VALUES ('churn-$i');" >/dev/null
    $PSQL_P -c "ANALYZE t;" >/dev/null
done
# Now explicitly VACUUM pg_statistic — this produces the xl_heap_vacuum /
# Heap2/PRUNE_ON_ACCESS WAL record whose snapshotConflictHorizon will
# cross the slot's catalog_xmin on standby replay.
log "   running VACUUM pg_statistic (expected to prune dead tuples)"
$PSQL_P -c "VACUUM (VERBOSE) pg_statistic;" 2>&1 | grep -E 'tuples:|removable cutoff' | head -3

# Force WAL completion so the prune record reaches the archive promptly
$PSQL_P -c "INSERT INTO t (payload) VALUES ('flush1');" >/dev/null
$PSQL_P -c "SELECT pg_switch_wal();" >/dev/null
$PSQL_P -c "INSERT INTO t (payload) VALUES ('flush2');" >/dev/null
$PSQL_P -c "SELECT pg_switch_wal();" >/dev/null

log "7. monitor slot until invalidated (poll every 3s, max 45s)"
INVALIDATED=0
for i in $(seq 1 15); do
    sleep 3
    STATE=$($PSQL_S -tA -c "SELECT wal_status || '|' || conflicting || '|' || coalesce(invalidation_reason,'-') FROM pg_replication_slots WHERE slot_name='decoder';" 2>/dev/null || echo "query-failed")
    log "   t+$((i*3))s  slot: $STATE"
    if echo "$STATE" | grep -q lost; then
        log "*** INVALIDATED at t+$((i*3))s ***"
        INVALIDATED=1
        break
    fi
done

log "8. invalidation WAL record from standby log"
grep -E 'invalidating obsolete|snapshotConflictHorizon.*isCatalogRel' "$BASE/logs/standby.log" | tail -4 || true

log "9. final slot state"
$PSQL_S -c "SELECT slot_name, catalog_xmin, restart_lsn, wal_status, conflicting, invalidation_reason FROM pg_replication_slots;" -x

if [ "$INVALIDATED" = 1 ]; then
    log "Result: G3 REPRODUCED — slot invalidated by pg_statistic PRUNE replay."
else
    log "Result: slot still alive at end of window — might need more catalog churn."
fi
log "Cleanup: $0 cleanup"
