#!/bin/bash
#
# Experiment: Does a long-running transaction block VACUUM from
# removing dead tuples via the xmin horizon?
#
# Tests:
#   A) VACUUM with no blocking transaction (baseline)
#   B) BEGIN (READ COMMITTED) + txid_current() — blocks vacuum
#   C) BEGIN ISOLATION LEVEL REPEATABLE READ + txid_current() — blocks vacuum
#   D) Bare BEGIN with no queries — does NOT block vacuum
#
# Conclusion:
#   A bare BEGIN; without any subsequent statement does NOT block vacuum.
#   PostgreSQL uses lazy snapshot/XID acquisition. Only once a transaction
#   acquires an XID (via write or txid_current()) or a snapshot (via read
#   or REPEATABLE READ+) does it hold back the xmin horizon.
#
# Usage: sudo -u postgres bash test_xmin_vacuum_blocking.sh
#   (or adjust PSQL below to match your setup)

set -euo pipefail

PSQL="psql -X -d postgres"

cleanup() {
    # Kill any leftover background processes
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
    rm -f /tmp/pg_fifo_xmin_* 2>/dev/null || true
    $PSQL -c "DROP TABLE IF EXISTS test_xmin;" 2>/dev/null || true
}
trap cleanup EXIT

terminate_others() {
    $PSQL -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname = current_database();" > /dev/null
    sleep 1
}

setup_table() {
    $PSQL -c "DROP TABLE IF EXISTS test_xmin;"
    $PSQL -c "CREATE TABLE test_xmin(id int);"
    $PSQL -c "INSERT INTO test_xmin SELECT generate_series(1, 10000);"
    $PSQL -c "VACUUM ANALYZE test_xmin;"
}

show_dead_tuples() {
    $PSQL -c "SELECT n_dead_tup, n_live_tup FROM pg_stat_user_tables WHERE relname = 'test_xmin';"
}

# ============================================================
echo "=========================================="
echo "TEST A: VACUUM without a blocking transaction (baseline)"
echo "=========================================="
terminate_others
setup_table

$PSQL -c "DELETE FROM test_xmin;"
echo "--- Dead tuples after DELETE ---"
show_dead_tuples

echo "--- VACUUM VERBOSE ---"
$PSQL -c "VACUUM VERBOSE test_xmin;" 2>&1

echo "--- After VACUUM ---"
show_dead_tuples
# Expected: 0 dead tuples, all removed

# ============================================================
echo ""
echo "=========================================="
echo "TEST B: BEGIN (READ COMMITTED) + txid_current() blocks vacuum"
echo "=========================================="
terminate_others
setup_table

FIFO_B=/tmp/pg_fifo_xmin_b_$$
mkfifo "$FIFO_B"
tail -f "$FIFO_B" | $PSQL &
sleep 1

echo "BEGIN;" > "$FIFO_B"
echo "SELECT txid_current();" > "$FIFO_B"
sleep 2

echo "--- Blocker session info ---"
$PSQL -c "SELECT pid, state, backend_xmin, backend_xid FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname = current_database();"

$PSQL -c "DELETE FROM test_xmin;"
echo "--- Dead tuples after DELETE ---"
show_dead_tuples

echo "--- VACUUM VERBOSE (should NOT remove dead tuples) ---"
$PSQL -c "VACUUM VERBOSE test_xmin;" 2>&1

echo "--- Dead tuples after VACUUM (should still be 10000) ---"
show_dead_tuples

echo "COMMIT;" > "$FIFO_B"
sleep 1
echo "\q" > "$FIFO_B"
sleep 1
jobs -p | xargs -r kill 2>/dev/null || true
wait 2>/dev/null || true
rm -f "$FIFO_B"

echo "--- VACUUM after COMMIT (should now clean up) ---"
$PSQL -c "VACUUM VERBOSE test_xmin;" 2>&1
show_dead_tuples
# Expected: 0 dead tuples after second vacuum

# ============================================================
echo ""
echo "=========================================="
echo "TEST C: REPEATABLE READ + txid_current() blocks vacuum"
echo "=========================================="
terminate_others
setup_table

FIFO_C=/tmp/pg_fifo_xmin_c_$$
mkfifo "$FIFO_C"
tail -f "$FIFO_C" | $PSQL &
sleep 1

echo "BEGIN ISOLATION LEVEL REPEATABLE READ;" > "$FIFO_C"
echo "SELECT txid_current();" > "$FIFO_C"
sleep 2

echo "--- Blocker session info ---"
$PSQL -c "SELECT pid, state, backend_xmin, backend_xid FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname = current_database();"

$PSQL -c "DELETE FROM test_xmin;"
echo "--- Dead tuples after DELETE ---"
show_dead_tuples

echo "--- VACUUM VERBOSE (should NOT remove dead tuples) ---"
$PSQL -c "VACUUM VERBOSE test_xmin;" 2>&1

echo "--- Dead tuples after VACUUM (should still be 10000) ---"
show_dead_tuples

echo "COMMIT;" > "$FIFO_C"
sleep 1
echo "\q" > "$FIFO_C"
sleep 1
jobs -p | xargs -r kill 2>/dev/null || true
wait 2>/dev/null || true
rm -f "$FIFO_C"

echo "--- VACUUM after COMMIT (should now clean up) ---"
$PSQL -c "VACUUM VERBOSE test_xmin;" 2>&1
show_dead_tuples
# Expected: 0 dead tuples

# ============================================================
echo ""
echo "=========================================="
echo "TEST D: Bare BEGIN with NO queries — does NOT block vacuum"
echo "=========================================="
terminate_others
setup_table

FIFO_D=/tmp/pg_fifo_xmin_d_$$
mkfifo "$FIFO_D"
tail -f "$FIFO_D" | $PSQL &
sleep 1

# ONLY send BEGIN, nothing else
echo "BEGIN;" > "$FIFO_D"
sleep 2

echo "--- Blocker session info (should show NULL xmin and xid) ---"
$PSQL -c "SELECT pid, state, backend_xmin, backend_xid FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname = current_database();"

$PSQL -c "DELETE FROM test_xmin;"
echo "--- Dead tuples after DELETE ---"
show_dead_tuples

echo "--- VACUUM VERBOSE (SHOULD remove dead tuples despite open BEGIN) ---"
$PSQL -c "VACUUM VERBOSE test_xmin;" 2>&1

echo "--- Dead tuples after VACUUM (should be 0!) ---"
show_dead_tuples

echo "COMMIT;" > "$FIFO_D"
sleep 1
echo "\q" > "$FIFO_D"
sleep 1
jobs -p | xargs -r kill 2>/dev/null || true
wait 2>/dev/null || true
rm -f "$FIFO_D"

# ============================================================
echo ""
echo "=========================================="
echo "ALL TESTS COMPLETE"
echo "=========================================="
echo ""
echo "Summary:"
echo "  Test A: Baseline — VACUUM cleans dead tuples with no blockers"
echo "  Test B: READ COMMITTED + txid_current() — BLOCKS vacuum (backend_xid set)"
echo "  Test C: REPEATABLE READ + txid_current() — BLOCKS vacuum (backend_xmin + xid set)"
echo "  Test D: Bare BEGIN — does NOT block vacuum (no xmin, no xid)"
echo ""
echo "Key insight: BEGIN alone does NOT acquire a snapshot or XID."
echo "PostgreSQL uses lazy acquisition — only actual operations trigger it."
