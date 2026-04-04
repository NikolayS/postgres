#!/usr/bin/env python3
"""
PostgreSQL Binary Protocol Fuzzer

Sends crafted binary data to an ASAN-instrumented PostgreSQL server
to find memory safety bugs in _recv functions, COPY BINARY parsing,
and protocol handling.

Targets:
  - Binary receive functions (numeric_recv, array_recv, record_recv, etc.)
  - COPY BINARY header and tuple parsing
  - Binary-format parameterized queries

Usage:
  python3 fuzz_binary_recv.py [--port 15433] [--host /tmp] [--db fuzzdb]
                              [--iterations 10000] [--timeout 5]
"""

import argparse
import os
import random
import struct
import subprocess
import sys
import time
import glob
import signal

# Connection parameters
PSQL_ENV = {}


def get_libpq_conninfo(host, port, db):
    return f"host={host} port={port} dbname={db}"


def run_sql(host, port, db, sql, timeout=5):
    """Run SQL via psql, return (success, stdout, stderr)"""
    PG = "/tmp/pg-fuzz-inst/usr/local/pgsql"
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = f"{PG}/lib/x86_64-linux-gnu"
    env["ASAN_OPTIONS"] = "detect_leaks=0:detect_stack_use_after_return=0"
    try:
        r = subprocess.run(
            [f"{PG}/bin/psql", "-p", str(port), "-h", host, "-d", db,
             "-t", "-A", "-c", sql],
            capture_output=True, text=True, timeout=timeout, env=env
        )
        return r.returncode == 0, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return False, "", "TIMEOUT"
    except Exception as e:
        return False, "", str(e)


def check_asan_logs():
    """Check for new ASAN crash logs"""
    logs = glob.glob("/tmp/pg-fuzz-asan.*")
    crashes = []
    for log in logs:
        try:
            with open(log) as f:
                content = f.read()
            if content.strip():
                crashes.append((log, content))
        except:
            pass
    return crashes


def clear_asan_logs():
    for f in glob.glob("/tmp/pg-fuzz-asan.*"):
        try:
            os.remove(f)
        except:
            pass


# ============================================================
# Mutation strategies
# ============================================================

def random_bytes(n):
    return bytes(random.getrandbits(8) for _ in range(n))


def mutate_buffer(buf):
    """Apply random mutations to a byte buffer"""
    buf = bytearray(buf)
    if not buf:
        return bytes(buf)

    strategy = random.choice([
        "bitflip", "byteflip", "insert", "delete", "overwrite",
        "interesting_int", "extend", "truncate", "duplicate"
    ])

    if strategy == "bitflip":
        pos = random.randint(0, len(buf) - 1)
        bit = random.randint(0, 7)
        buf[pos] ^= (1 << bit)

    elif strategy == "byteflip":
        pos = random.randint(0, len(buf) - 1)
        buf[pos] = random.randint(0, 255)

    elif strategy == "insert":
        pos = random.randint(0, len(buf))
        buf[pos:pos] = random_bytes(random.randint(1, 16))

    elif strategy == "delete" and len(buf) > 1:
        pos = random.randint(0, len(buf) - 1)
        n = min(random.randint(1, 8), len(buf) - pos)
        del buf[pos:pos+n]

    elif strategy == "overwrite":
        pos = random.randint(0, len(buf) - 1)
        n = min(random.randint(1, 8), len(buf) - pos)
        buf[pos:pos+n] = random_bytes(n)

    elif strategy == "interesting_int":
        # Write interesting integer values at random positions
        interesting = [0, 1, -1, 0x7f, 0x80, 0xff, 0x7fff, 0x8000, 0xffff,
                       0x7fffffff, 0x80000000, 0xffffffff, 0x7fffffffffffffff]
        val = random.choice(interesting)
        width = random.choice([1, 2, 4, 8])
        pos = random.randint(0, max(0, len(buf) - width))
        try:
            if width == 1:
                buf[pos] = val & 0xff
            elif width == 2:
                struct.pack_into(">h", buf, pos, val & 0xffff if val >= 0 else val)
            elif width == 4:
                struct.pack_into(">i", buf, pos, val & 0xffffffff if val >= 0 else val)
        except (struct.error, IndexError):
            pass

    elif strategy == "extend":
        buf.extend(random_bytes(random.randint(1, 64)))

    elif strategy == "truncate" and len(buf) > 1:
        buf = buf[:random.randint(1, len(buf) - 1)]

    elif strategy == "duplicate":
        pos = random.randint(0, len(buf) - 1)
        n = min(random.randint(1, 16), len(buf) - pos)
        chunk = bytes(buf[pos:pos+n])
        ipos = random.randint(0, len(buf))
        buf[ipos:ipos] = chunk

    return bytes(buf)


# ============================================================
# Seed generators for different target types
# ============================================================

def make_binary_int4(val):
    """Binary format for int4"""
    return struct.pack(">i", val)


def make_binary_text(s):
    """Binary format for text"""
    return s.encode("utf-8")


def make_binary_numeric(ndigits=4, weight=1, sign=0, dscale=0, digits=None):
    """Binary format for numeric: header + digits (each digit is int16, 0-9999)"""
    if digits is None:
        digits = [random.randint(0, 9999) for _ in range(ndigits)]
    buf = struct.pack(">hhhh", ndigits, weight, sign, dscale)
    for d in digits:
        buf += struct.pack(">H", d)
    return buf


def make_binary_array(element_type_oid, ndim, dims, elements):
    """Binary format for array"""
    buf = struct.pack(">i", ndim)  # ndim
    buf += struct.pack(">i", 0)    # flags (has nulls?)
    buf += struct.pack(">i", element_type_oid)  # element type OID
    for i in range(ndim):
        buf += struct.pack(">i", dims[i])  # dimension size
        buf += struct.pack(">i", 1)         # lower bound
    for elem in elements:
        if elem is None:
            buf += struct.pack(">i", -1)  # NULL
        else:
            buf += struct.pack(">i", len(elem)) + elem
    return buf


def make_copy_binary_header(ext_len=0, ext_data=b''):
    """COPY BINARY file header"""
    header = b'PGCOPY\n\xff\r\n\x00'  # 11-byte signature
    header += struct.pack(">I", 0)      # flags
    header += struct.pack(">i", ext_len) # extension length
    header += ext_data[:ext_len]
    return header


def make_copy_binary_tuple(field_data_list):
    """One tuple in COPY BINARY format"""
    buf = struct.pack(">h", len(field_data_list))  # field count
    for data in field_data_list:
        if data is None:
            buf += struct.pack(">i", -1)  # NULL
        else:
            buf += struct.pack(">i", len(data)) + data
    return buf


def make_copy_binary_trailer():
    return struct.pack(">h", -1)  # EOF marker


# ============================================================
# Fuzz targets
# ============================================================

def fuzz_copy_binary_numeric(host, port, db):
    """Fuzz numeric_recv via COPY BINARY"""
    # Create table if not exists
    run_sql(host, port, db, "CREATE TABLE IF NOT EXISTS fuzz_numeric (v numeric)")

    # Generate valid seed then mutate
    seed = make_binary_numeric(ndigits=3, weight=2, sign=0, dscale=4,
                               digits=[1234, 5678, 9000])
    data = mutate_buffer(seed)

    header = make_copy_binary_header()
    tup = make_copy_binary_tuple([data])
    trailer = make_copy_binary_trailer()
    payload = header + tup + trailer

    return _send_copy_binary(host, port, db, "fuzz_numeric", payload)


def fuzz_copy_binary_array(host, port, db):
    """Fuzz array_recv via COPY BINARY"""
    run_sql(host, port, db, "CREATE TABLE IF NOT EXISTS fuzz_array (v int[])")

    # Valid int4 array seed: 1-dim, 3 elements
    elems = [make_binary_int4(i) for i in [1, 2, 3]]
    seed = make_binary_array(23, 1, [3], elems)  # OID 23 = int4
    data = mutate_buffer(seed)

    header = make_copy_binary_header()
    tup = make_copy_binary_tuple([data])
    trailer = make_copy_binary_trailer()
    payload = header + tup + trailer

    return _send_copy_binary(host, port, db, "fuzz_array", payload)


def fuzz_copy_binary_nested_array(host, port, db):
    """Fuzz deeply nested array (array of array of int)"""
    run_sql(host, port, db, "CREATE TABLE IF NOT EXISTS fuzz_nested (v int[][])")

    # 2-D array seed
    seed = make_binary_array(23, 2, [2, 3],
                             [make_binary_int4(i) for i in range(6)])
    data = mutate_buffer(seed)

    header = make_copy_binary_header()
    tup = make_copy_binary_tuple([data])
    trailer = make_copy_binary_trailer()
    payload = header + tup + trailer

    return _send_copy_binary(host, port, db, "fuzz_nested", payload)


def fuzz_copy_binary_text(host, port, db):
    """Fuzz text_recv with various encodings"""
    run_sql(host, port, db, "CREATE TABLE IF NOT EXISTS fuzz_text (v text)")

    # Seed with random bytes (invalid UTF-8)
    data = random_bytes(random.randint(0, 256))

    header = make_copy_binary_header()
    tup = make_copy_binary_tuple([data])
    trailer = make_copy_binary_trailer()
    payload = header + tup + trailer

    return _send_copy_binary(host, port, db, "fuzz_text", payload)


def fuzz_copy_binary_jsonb(host, port, db):
    """Fuzz jsonb_recv via COPY BINARY"""
    run_sql(host, port, db, "CREATE TABLE IF NOT EXISTS fuzz_jsonb (v jsonb)")

    # jsonb binary format: version byte (1) + JSON string
    seeds = [
        b'\x01{"a":1}',
        b'\x01[1,2,3]',
        b'\x01' + b'{"x":' * 50 + b'1' + b'}' * 50,
        b'\x01"hello"',
        b'\x01null',
    ]
    seed = random.choice(seeds)
    data = mutate_buffer(seed)

    header = make_copy_binary_header()
    tup = make_copy_binary_tuple([data])
    trailer = make_copy_binary_trailer()
    payload = header + tup + trailer

    return _send_copy_binary(host, port, db, "fuzz_jsonb", payload)


def fuzz_copy_binary_record(host, port, db):
    """Fuzz record_recv via COPY BINARY on a composite type"""
    run_sql(host, port, db, """
        DO $$ BEGIN
            CREATE TYPE fuzz_rec AS (a int, b text, c numeric);
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $$;
        CREATE TABLE IF NOT EXISTS fuzz_record (v fuzz_rec)
    """)

    # Record binary format: nfields, then for each: oid + len + data
    nfields = random.randint(0, 10)
    buf = struct.pack(">i", nfields)
    for _ in range(nfields):
        oid = random.choice([23, 25, 1700, 0, 0xffffffff & random.getrandbits(32)])
        field_data = random_bytes(random.randint(0, 32))
        buf += struct.pack(">i", oid)
        if random.random() < 0.2:
            buf += struct.pack(">i", -1)  # NULL
        else:
            buf += struct.pack(">i", len(field_data)) + field_data
    data = mutate_buffer(buf)

    header = make_copy_binary_header()
    tup = make_copy_binary_tuple([data])
    trailer = make_copy_binary_trailer()
    payload = header + tup + trailer

    return _send_copy_binary(host, port, db, "fuzz_record", payload)


def fuzz_copy_binary_range(host, port, db):
    """Fuzz range_recv via COPY BINARY"""
    run_sql(host, port, db, "CREATE TABLE IF NOT EXISTS fuzz_range (v int4range)")

    # Range binary format: flags byte, then optional lower and upper bounds
    flags = random.randint(0, 255)
    buf = struct.pack("B", flags)
    # Add lower bound
    if not (flags & 0x08):  # RANGE_LB_INF
        lb = make_binary_int4(random.randint(-2**31, 2**31 - 1))
        buf += struct.pack(">i", len(lb)) + lb
    # Add upper bound
    if not (flags & 0x10):  # RANGE_UB_INF
        ub = make_binary_int4(random.randint(-2**31, 2**31 - 1))
        buf += struct.pack(">i", len(ub)) + ub
    data = mutate_buffer(buf)

    header = make_copy_binary_header()
    tup = make_copy_binary_tuple([data])
    trailer = make_copy_binary_trailer()
    payload = header + tup + trailer

    return _send_copy_binary(host, port, db, "fuzz_range", payload)


def fuzz_copy_header(host, port, db):
    """Fuzz the COPY BINARY header itself"""
    run_sql(host, port, db, "CREATE TABLE IF NOT EXISTS fuzz_header (v int)")

    # Mutate the header
    ext_len = random.choice([0, 1, 100, 0x7fffffff, -1, 0xffff])
    ext_data = random_bytes(min(abs(ext_len) if ext_len > 0 else 0, 256))

    sig = b'PGCOPY\n\xff\r\n\x00'
    flags = struct.pack(">I", random.choice([0, 1, 0xffffffff, 0x80000000]))

    if random.random() < 0.3:
        sig = mutate_buffer(sig)

    header = sig + flags + struct.pack(">i", min(ext_len, len(ext_data))) + ext_data

    # Simple tuple
    tup = make_copy_binary_tuple([make_binary_int4(42)])
    trailer = make_copy_binary_trailer()

    payload = header + tup + trailer
    return _send_copy_binary(host, port, db, "fuzz_header", payload)


def fuzz_copy_binary_multi_field(host, port, db):
    """Fuzz COPY BINARY with wrong field count / mixed types"""
    run_sql(host, port, db, "CREATE TABLE IF NOT EXISTS fuzz_multi (a int, b text, c numeric, d bytea)")

    nfields = random.randint(0, 20)  # may be wrong count
    fields = []
    for _ in range(nfields):
        if random.random() < 0.15:
            fields.append(None)  # NULL
        else:
            fields.append(random_bytes(random.randint(0, 128)))

    header = make_copy_binary_header()
    tup = make_copy_binary_tuple(fields)
    trailer = make_copy_binary_trailer()
    payload = header + tup + trailer

    return _send_copy_binary(host, port, db, "fuzz_multi", payload)


def _send_copy_binary(host, port, db, table, payload):
    """Send binary COPY data to PostgreSQL via psql pipe"""
    PG = "/tmp/pg-fuzz-inst/usr/local/pgsql"
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = f"{PG}/lib/x86_64-linux-gnu"
    env["ASAN_OPTIONS"] = "detect_leaks=0:detect_stack_use_after_return=0"

    try:
        proc = subprocess.Popen(
            [f"{PG}/bin/psql", "-p", str(port), "-h", host, "-d", db,
             "-c", f"COPY {table} FROM STDIN WITH (FORMAT binary)"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env
        )
        out, err = proc.communicate(input=payload, timeout=5)
        return proc.returncode == 0, err.decode(errors='replace')
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        return False, "TIMEOUT"
    except Exception as e:
        return False, str(e)


# ============================================================
# Main fuzzer loop
# ============================================================

TARGETS = [
    ("numeric_recv", fuzz_copy_binary_numeric),
    ("array_recv", fuzz_copy_binary_array),
    ("nested_array", fuzz_copy_binary_nested_array),
    ("text_recv", fuzz_copy_binary_text),
    ("jsonb_recv", fuzz_copy_binary_jsonb),
    ("record_recv", fuzz_copy_binary_record),
    ("range_recv", fuzz_copy_binary_range),
    ("copy_header", fuzz_copy_header),
    ("multi_field", fuzz_copy_binary_multi_field),
]


def main():
    parser = argparse.ArgumentParser(description="PostgreSQL Binary Protocol Fuzzer")
    parser.add_argument("--port", type=int, default=15433)
    parser.add_argument("--host", default="/tmp")
    parser.add_argument("--db", default="fuzzdb")
    parser.add_argument("--iterations", type=int, default=10000)
    parser.add_argument("--timeout", type=int, default=5)
    args = parser.parse_args()

    print(f"PostgreSQL Binary Protocol Fuzzer")
    print(f"Server: {args.host}:{args.port}/{args.db}")
    print(f"Iterations: {args.iterations}")
    print(f"Targets: {', '.join(t[0] for t in TARGETS)}")
    print(f"ASAN log prefix: /tmp/pg-fuzz-asan.*")
    print()

    # Clear old ASAN logs
    clear_asan_logs()

    # Verify server is running
    ok, out, err = run_sql(args.host, args.port, args.db, "SELECT 1")
    if not ok:
        print(f"ERROR: Cannot connect to server: {err}")
        sys.exit(1)
    print("Server connection OK")

    crashes = []
    errors_by_target = {t[0]: 0 for t in TARGETS}
    total_by_target = {t[0]: 0 for t in TARGETS}
    start_time = time.time()

    for i in range(1, args.iterations + 1):
        target_name, target_fn = random.choice(TARGETS)
        total_by_target[target_name] += 1

        try:
            ok, errmsg = target_fn(args.host, args.port, args.db)
            if not ok:
                errors_by_target[target_name] += 1
        except Exception as e:
            errors_by_target[target_name] += 1
            errmsg = str(e)

        # Check for ASAN crashes periodically
        if i % 100 == 0:
            new_crashes = check_asan_logs()
            if new_crashes:
                for log_file, content in new_crashes:
                    crash_info = {
                        "iteration": i,
                        "target": target_name,
                        "log_file": log_file,
                        "summary": content[:500]
                    }
                    crashes.append(crash_info)
                    print(f"\n{'='*60}")
                    print(f"*** ASAN CRASH DETECTED at iteration {i} ***")
                    print(f"Target: {target_name}")
                    print(f"Log: {log_file}")
                    print(content[:1000])
                    print(f"{'='*60}\n")

            # Check server is still alive
            ok, _, err = run_sql(args.host, args.port, args.db, "SELECT 1")
            if not ok:
                print(f"\n*** SERVER CRASHED at iteration {i}! ***")
                print(f"Last target: {target_name}")
                # Check ASAN logs one more time
                final_crashes = check_asan_logs()
                for log_file, content in final_crashes:
                    crashes.append({
                        "iteration": i,
                        "target": target_name,
                        "log_file": log_file,
                        "summary": content[:500]
                    })
                    print(content[:2000])
                break

            elapsed = time.time() - start_time
            rate = i / elapsed if elapsed > 0 else 0
            print(f"[{i}/{args.iterations}] {rate:.0f} iter/s | "
                  f"crashes: {len(crashes)} | "
                  f"target: {target_name}", end="\r")

    elapsed = time.time() - start_time
    print(f"\n\nFuzzing complete: {args.iterations} iterations in {elapsed:.1f}s "
          f"({args.iterations/elapsed:.0f} iter/s)")
    print(f"\nTarget statistics:")
    for name, fn in TARGETS:
        total = total_by_target[name]
        errs = errors_by_target[name]
        print(f"  {name:20s}: {total:5d} runs, {errs:5d} errors ({100*errs/max(total,1):.0f}%)")

    print(f"\nASAN crashes found: {len(crashes)}")
    if crashes:
        print("\nCrash details:")
        for c in crashes:
            print(f"  Iteration {c['iteration']}, target={c['target']}")
            print(f"  Log: {c['log_file']}")
            print(f"  {c['summary'][:200]}")
            print()

    # Write crash summary
    with open("/tmp/fuzz_results.txt", "w") as f:
        f.write(f"PostgreSQL Binary Protocol Fuzzer Results\n")
        f.write(f"Date: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"Iterations: {args.iterations}\n")
        f.write(f"Duration: {elapsed:.1f}s\n")
        f.write(f"ASAN crashes: {len(crashes)}\n\n")
        for c in crashes:
            f.write(f"--- Crash at iteration {c['iteration']} ---\n")
            f.write(f"Target: {c['target']}\n")
            f.write(f"Log: {c['log_file']}\n")
            f.write(c['summary'] + "\n\n")

    return len(crashes)


if __name__ == "__main__":
    sys.exit(0 if main() == 0 else 1)
