#!/bin/bash
# Script to build PostgreSQL 16.3 and run reproduction tests
set -e

echo "========================================="
echo "PostgreSQL 16.3 Parallel Hang Test Setup"
echo "========================================="
echo ""

# Check if we're in the postgres directory
if [ ! -f "configure" ]; then
    echo "Error: Must be run from PostgreSQL source directory"
    exit 1
fi

# Set paths
TEST_DIR="/tmp/pg16test"
DATA_DIR="$TEST_DIR/data"
LOG_FILE="$TEST_DIR/server.log"
PORT=5433

echo "Test directory: $TEST_DIR"
echo "Data directory: $DATA_DIR"
echo "Port: $PORT"
echo ""

# Cleanup old test environment
if [ -d "$TEST_DIR" ]; then
    echo "Cleaning up old test environment..."
    if [ -f "$DATA_DIR/postmaster.pid" ]; then
        $TEST_DIR/bin/pg_ctl -D "$DATA_DIR" stop -m immediate || true
        sleep 2
    fi
    rm -rf "$TEST_DIR"
fi

# Check PostgreSQL version
echo "Checking PostgreSQL version..."
PG_VERSION=$(grep "PG_VERSION_NUM" src/include/pg_config.h.in | grep -o '[0-9]*' | head -1)
if [ "$PG_VERSION" != "160003" ]; then
    echo "Warning: Expected version 160003 (16.3), found $PG_VERSION"
    echo "Continuing anyway..."
fi
echo ""

# Configure and build
echo "Configuring PostgreSQL..."
./configure --prefix="$TEST_DIR" \
    --enable-debug \
    --enable-cassert \
    CFLAGS="-O0 -g" \
    --quiet

echo "Building PostgreSQL (this may take a few minutes)..."
make -j$(nproc) -s
make install -s

echo "Build complete!"
echo ""

# Initialize cluster
echo "Initializing database cluster..."
$TEST_DIR/bin/initdb -D "$DATA_DIR" --locale=C --encoding=UTF8

# Configure for parallel execution
echo "Configuring for parallel execution..."
cat >> "$DATA_DIR/postgresql.conf" <<EOF

# Configuration for parallel hang reproduction
port = $PORT
max_parallel_workers_per_gather = 4
max_parallel_workers = 8
max_worker_processes = 8
shared_buffers = 1GB
work_mem = 256MB

# Logging
log_min_messages = info
log_min_duration_statement = 1000
log_line_prefix = '%m [%p] %q%u@%d '
log_connections = on
log_disconnections = on
log_lock_waits = on
deadlock_timeout = 5s

# Autovacuum (to match production)
log_autovacuum_min_duration = 0
autovacuum_naptime = 10s
EOF

# Start server
echo "Starting PostgreSQL server..."
$TEST_DIR/bin/pg_ctl -D "$DATA_DIR" -l "$LOG_FILE" start
sleep 2

# Create test database
echo "Creating test database..."
$TEST_DIR/bin/createdb -p $PORT test

echo ""
echo "========================================="
echo "Setup Complete!"
echo "========================================="
echo ""
echo "PostgreSQL is running on port $PORT"
echo "Server log: $LOG_FILE"
echo ""
echo "To run the tests:"
echo ""
echo "Terminal 1 (Monitor):"
echo "  $TEST_DIR/bin/psql -p $PORT test -f monitor_parallel_hang.sql"
echo ""
echo "Terminal 2 (Test):"
echo "  $TEST_DIR/bin/psql -p $PORT test -f test_parallel_queue_saturation.sql"
echo ""
echo "To check for hang:"
echo "  $TEST_DIR/bin/psql -p $PORT test -c \"SELECT pid, wait_event, backend_type, state FROM pg_stat_activity WHERE backend_type IN ('client backend', 'parallel worker');\""
echo ""
echo "To stop server:"
echo "  $TEST_DIR/bin/pg_ctl -D $DATA_DIR stop"
echo ""
echo "Press Enter to run the main test now, or Ctrl+C to exit and run manually..."
read

echo ""
echo "========================================="
echo "Running Main Test"
echo "========================================="
echo ""

# Run the test
$TEST_DIR/bin/psql -p $PORT test -f test_parallel_queue_saturation.sql

echo ""
echo "Test completed. Check output above for results."
echo ""
echo "To view server log:"
echo "  tail -f $LOG_FILE"
