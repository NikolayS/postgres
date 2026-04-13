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
- **Status:** DONE — raised from 8 to 32
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
- **Status:** DESIGN COMPLETE (do not implement without benchmarking simpler ideas first)
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

#### Detailed Design (2026-04-12)

##### Current Architecture

The insertion target block is stored in the SMgrRelation handle:

```
SMgrRelationData (src/include/storage/smgr.h):
    BlockNumber smgr_targblock;   /* single target block */
```

This is accessed through macros in `src/include/utils/rel.h`:

```c
#define RelationGetTargetBlock(relation) \
    ( (relation)->rd_smgr != NULL ? (relation)->rd_smgr->smgr_targblock : InvalidBlockNumber )

#define RelationSetTargetBlock(relation, targblock) \
    do { \
        RelationGetSmgr(relation)->smgr_targblock = (targblock); \
    } while (0)
```

`smgr_targblock` is per-backend (each backend has its own SMgrRelation hash
table), but all backends converge on the same physical block because:
1. When backend A extends the relation and sets its targblock to block X, it
   returns that buffer locked. After inserting and releasing the lock, other
   backends trying the FSM path or "last page" fallback will discover block X
   has room and also set *their* targblock to X.
2. The FSM lookup (`GetPageWithFreeSpace`) returns the same block to all
   concurrent callers since it's a shared data structure.
3. The "try last block" fallback (`nblocks - 1`) is identical for all backends.

The contention point is `LockBuffer(buffer, BUFFER_LOCK_EXCLUSIVE)` at line
628 of `hio.c`. Every concurrent inserter serializes here on the
`BufferContent` LWLock for the same buffer descriptor. At 10+ backends doing
single-row inserts, this accounts for ~23% of total wall time.

##### Flow through RelationGetBufferForTuple (hio.c:499-883)

1. **Pick target**: Use bistate->current_buf, else smgr_targblock, else FSM,
   else last block in relation (nblocks-1).
2. **Lock & check**: ReadBufferBI + BUFFER_LOCK_EXCLUSIVE. If page has enough
   free space, call `RelationSetTargetBlock()` and return.
3. **No space**: Release lock, try FSM for another page (or bistate bulk-extend
   leftover pages), loop.
4. **Extend**: If FSM exhausted, call `RelationAddBlocks()` to extend. Set
   target block to newly allocated block.

The key insight: step 1 is where all backends converge. If we make step 1
return *different* blocks for different backends, they stop serializing.

##### Proposed Data Structure Changes

**Option A: Array in SMgrRelationData (RECOMMENDED for prototype)**

```c
/* src/include/storage/smgr.h */
#define SMGR_TARGBLOCK_SLOTS  4  /* must be power of 2 */

typedef struct SMgrRelationData
{
    ...
    BlockNumber smgr_targblock[SMGR_TARGBLOCK_SLOTS];
    ...
};
```

Pros: Minimal footprint, per-backend (no shared memory), simple.
Cons: Fixed N. All backends in one process share the same SMgrRelation, but
that's fine because PostgreSQL is process-per-connection -- each backend has
its own SMgrRelation hash table.

**Option B: Array in StdRdOptions (via reloption)**

A `insert_target_slots` reloption (1..16, default 1) controlling N. The
actual array stays in SMgrRelationData but its length is driven by the
reloption. This is more flexible but adds complexity for the prototype.

Recommendation: Start with Option A (compile-time constant), graduate to
Option B only if benchmarks prove the concept.

##### Proposed Code Changes

**1. smgr.h: Expand smgr_targblock to an array**

```c
#define SMGR_TARGBLOCK_SLOTS  4  /* power of 2 for fast modulo */
BlockNumber smgr_targblock[SMGR_TARGBLOCK_SLOTS];
```

**2. smgr.c: Initialize all slots to InvalidBlockNumber**

In `smgropen()` (line 273):
```c
for (int i = 0; i < SMGR_TARGBLOCK_SLOTS; i++)
    reln->smgr_targblock[i] = InvalidBlockNumber;
```

Same in `smgrrelease()` (line 359) and `RelationMapInvalidate` path in
`storage.c` (line 305).

**3. rel.h: Change the macros to accept/compute a slot index**

```c
/* Slot for this backend, using MyProcNumber for distribution */
#define RelationTargetBlockSlot() \
    ((uint32)MyProcNumber & (SMGR_TARGBLOCK_SLOTS - 1))

#define RelationGetTargetBlock(relation) \
    ( (relation)->rd_smgr != NULL ? \
      (relation)->rd_smgr->smgr_targblock[RelationTargetBlockSlot()] : \
      InvalidBlockNumber )

#define RelationSetTargetBlock(relation, targblock) \
    do { \
        RelationGetSmgr(relation)->smgr_targblock[RelationTargetBlockSlot()] = (targblock); \
    } while (0)
```

Using `MyProcNumber` (declared in `src/include/storage/procnumber.h`, type
`ProcNumber` aka `int`, assigned at backend startup) is ideal:
- Stable for the lifetime of the backend
- Already used pervasively, zero overhead
- Modulo a power-of-2 constant is a single AND instruction

**4. hio.c: No changes required for the basic version**

The existing logic in `RelationGetBufferForTuple()` already handles:
- Target block invalid -> fall through to FSM or extension (line 576-593)
- Target block full -> release lock, try FSM, loop (line 708-762)
- Extension needed -> call RelationAddBlocks, set target (line 765-880)

With the multi-slot macros, different backends will naturally:
- Get their own slot's target block (or InvalidBlockNumber initially)
- Set their own slot after finding/extending a page
- NOT interfere with other backends' slots

The FSM fallback still works: two backends that hash to the same slot will
share a target block (acceptable, just same as today). Two backends in
different slots will independently find pages via FSM or extension.

**5. Callers outside heap that use RelationGetTargetBlock/RelationSetTargetBlock**

These need review:

- `src/backend/access/brin/brin_pageops.c` (lines 705, 817): BRIN index
  inserts. Same multi-slot logic is fine here too.
- `src/backend/access/nbtree/nbtinsert.c` (lines 326-379, 1449): B-tree fast
  path for rightmost inserts. This code uses conditional locking and already
  handles the case where the cached block is stale. Multi-slot is safe here
  and would actually help B-tree append-heavy workloads too.
- `src/backend/commands/createas.c` (line 576), `matview.c` (line 501),
  `heapam_handler.c` (line 725): These are Asserts checking that all slots
  are InvalidBlockNumber. With the array change, these would need to check
  all slots or just one representative slot. Since they're Asserts in bulk
  paths that use bistate anyway, checking slot 0 is sufficient.

##### Interactions and Risks

**FSM interaction**: The FSM is a shared structure. When backend A's slot fills
up and it queries the FSM, it may get the same block that backend B's slot
points to. This is harmless: backend A will find space there, use it, and set
its own slot. The FSM cannot get "confused" by multiple active insert targets.

**VACUUM interaction**: VACUUM scans pages sequentially and updates the FSM. It
doesn't touch `smgr_targblock` (that's per-backend, process-local). No
interaction. If VACUUM frees space on a page that some backend has as its
target, that backend will simply find more free space there -- a win.

**Visibility map interaction**: The existing code in
`RelationGetBufferForTuple()` already handles all-visible pages (pins VM page
before locking buffer). Having N target blocks doesn't change this logic at
all since each path through the function handles one target block at a time.

**Table bloat / fragmentation**: With N=4 backends inserting into 4 different
pages, we fill pages slightly less efficiently (each page may have a few
hundred bytes of unfilled space before the next tuple goes to that slot's
page). For typical queue workloads with uniform tuple sizes, this is
negligible. For mixed workloads, the FSM reclaims space normally.

Worst case: if 4 pages each have `saveFreeSpace` bytes wasted, that's
4 * (8192 * (1 - fillfactor/100)) extra bytes. At fillfactor=100 (default),
this is zero because we fill pages completely before moving on.

**Sequential scan performance**: Tuples from concurrent transactions will be
interleaved across N pages instead of being sequential. This could slightly
hurt range scans that depend on physical ordering. For queue workloads (which
consume via DELETE or archival, not sequential scan), this is irrelevant.

**BulkInsertState interaction**: When `bistate != NULL` (COPY path), the code
bypasses `RelationGetTargetBlock()` entirely and uses
`bistate->current_buf` (hio.c line 571-572). So COPY is completely
unaffected by this change. This is correct since COPY is already optimized
with its own bulk extend logic.

**Relation extension contention**: With N target blocks, we may call
`RelationAddBlocks()` more frequently (each slot independently decides to
extend). However, `RelationAddBlocks()` already has adaptive bulk extension
(scales by waiter count, line 281). The relation extension lock
(`Lock:extend`) is a separate bottleneck (11% in our profile) and would
actually benefit slightly from staggered extension rather than thundering
herd.

**smgr cache invalidation**: `smgrrelease()` already resets
`smgr_targblock` to `InvalidBlockNumber`. With an array, it resets all
slots. Same for `storage.c:RelationMapInvalidate`. This is safe because
invalidation drops the entire SMgrRelation entry.

**Memory overhead**: `3 * sizeof(BlockNumber)` = 12 bytes extra per
SMgrRelation entry (going from 1 to 4 slots). There are at most a few
hundred SMgrRelation entries per backend. Total: ~1.2KB per backend.
Negligible.

##### Estimated Complexity

- **smgr.h change**: 3 lines (array declaration + define)
- **smgr.c changes**: ~10 lines (loop initialization in 2 places)
- **rel.h changes**: ~10 lines (macro rewrites)
- **storage.c change**: ~3 lines (loop for invalidation)
- **Assert fixups**: ~5 lines (3 call sites checking for InvalidBlockNumber)
- **Total**: ~30 lines of code change
- **Risk level**: Medium. Small patch but in critical hot path.
- **Review difficulty**: Would need sign-off from someone familiar with smgr
  and heap insertion. Key reviewer concern will be correctness of
  invalidation paths and memory model (all process-local, no atomics needed).

##### Suggested Prototype Approach

1. **Gate on Ideas 3 and 4 first.** Those are higher confidence and may
   reduce total contention enough that this idea becomes unnecessary.
   Re-profile after implementing those.

2. **If still needed, implement the minimal patch:**
   - Change smgr_targblock to array[4] in smgr.h
   - Fix initialization in smgr.c (2 places) and storage.c (1 place)
   - Update macros in rel.h to use MyProcNumber
   - Fix Assert sites (createas.c, matview.c, heapam_handler.c)

3. **Benchmark with pgbench queue workload:**
   - Baseline: current code at 8, 16, 32 clients
   - With patch: same client counts
   - Measure: ev/s, wait event breakdown (pg_stat_activity sampling),
     LWLock:BufferContent percentage
   - Also test: sequential scan performance on the same table, table size
     after 1M inserts (check for bloat)

4. **If promising, consider making N configurable:**
   - Add `insert_target_slots` reloption (1, 2, 4, 8, 16; default 4)
   - Store in StdRdOptions
   - Read via `RelationGetInsertTargetSlots(relation)` macro
   - Pass to a function version of RelationGetTargetBlock that takes
     the slot count as a parameter

5. **Alternative to explore**: Instead of hashing by MyProcNumber, use a
   round-robin approach where each backend increments a local counter. This
   would spread inserts even more evenly when backend count < slot count.
   However, the hash approach is simpler and sufficient when backend count
   >= slot count (the common case for queue workloads).

##### Why Not Implement Now

- Ideas 3 (WAL insert locks) and 4 (wal_compression) are strictly higher
  value and lower risk. They should be benchmarked first.
- The 23% LWLock:BufferContent number may partially overlap with WAL
  insertion time. After fixing WAL bottlenecks, the buffer contention
  percentage may shift.
- This change touches code that every INSERT in every PostgreSQL workload
  goes through. The blast radius of a bug is enormous. Need high confidence
  in the benefit before proceeding.

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
