# PostgreSQL Core Optimizations for Queue Workloads

Experiments to improve PostgreSQL throughput for append-heavy queue workloads
(PgQ, pgq2, and similar systems).

## Context

Profiling PgQ `insert_event()` on PG 18.3 (Apple Silicon, 10 cores, 24GB)
showed these bottlenecks for single-insert-per-TX workloads at ~148k ev/s:

| Wait event | % of time | Root cause |
|-----------|-----------|------------|
| IO:DataFileWrite | 57% (sustained) | Single-threaded synchronous checkpoint writes |
| LWLock:BufferContent | 23% | All inserters contend on same 8KB page |
| Lock:extend | 11% | Relation extension lock serializes all extenders |
| LWLock:ProcArray | 4% | O(numProcs) snapshot scan |
| LWLock:XidGen | 4% | Serial transaction ID generation |

## Ideas (ordered by confidence, highest first)

### Idea 4: wal_compression = zstd:1 (confidence 9/10)
- **Status:** TODO
- **Type:** Config-only, no code change
- **What:** Test `zstd:1` instead of `lz4` for FPW compression. zstd at level 1
  has similar CPU cost to lz4 but better compression ratio.
- **Why:** FPW write amplification is 3-4x. Better compression directly reduces
  WAL volume and checkpoint I/O.
- **Risk:** Near zero. Just a GUC setting.

### Idea 3: Raise NUM_XLOGINSERT_LOCKS (confidence 8/10)
- **Status:** TODO
- **File:** `src/backend/access/transam/xlog.c:154`
- **What:** Change `#define NUM_XLOGINSERT_LOCKS 8` to 16 or 32.
- **Why:** 8 WAL insert locks is a serialization bottleneck with 10+ concurrent
  inserters. Each INSERT must acquire one of these locks to copy its WAL record
  into the WAL buffer. More locks = less contention.
- **Risk:** Low. More locks = slightly more memory. Well-understood tradeoff,
  similar to how NUM_BUFFER_PARTITIONS was raised over the years.
- **Benchmark:** Compare 8 vs 16 vs 32 at 8 and 16 clients.

### Idea 2: BulkInsertState for SPI inserts (confidence 6/10)
- **Status:** TODO
- **File:** `src/backend/executor/spi.c`, `src/backend/access/heap/heapam.c`
- **What:** When SPI executes an INSERT, provide a BulkInsertState so the bulk
  extend adaptive logic kicks in. Currently only COPY gets BulkInsertState.
- **Why:** PgQ's C insert_event_raw uses SPI for the INSERT. Without
  BulkInsertState, each insert may trigger single-page extension instead of
  bulk extend. The adaptive extension (scale by waiter count, remember
  last extend size) is wasted.
- **Risk:** Moderate. Need to manage BulkInsertState lifecycle across SPI calls
  within a transaction. Precedent in COPY code.

### Idea 1: Multiple target blocks (confidence 4/10)
- **Status:** TODO
- **File:** `src/backend/access/heap/hio.c` (RelationGetBufferForTuple)
- **What:** Instead of a single `rd_targblock` that all backends converge on,
  maintain an array of N target blocks. Hash each backend to a different target
  block to spread inserts across N pages.
- **Why:** The "last page contention" problem. All inserters fight for exclusive
  content lock on the same 8KB page. Spreading across N pages reduces
  contention ~Nx.
- **Risk:** Significant. Touches hot code path. Interactions with FSM, VACUUM,
  visibility maps. Could introduce fragmentation. Needs new reloption
  (`insert_target_count`) and careful benchmarking.

### Idea 5: AIO writes in checkpoint path (confidence 2/10)
- **Status:** TODO (wait for community)
- **Files:** `src/backend/postmaster/checkpointer.c`, `src/backend/storage/buffer/bufmgr.c`
- **What:** Make checkpointer use io_uring for writes instead of synchronous
  pwrite(). Prerequisites (buffer lock refactoring, 64-bit atomic BufferDesc)
  are already committed in PG 18.
- **Why:** Single-threaded synchronous writes cannot saturate modern NVMe.
  io_uring could issue dozens of concurrent I/Os.
- **Risk:** Very high. Massive patch, core write path change.

### Idea 7: Delta/incremental FPW (confidence 2/10)
- **Status:** TODO (wait for community)
- **File:** `src/backend/access/transam/xloginsert.c` (XLogRecordAssemble)
- **What:** Write only changed bytes instead of full 8KB page image after
  checkpoint. Would reduce FPW from 8KB to ~2KB for a single-row INSERT.
- **Why:** FPW is the dominant source of write amplification (3-4x).
- **Risk:** Very high. WAL format change, replay logic, backup tools.

### Idea 6: CSN-based snapshots (confidence 1/10)
- **Status:** TODO (wait for community)
- **File:** `src/backend/storage/ipc/procarray.c` (GetSnapshotData)
- **What:** Replace O(numProcs) snapshot scan with O(1) commit sequence number.
- **Risk:** Architectural change to MVCC model. Years of work.

## Benchmark methodology

- PG 18.3, Apple Silicon (10 cores, 24GB), APFS SSD
- PgQ 3.5.1, C mode, `insert_event()` via pgbench
- Base config: `synchronous_commit=off, shared_buffers=2GB, max_wal_size=4GB, wal_level=minimal`
- 30s runs, 8 clients, prepared mode, ~2KB payload
- Baseline: ~148k ev/s (100B), ~86k ev/s (2KB)
