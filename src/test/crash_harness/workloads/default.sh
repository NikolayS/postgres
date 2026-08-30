#!/usr/bin/env bash
# src/test/crash_harness/workloads/default.sh
#
# Default mixed workload run by the crash-consistency harness during the
# `record` phase. Gets PGHOST/PGPORT/PGUSER from the environment (the harness
# sets them). Exercises the high-frequency fsync subsystems mapped in Exp D:
# pg_wal/* (commit path), pg_xact/* (CLOG), global/pg_control (checkpoint),
# pg_logical/replorigin_checkpoint (atomic rename).
#
# Total runtime ~30-60s on a small VM. Meant to be replaced for a real
# campaign; keep it small so CI stays quick.

set -euo pipefail

: "${PGHOST:?PGHOST must be set by harness}"
: "${PGPORT:?PGPORT must be set by harness}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"

PG_BIN="${CRASH_HARNESS_PG_BIN:-/usr/lib/postgresql/16/bin}"
MOUNT="${CRASH_HARNESS_MOUNT:-/mnt/crash-harness}"
TARGET="${CRASH_HARNESS_TARGET:-crash-harness}"

PSQL=("${PG_BIN}/psql" -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" \
      -v ON_ERROR_STOP=1 -X -At)
PGBENCH=("${PG_BIN}/pgbench" -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}")

# Utility: emit a named mark into the dm-log-writes log. The harness sprinkles
# its own marks at phase boundaries; these are the workload's own fine-grained
# marks. Failures are non-fatal (e.g. dmsetup missing during a dry run).
mark() {
    if command -v dmsetup >/dev/null 2>&1; then
        dmsetup message "${TARGET}" 0 mark "workload:$1" 2>/dev/null || true
    fi
    # Mirror to sidecar so `replay all` can iterate even if replay-log can't
    # enumerate marks.
    if [ -n "${CRASH_HARNESS_LOG:-}" ]; then
        printf 'workload:%s\n' "$1" >> "${CRASH_HARNESS_LOG}.marks" 2>/dev/null || true
    fi
}

# Record committed xids so the committed_xact_visibility oracle has something
# to check.
COMMITTED_LOG="${MOUNT}/workload_committed_xids.log"
: > "${COMMITTED_LOG}" || true

log_xid() {
    "${PSQL[@]}" -d "${PGDATABASE}" -c "SELECT txid_current()::text" >> "${COMMITTED_LOG}" || true
}

# -----------------------------------------------------------------------------
# Phase 1: pgbench init (heavy DDL + bulk load → exercises catalog rename path,
# relation file creation, CLOG pages).
# -----------------------------------------------------------------------------
mark "pgbench-init-start"
"${PGBENCH[@]}" -i -s 2 -d "${PGDATABASE}" -q
mark "pgbench-init-end"

# Force a checkpoint so we have a known quiesced state in the log.
"${PSQL[@]}" -d "${PGDATABASE}" -c "CHECKPOINT"
mark "checkpoint-after-init"

# -----------------------------------------------------------------------------
# Phase 2: concurrent OLTP — group commit, WAL heavy.
# -----------------------------------------------------------------------------
mark "pgbench-tpcb-start"
"${PGBENCH[@]}" -c 2 -j 2 -T 15 -N -d "${PGDATABASE}" -q || true
mark "pgbench-tpcb-end"

# -----------------------------------------------------------------------------
# Phase 3: DDL churn — CREATE/DROP TABLE + VACUUM + WAL switches.
# Hits per-checkpoint replorigin rename + pg_filenode.map updates.
# -----------------------------------------------------------------------------
for i in 1 2 3; do
    mark "ddl-churn-$i"
    "${PSQL[@]}" -d "${PGDATABASE}" <<SQL
CREATE TABLE churn_$i (id serial PRIMARY KEY, v text);
INSERT INTO churn_$i(v) SELECT md5(g::text) FROM generate_series(1, 5000) g;
CREATE INDEX churn_${i}_v_idx ON churn_$i(v);
VACUUM (ANALYZE) churn_$i;
SQL
    log_xid
done

mark "drop-churn"
for i in 1 2 3; do
    "${PSQL[@]}" -d "${PGDATABASE}" -c "DROP TABLE churn_$i"
done

# -----------------------------------------------------------------------------
# Phase 4: WAL segment rotation (exercises xlogtemp rename + dir fsync).
# -----------------------------------------------------------------------------
for i in 1 2 3; do
    mark "switch-wal-$i"
    "${PSQL[@]}" -d "${PGDATABASE}" -c "SELECT pg_switch_wal()" > /dev/null
done

# -----------------------------------------------------------------------------
# Phase 5: CREATE DATABASE / DROP DATABASE — hits template copy + fsync on
# base/<dboid>/ directory.
# -----------------------------------------------------------------------------
mark "createdb"
"${PSQL[@]}" -d "${PGDATABASE}" -c "CREATE DATABASE scratch TEMPLATE template0"
"${PSQL[@]}" -d scratch -c "CREATE TABLE scratch_t(id int); INSERT INTO scratch_t SELECT generate_series(1, 100)"
log_xid
mark "dropdb"
"${PSQL[@]}" -d "${PGDATABASE}" -c "DROP DATABASE scratch"

# Final checkpoint so pg_control lands.
mark "final-checkpoint"
"${PSQL[@]}" -d "${PGDATABASE}" -c "CHECKPOINT"

mark "workload-done"
