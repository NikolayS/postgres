# PostgreSQL Binary Protocol Fuzzer

Sends crafted binary data to an ASAN-instrumented PostgreSQL server to find
memory safety bugs in `_recv` functions, COPY BINARY parsing, and protocol handling.

## Architecture

```
  fuzzer (Python)  --(COPY BINARY stdin)-->  PostgreSQL (clang + ASAN)
       |                                           |
       |  mutated binary payloads                  |  _recv functions
       |  for numeric, array, record,              |  validate and reject
       |  jsonb, range, text types                 |  malformed input
       |                                           |
       +-- checks /tmp/pg-fuzz-asan.* logs         +-- ASAN writes crash logs
```

## Setup

### 1. Build PostgreSQL with ASAN

```bash
# Need clang-18 + libclang-rt-18-dev
apt-get install -y clang-18 libclang-rt-18-dev

# Clean source tree (if configure was run before)
make distclean 2>/dev/null; git checkout -- .

# Build with meson + ASAN
CC=clang-18 CXX=clang++-18 meson setup /tmp/pg-fuzz-build \
  -Dcassert=true -Ddebug=true -Doptimization=0 \
  -Db_sanitize=address -Db_lundef=false \
  -Dreadline=disabled -Dzlib=disabled -Dicu=disabled -Dlibxml=disabled

cd /tmp/pg-fuzz-build && ninja -j$(nproc)
DESTDIR=/tmp/pg-fuzz-inst ninja install
```

### 2. Init and start ASAN server

```bash
PG=/tmp/pg-fuzz-inst/usr/local/pgsql

# IMPORTANT: detect_stack_use_after_return=0 is needed to avoid
# triggering PostgreSQL's stack depth check under ASAN
sudo -u pgtest bash -c "
  ASAN_OPTIONS=detect_leaks=0:detect_stack_use_after_return=0 \
  LD_LIBRARY_PATH=$PG/lib/x86_64-linux-gnu \
  $PG/bin/initdb -D /tmp/pg-fuzz-data"

sudo -u pgtest bash -c "
  ASAN_OPTIONS=detect_leaks=0:detect_stack_use_after_return=0:halt_on_error=0:log_path=/tmp/pg-fuzz-asan \
  LD_LIBRARY_PATH=$PG/lib/x86_64-linux-gnu \
  $PG/bin/pg_ctl start -D /tmp/pg-fuzz-data -o '-p 15433 -k /tmp' -l /tmp/pg-fuzz.log"

sudo -u pgtest bash -c "
  LD_LIBRARY_PATH=$PG/lib/x86_64-linux-gnu \
  $PG/bin/createdb -p 15433 -h /tmp fuzzdb"
```

### 3. Run the fuzzer

```bash
sudo -u pgtest python3 tests/security/fuzz/fuzz_binary_recv.py \
  --iterations 20000 --port 15433 --host /tmp --db fuzzdb
```

## Targets

| Target | _recv function | Description |
|--------|---------------|-------------|
| numeric_recv | `numeric_recv()` | Mutated numeric binary headers (ndigits, weight, sign, dscale) |
| array_recv | `array_recv()` | 1-D int4 arrays with corrupted dimensions/elements |
| nested_array | `array_recv()` | Multi-dimensional arrays |
| text_recv | `text_recv()` | Random bytes (invalid UTF-8) |
| jsonb_recv | `jsonb_recv()` | Mutated JSONB binary format (version + JSON string) |
| record_recv | `record_recv()` | Composite types with random field OIDs and data |
| range_recv | `range_recv()` | int4range with mutated flags and bounds |
| copy_header | N/A | Mutated COPY BINARY header (signature, flags, extension) |
| multi_field | multiple | Wrong field count, mixed type data |

## Results (2026-04-04)

- **20,000 iterations** across 9 targets
- **0 ASAN crashes**
- **0 server crashes**
- ~15,000 ERROR-level rejections (expected -- malformed data is properly validated)
- All malformed input properly rejected with descriptive ERROR messages

This confirms the audit finding that PostgreSQL's binary receive functions
are systematically well-validated. The `pq_getmsgint()` / `pq_getmsgbyte()` /
`pq_getmsgend()` infrastructure provides reliable bounds checking.

**Conclusion:** The binary protocol input path is hardened against memory
corruption. Finding bugs here would require either:
1. Coverage-guided fuzzing (libFuzzer) with a standalone harness for much
   higher throughput (~millions of iterations)
2. Targeting specific code paths with structure-aware mutations
3. Fuzzing logical replication protocol which has weaker validation (X-1 finding)
