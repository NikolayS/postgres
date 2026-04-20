# Design: Online Resizing of `shared_buffers` Without Restart

**Status:** Proposal / Design Document
**Target:** PostgreSQL 19+
**Author:** Design analysis based on PostgreSQL source code study
**Date:** 2026-02-06
**Related work:** Dmitry Dolgov's RFC patch series on pgsql-hackers (October 2024 -- April 2025)

---

## Table of Contents

1. [Motivation](#1-motivation)
2. [Current Architecture](#2-current-architecture)
3. [Prior Art: How Other Systems Do It](#3-prior-art-how-other-systems-do-it)
4. [Design Overview](#4-design-overview)
5. [Phase 1: Virtual Address Space Reservation](#5-phase-1-virtual-address-space-reservation)
6. [Phase 2: Growing the Buffer Pool](#6-phase-2-growing-the-buffer-pool)
7. [Phase 3: Shrinking the Buffer Pool](#7-phase-3-shrinking-the-buffer-pool)
8. [Phase 4: Hash Table Resizing](#8-phase-4-hash-table-resizing)
9. [Coordination Protocol](#9-coordination-protocol)
10. [GUC and User Interface Changes](#10-guc-and-user-interface-changes)
11. [Edge Cases and Corner Cases](#11-edge-cases-and-corner-cases)
12. [Huge Pages](#12-huge-pages)
13. [Portability](#13-portability)
14. [Performance Impact](#14-performance-impact)
15. [Observability](#15-observability)
16. [Testing Strategy](#16-testing-strategy)
17. [Migration and Compatibility](#17-migration-and-compatibility)
18. [Phased Implementation Plan](#18-phased-implementation-plan)
19. [Open Questions](#19-open-questions)
20. [References](#20-references)

---

## 1. Motivation

`shared_buffers` is arguably the most important PostgreSQL tuning parameter, yet
changing it requires a full server restart -- the most disruptive operation a
DBA can perform. This creates real-world pain in several scenarios:

- **Cloud/managed databases** that need to scale vertically without downtime
- **Autoscaling** in response to workload changes (e.g., reporting windows)
- **Initial misconfiguration** discovered under production load
- **Memory rebalancing** on multi-tenant hosts running multiple PG instances
- **Gradual warm-up** strategies: start small, grow as the working set stabilizes

Other major databases already support this:
- MySQL/InnoDB: `innodb_buffer_pool_size` has been online-resizable since 5.7.5 (2014)
- Oracle: `db_cache_size` dynamically adjustable within SGA since 9i (2001)
- SQL Server: `max server memory` fully dynamic (always was)

PostgreSQL should close this gap.

---

## 2. Current Architecture

Understanding what needs to change requires a detailed inventory of every data
structure and code path that depends on `NBuffers` being constant.

### 2.1 Shared Memory Allocation

At postmaster startup, `CreateSharedMemoryAndSemaphores()` (`src/backend/storage/ipc/ipci.c:191`)
allocates a single contiguous shared memory segment:

```
CalculateShmemSize()     -- compute total size including BufferManagerShmemSize()
PGSharedMemoryCreate()   -- mmap() one giant anonymous segment (or SysV)
CreateOrAttachShmemStructs() -- carve it up via ShmemInitStruct()
```

The segment size is fixed for the lifetime of the postmaster. All subsystems
allocate their shared memory from this segment via `ShmemInitStruct()`, which is
a simple bump allocator. There is no facility to grow or shrink the segment.

### 2.2 Buffer Manager Data Structures

`BufferManagerShmemInit()` (`src/backend/storage/buffer/buf_init.c:68`) allocates
five arrays, all dimensioned by `NBuffers`:

| Structure | Size per buffer | Total (default 128MB / 16384 bufs) | Purpose |
|---|---|---|---|
| `BufferDescriptors[]` | 64 bytes (cache-line padded) | 1 MB | Metadata: tag, state (atomic), lock waiters |
| `BufferBlocks` | 8192 bytes (BLCKSZ) | 128 MB | Actual page data |
| `BufferIOCVArray[]` | ~64 bytes (padded) | 1 MB | I/O completion condition variables |
| `CkptBufferIds[]` | 24 bytes | 384 KB | Checkpoint sort array |
| Buffer hash table | ~40 bytes | ~800 KB | Tag-to-buffer-ID lookup (partitioned) |

**Total overhead beyond the page data:** ~3.3 MB per 16384 buffers (~0.2 KB per buffer).

### 2.3 Critical Code Paths Depending on NBuffers

#### 2.3.1 Direct Array Indexing (Hot Path)

```c
// buf_internals.h:422 -- THE hottest function in PG
static inline BufferDesc *GetBufferDescriptor(uint32 id)
{
    return &(BufferDescriptors[id]).bufferdesc;
}

// bufmgr.c:73 -- converts descriptor to data pointer
#define BufHdrGetBlock(bufHdr) \
    ((Block) (BufferBlocks + ((Size) (bufHdr)->buf_id) * BLCKSZ))
```

These are zero-overhead array lookups. Every buffer pin, unpin, read, write, and
dirty operation goes through `GetBufferDescriptor()`. Any indirection added here
is on the absolute hottest path.

#### 2.3.2 Clock Sweep (Victim Selection)

```c
// freelist.c:99-156
static inline uint32 ClockSweepTick(void)
{
    victim = pg_atomic_fetch_add_u32(&StrategyControl->nextVictimBuffer, 1);
    if (victim >= NBuffers)
    {
        victim = victim % NBuffers;
        // ... wrap-around handling with completePasses increment
    }
    return victim;
}
```

The clock hand is a monotonically increasing atomic counter, reduced modulo
`NBuffers` to find the actual buffer. Changing `NBuffers` while the clock hand
is in flight would cause the modulo to produce different results -- but since
the clock hand is already designed to wrap, this is actually one of the easier
parts to handle (see Section 6.3).

#### 2.3.3 Buffer Lookup Hash Table

```c
// buf_table.c:50 -- fixed-size, created once
InitBufTable(NBuffers + NUM_BUFFER_PARTITIONS);
// Uses HASH_FIXED_SIZE flag -- cannot grow!
```

The buffer mapping hash table is created with `HASH_FIXED_SIZE`, explicitly
preventing dynamic growth. It's partitioned across `NUM_BUFFER_PARTITIONS` (128)
LWLocks. The table is sized for `NBuffers + NUM_BUFFER_PARTITIONS` entries to
handle concurrent insert-before-delete during buffer replacement.

#### 2.3.4 Background Writer and Checkpointer

```c
// freelist.c:230 -- scan limit in StrategyGetBuffer
trycounter = NBuffers;

// bufmgr.c:92 -- threshold for full-pool scan vs. hash lookup
#define BUF_DROP_FULL_SCAN_THRESHOLD  (uint64) (NBuffers / 32)
```

The bgwriter uses `StrategySyncStart()` which reads `nextVictimBuffer % NBuffers`.
The checkpointer allocates `CkptBufferIds[NBuffers]` at startup for sort space.

#### 2.3.5 Buffer Access Strategies (Ring Buffers)

```c
// freelist.c:560 -- ring buffers capped at 1/8 of pool
ring_buffers = Min(NBuffers / 8, ring_buffers);
```

Ring buffer sizes for sequential scans, VACUUM, and bulk writes are derived from
`NBuffers`. These are per-backend allocations and can tolerate NBuffers changes
between allocations -- but an active ring buffer referencing a buffer ID that
gets invalidated during shrink is dangerous.

#### 2.3.6 Other NBuffers Dependencies

- `GetAccessStrategyPinLimit()` returns `NBuffers` for NULL strategy
- `PrivateRefCount` hash table (per-backend, in local memory) -- no issue
- Predicate lock manager's buffer-level locks reference buffer IDs
- AIO subsystem references buffer IDs for in-flight I/O operations
- `pg_buffercache` extension iterates `0..NBuffers-1`

### 2.4 Shared Memory Backend Model

On Linux (the primary target), the postmaster creates shared memory via
anonymous `mmap()` with `MAP_SHARED`. Child backends inherit the mapping
through `fork()`. All backends see the same physical pages at the same virtual
address. There is no facility to notify backends that the mapping has changed.

On `EXEC_BACKEND` platforms (Windows), backends re-attach to the shared memory
segment after `exec()` via `AttachSharedMemoryStructs()`. This path already
handles pointer re-initialization -- which is actually advantageous for resize.

---

## 3. Prior Art: How Other Systems Do It

### 3.1 MySQL/InnoDB (Since 5.7.5)

**Unit of resize:** 128MB chunks (`innodb_buffer_pool_chunk_size`).

**Growing:**
1. Background thread allocates new chunks (OS memory)
2. New pages added to free list
3. Hash tables resized
4. Adaptive Hash Index (AHI) re-enabled

**Shrinking (much harder):**
1. AHI disabled
2. Defragmentation: pages from condemned chunks relocated
3. Dirty pages flushed, chunks freed
4. Hash tables resized

**Known problems:**
- TPS drops to zero during resize (MySQL Bug #81615)
- Shrink blocked by long-running transactions holding buffer pins
- mmap failures mid-resize treated as fatal
- AHI disabled for entire duration causes latency spikes

**Lesson:** Chunk-based allocation avoids per-page copying. But the critical
section that blocks all buffer access is the main source of production issues.

### 3.2 MariaDB (10.11.12+)

Evolved beyond MySQL's approach:
- Deprecated fixed chunk sizes; arbitrary 1MB increments
- `innodb_buffer_pool_size_max` reserves address space at startup
- Automatic memory-pressure-driven shrinking via Linux `madvise(MADV_DONTNEED)`
- Initially caused performance anomalies (MDEV-35000); disabled by default

**Lesson:** OS memory pressure integration is attractive but treacherous.
Hysteresis and minimum bounds are essential.

### 3.3 Oracle (SGA Dynamic Resize)

**Unit of resize:** Granules (4MB if SGA < 1GB, 16MB otherwise).

- Components resizable within `SGA_MAX_SIZE` (fixed at startup)
- ASMM/AMM automatic tuning uses cost-benefit analysis
- Shared pool shrink rarely succeeds due to pinned objects

**Known problems:**
- Memory thrashing: 900+ resize cycles/day ending at same size
- AMM incompatible with HugePages on Linux
- Buffer cache shrank from 2.6GB to 640MB causing system hang

**Lesson:** Always require explicit minimum bounds. Automatic tuning without
guardrails causes pathological oscillation. Pre-reserve the maximum.

### 3.4 SQL Server

Fundamentally different: demand-driven, page-at-a-time acquisition. No discrete
"resize operation." When `max server memory` is lowered, gradual release via
eviction. Resource Monitor handles OS memory pressure.

**Lesson:** The cleanest model, but requires a completely different memory
architecture than PostgreSQL's. Not directly applicable as a migration target.

### 3.5 Existing PostgreSQL Patch Work (Dolgov, 2024-2025)

Dmitry Dolgov's RFC patch series on pgsql-hackers establishes key groundwork:

| Patch | Approach |
|---|---|
| 0001 | Multiple shared memory mappings (instead of single mmap) |
| 0002 | Place mappings with offset (reserve space for growth) |
| 0003 | Shared memory "slots" for each buffer subsystem array |
| 0004 | Actual resize via `mremap` with GUC assign hook |
| 0005 | `memfd_create` for anonymous file-backed segments |
| 0006 | Coordination for shrinking (prevent SIGBUS from ftruncate) |

**Key design choices:**
- `max_available_memory` GUC reserves virtual address space at startup
- Extends `ProcSignalBarrier` for global coordination
- Linux-specific (`mremap`, `memfd_create`)
- Currently grow-only; shrink coordination is WIP

**Open issues identified by reviewers:**
- Portability to non-Linux (macOS, FreeBSD, Windows)
- HugePages interaction with `mremap`
- Address space collisions from other allocations
- No POSIX fallback for `memfd_create`

---

## 4. Design Overview

Based on the analysis above, we propose a **chunk-based, grow-first** design
that builds on Dolgov's foundation while addressing identified gaps:

### Core Principles

1. **Zero overhead on the hot path when not resizing.** The `GetBufferDescriptor()`
   and `BufHdrGetBlock()` lookups must remain direct array indexing. No pointer
   indirection, no bounds checks, no version counters in steady state.

2. **Chunk-based allocation.** Buffer pool memory is managed in chunks
   (default 128MB, configurable). Growing adds chunks; shrinking removes them.
   Within a chunk, memory is contiguous. Chunks need not be contiguous with
   each other.

3. **Reserve virtual address space at startup.** A `max_shared_buffers` GUC
   (default: 2x `shared_buffers`, max: total system RAM) reserves virtual
   address space at postmaster start. Growing beyond this requires restart.

4. **Grow is online and nearly non-blocking.** Shrink requires a brief
   coordinated pause.

5. **Phase the implementation.** Grow-only first. Shrink later. Auto-tuning
   never (leave to external tools).

### Architecture Diagram

```
Virtual Address Space (reserved at startup for max_shared_buffers):
┌──────────────────────────────────────────────────────────────────┐
│                        BufferBlocks region                       │
│  ┌─────────┬─────────┬─────────┬ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐ │
│  │ Chunk 0 │ Chunk 1 │ Chunk 2 │    (reserved, uncommitted)    │
│  │ 128 MB  │ 128 MB  │ 128 MB  │                               │
│  └─────────┴─────────┴─────────┴ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘ │
├──────────────────────────────────────────────────────────────────┤
│                    BufferDescriptors region                      │
│  ┌─────────┬─────────┬─────────┬ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐ │
│  │ Descs 0 │ Descs 1 │ Descs 2 │    (reserved, uncommitted)    │
│  └─────────┴─────────┴─────────┴ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘ │
├──────────────────────────────────────────────────────────────────┤
│                    BufferIOCVArray region                        │
│  (same pattern)                                                  │
├──────────────────────────────────────────────────────────────────┤
│                    CkptBufferIds region                          │
│  (same pattern)                                                  │
└──────────────────────────────────────────────────────────────────┘
```

Each region is reserved as a contiguous virtual address range sized for
`max_shared_buffers`. Physical memory is committed only for the active
`shared_buffers` portion. The global pointers (`BufferDescriptors`,
`BufferBlocks`, etc.) never change -- only `NBuffers` changes.

---

## 5. Phase 1: Virtual Address Space Reservation

### 5.1 Separate Buffer Manager Memory from Main Shmem

**Problem:** Today, buffer pool arrays are allocated from the same `mmap`
segment as everything else (lock tables, proc arrays, CLOG, etc.) via
`ShmemInitStruct()`. We cannot resize one part without affecting the rest.

**Solution:** Allocate the buffer manager's five arrays as a **separate memory
mapping**, independent of the main shared memory segment:

```c
/* New function in buf_init.c */
void
BufferManagerShmemReserve(void)
{
    Size max_bufs = MaxNBuffers;  /* from max_shared_buffers GUC */

    /* Reserve VA space for BufferBlocks */
    BufferBlocks = mmap(NULL,
                        max_bufs * BLCKSZ + PG_IO_ALIGN_SIZE,
                        PROT_NONE,           /* no access yet */
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE,
                        -1, 0);

    /* Similarly for BufferDescriptors, BufferIOCVArray, CkptBufferIds */
    ...

    /* Commit the initial shared_buffers portion */
    BufferManagerShmemCommit(NBuffers);
}
```

The key insight: `PROT_NONE` + `MAP_NORESERVE` reserves virtual address space
without committing physical memory or swap. We then `mprotect()` + `mmap()` the
active portion with `MAP_SHARED | MAP_FIXED`.

### 5.2 New GUC: `max_shared_buffers`

```
{ name => 'max_shared_buffers',
  type => 'int',
  context => 'PGC_POSTMASTER',     /* requires restart */
  group => 'RESOURCES_MEM',
  short_desc => 'Maximum value to which shared_buffers can be set without restart.',
  flags => 'GUC_UNIT_BLOCKS',
  variable => 'MaxNBuffers',
  boot_val => '0',                  /* 0 means "same as shared_buffers" */
  min => '0',
  max => 'INT_MAX / 2',
}
```

When `max_shared_buffers = 0` (default), it equals `shared_buffers` and no
online resize is possible -- preserving current behavior. When set to a value
greater than `shared_buffers`, online resize up to that limit is enabled.

### 5.3 Shared Memory Backing

For the reserved region to be shared across `fork()`ed backends, we need a
shared anonymous file descriptor. Options:

| Method | Pros | Cons |
|---|---|---|
| `memfd_create()` | No filesystem impact, sealed | Linux 3.17+ only |
| `shm_open()` + unlink | POSIX portable | Requires /dev/shm space |
| Anonymous `mmap(MAP_SHARED)` | Simplest | Cannot `mremap()` |

**Recommended:** Use `memfd_create()` on Linux (the dominant production
platform), with `shm_open()` fallback for FreeBSD/macOS. On Windows
(EXEC_BACKEND), use `CreateFileMapping()` with `SEC_RESERVE`.

### 5.4 Keeping Pointers Stable

The critical invariant: `BufferDescriptors`, `BufferBlocks`, `BufferIOCVArray`,
and `CkptBufferIds` pointers must never change after postmaster startup.
Growing the pool extends the committed region *within* the already-reserved
range, so the base address stays fixed. This means:

- `GetBufferDescriptor(id)` continues to work with zero overhead
- `BufHdrGetBlock(bufHdr)` continues to work with zero overhead
- No pointer indirection is needed on the hot path

---

## 6. Phase 2: Growing the Buffer Pool

Growing is the simpler operation. New buffers are added at the end of the
arrays with no impact on existing buffers.

### 6.1 Grow Algorithm

```
1. DBA issues: ALTER SYSTEM SET shared_buffers = '2GB'; SELECT pg_reload_conf();
   Or: SET shared_buffers = '2GB';  (with PGC_SIGHUP context)

2. Postmaster receives SIGHUP, validates new value <= max_shared_buffers.

3. Postmaster initiates resize sequence:

   a. Commit new memory pages:
      - mmap(MAP_FIXED | MAP_SHARED) over the PROT_NONE region for each array
      - Or: ftruncate() the memfd to the new size + mprotect()

   b. Initialize new buffer descriptors:
      for (i = old_NBuffers; i < new_NBuffers; i++) {
          BufferDesc *buf = GetBufferDescriptor(i);
          ClearBufferTag(&buf->tag);
          pg_atomic_init_u64(&buf->state, 0);
          buf->wait_backend_pgprocno = INVALID_PROC_NUMBER;
          buf->buf_id = i;
          ConditionVariableInit(BufferDescriptorGetIOCV(buf));
      }

   c. Emit ProcSignalBarrier to all backends:
      EmitProcSignalBarrier(PROCSIGNAL_BARRIER_BUFFER_POOL_RESIZE);

   d. Wait for all backends to acknowledge:
      WaitForProcSignalBarrier(generation);

   e. Update NBuffers atomically:
      pg_atomic_write_u32(&shared_NBuffers, new_NBuffers);

   f. New buffers are immediately available for clock sweep.
```

### 6.2 Why Growing Is Nearly Non-Blocking

During step 3a-3b, existing buffers are untouched. Backends continue operating
normally on buffers 0..old_NBuffers-1. The barrier in step 3c-3d only requires
each backend to:

1. Call `ProcessProcSignalBarrier()` at the next CHECK_FOR_INTERRUPTS()
2. Read the new `NBuffers` value
3. Acknowledge the barrier

No buffer access needs to be paused. The new buffers simply appear at the end
of the arrays, and the clock sweep naturally starts visiting them.

### 6.3 Clock Sweep Interaction

The clock sweep hand (`nextVictimBuffer`) is a monotonically increasing atomic
counter reduced modulo `NBuffers`. When `NBuffers` increases:

- If hand is at position H and old NBuffers was N₁ and new is N₂ (N₂ > N₁):
  - `H % N₁` and `H % N₂` may differ, but this is harmless -- the clock sweep
    already tolerates arbitrary starting positions
  - The `completePasses` counter becomes slightly inaccurate for one cycle
  - The bgwriter's sync estimation may be off for one cycle (acceptable)

No special handling is needed beyond updating the value of NBuffers.

### 6.4 Hash Table Interaction

The buffer hash table (`SharedBufHash`) is currently fixed-size. After growing
NBuffers, the table may become undersized, leading to longer chains and slower
lookups. Options:

**Option A: Over-provision at startup.** Size the hash table for
`MaxNBuffers + NUM_BUFFER_PARTITIONS` entries. Wastes memory proportional to
`max_shared_buffers - shared_buffers`, but hash tables are small (~40 bytes per
entry). For a 2x over-provision, the waste is ~40 * NBuffers ≈ 0.6 MB per GB
of buffer pool. This is the recommended approach for Phase 2.

**Option B: Dynamic hash table.** Replace `HASH_FIXED_SIZE` with a dynamically
resizable hash table. More complex but avoids the waste. Deferred to Phase 4.

### 6.5 AIO and In-Flight I/O

The AIO subsystem tracks in-flight I/O operations referencing buffer IDs.
Growing is safe: new buffer IDs (≥ old_NBuffers) won't have any in-flight I/O.
Existing buffer I/O continues undisturbed.

---

## 7. Phase 3: Shrinking the Buffer Pool

Shrinking is fundamentally harder than growing. Buffers being removed may
contain dirty data, be pinned by active backends, or be referenced by in-flight
I/O operations.

### 7.1 Shrink Algorithm

```
1. DBA issues: ALTER SYSTEM SET shared_buffers = '512MB'; SELECT pg_reload_conf();

2. Postmaster validates new value >= min_shared_buffers (16 blocks).

3. Postmaster initiates drain sequence:

   a. Mark condemned range [new_NBuffers, old_NBuffers) as "draining":
      - Set a shared flag: drain_target = new_NBuffers
      - Clock sweep skips condemned buffers for allocation
      - New buffer allocations cannot choose condemned buffers

   b. Drain condemned buffers (may take multiple passes):
      for each buffer in condemned range:
        - If buffer is dirty, schedule writeback
        - If buffer has tag, remove from hash table
        - Wait for refcount == 0 (buffer unpinned by all)
        - Wait for I/O completion (no in-flight AIO)
        - Invalidate: clear tag, set state to 0

   c. After all condemned buffers are drained:
      Emit ProcSignalBarrier(PROCSIGNAL_BARRIER_BUFFER_POOL_RESIZE)

   d. Wait for all backends to acknowledge.

   e. Update NBuffers atomically:
      pg_atomic_write_u32(&shared_NBuffers, new_NBuffers);

   f. Decommit memory:
      madvise(MADV_DONTNEED, ...) on the freed regions
      mprotect(PROT_NONE, ...) to prevent accidental access

4. If drain does not complete within timeout (e.g., 60 seconds):
   - Log a WARNING identifying which buffers are still pinned
   - Cancel the shrink operation
   - Restore original NBuffers
```

### 7.2 Drain Coordination Details

The drain phase is the hardest part. Each condemned buffer can be in one of
several states:

| Buffer State | Action Required |
|---|---|
| Free (no tag, refcount=0) | Nothing -- already drainable |
| Valid, clean, unpinned | Remove from hash table, clear tag |
| Valid, dirty, unpinned | Flush to disk, then clear |
| Valid, pinned (refcount > 0) | Wait for unpin -- cannot force |
| I/O in progress | Wait for I/O completion |
| Locked (BM_LOCKED) | Wait for unlock |
| Content lock held | Wait for content lock release |

**Pinned buffers are the critical bottleneck.** A backend holding a pin on a
condemned buffer prevents shrinking. We cannot force-unpin because:
- The backend may be in the middle of reading/writing the page
- The backend's `PrivateRefCount` would become inconsistent
- It could corrupt data

**Strategy:** Use a cooperative approach:
1. Set a per-buffer flag `BM_CONDEMNED` in the buffer state
2. When a backend unpins a condemned buffer, instead of just decrementing
   refcount, it also invalidates the buffer (removes from hash table, clears tag)
3. The postmaster's drain loop polls condemned buffers, flushing dirty ones
   and waiting for pins to be released
4. A timeout prevents indefinite blocking

### 7.3 Preventing SIGBUS on Shrink

When using `memfd_create()`, shrinking the underlying file with `ftruncate()`
immediately invalidates the pages -- any backend accessing that memory will get
SIGBUS. This is the problem identified in Dolgov's patch 0006.

**Solution:** The barrier protocol ensures all backends have stopped accessing
the condemned region before `ftruncate()` or `mprotect(PROT_NONE)`:

```
Timeline:
  1. All condemned buffers drained (refcount=0, no tags, no I/O)
  2. Barrier emitted -- all backends process it and read new NBuffers
  3. After barrier: NBuffers is smaller, so no backend will access IDs >= new NBuffers
  4. Only now: ftruncate/mprotect to release the memory
```

The safety invariant: after the barrier completes, no backend can form a
reference to a buffer ID >= new_NBuffers because:
- `GetBufferDescriptor(ClockSweepTick())` returns `victim % NBuffers` where
  NBuffers is now smaller
- `BufTableLookup()` can't return an ID >= new_NBuffers because all condemned
  entries were removed in the drain phase
- `PrivateRefCount` entries for condemned buffers were cleared during unpin

### 7.4 In-Flight I/O and AIO

Before shrinking, ALL in-flight I/O on condemned buffers must complete:
1. Check `io_wref` on each condemned buffer descriptor
2. If AIO is in progress, wait for completion
3. Do NOT initiate new I/O on condemned buffers after drain starts

The bgwriter and checkpointer must also be aware of the drain -- they should
not attempt to flush condemned buffers after the drain is initiated.

---

## 8. Phase 4: Hash Table Resizing

### 8.1 Problem Statement

The buffer hash table (`SharedBufHash`) uses PostgreSQL's `dynahash` with
`HASH_FIXED_SIZE`. After significant growth, the hash table may have excessive
chain lengths. After shrinking, it wastes memory.

### 8.2 Incremental Rehashing

Full rehashing requires locking all 128 partitions simultaneously -- equivalent
to stopping all buffer operations. Instead, use **incremental rehashing**:

1. Allocate new hash table alongside the old one
2. For each partition (0..127):
   a. Acquire exclusive lock on partition
   b. Move all entries from old bucket to new bucket
   c. Release lock
   d. (Other partitions continue operating on old table concurrently)
3. After all 128 partitions migrated:
   a. Emit barrier to switch all backends to new table
   b. Deallocate old table

**Concurrency:** Since each partition is independently locked, at most one
partition is being migrated at any time. Other backends see consistent state
because they look up the partition lock before accessing the table. Reads in
non-migrating partitions are unaffected.

### 8.3 Alternative: Over-Provision

For the initial implementation, simply pre-size the hash table for
`MaxNBuffers + NUM_BUFFER_PARTITIONS`. The additional memory cost is modest:

| max_shared_buffers | Hash table waste |
|---|---|
| 2x shared_buffers (1GB → 2GB) | ~5 MB |
| 4x shared_buffers (1GB → 4GB) | ~15 MB |
| 8x shared_buffers (1GB → 8GB) | ~35 MB |

This is a reasonable tradeoff for avoiding the complexity of online hash table
resizing in the initial implementation.

---

## 9. Coordination Protocol

### 9.1 ProcSignalBarrier Extension

PostgreSQL already has a `ProcSignalBarrier` mechanism used for
`PROCSIGNAL_BARRIER_SMGRRELEASE`. We extend it with a new barrier type:

```c
typedef enum
{
    PROCSIGNAL_BARRIER_SMGRRELEASE,
    PROCSIGNAL_BARRIER_UPDATE_XLOG_LOGICAL_INFO,
    PROCSIGNAL_BARRIER_BUFFER_POOL_RESIZE,   /* NEW */
} ProcSignalBarrierType;
```

When a backend processes this barrier:
1. Read the new value of `NBuffers` from shared memory
2. Update any backend-local cached values derived from NBuffers
3. Invalidate active `BufferAccessStrategy` objects that reference condemned IDs
4. Check `PrivateRefCount` for entries referencing condemned buffers (should be
   none if drain completed correctly -- assert in debug builds)
5. Acknowledge the barrier

### 9.2 Making NBuffers Atomic

Currently, `NBuffers` is a plain `int` read without synchronization:

```c
// globals.c
int NBuffers = 16384;
```

For online resize, it must become an atomic variable with a local cache:

```c
// In shared memory:
pg_atomic_uint32 SharedNBuffers;

// Per-backend cached copy (updated at barrier):
int NBuffers;  /* remains a plain int for zero-overhead reads */
```

The barrier protocol ensures all backends update their local `NBuffers` before
the resize is considered complete. Between barriers, the local copy is
guaranteed to be current.

**Critical safety property:** Between the moment the postmaster updates
`SharedNBuffers` and the moment a backend processes the barrier, the backend
is using the OLD NBuffers value. This is safe because:
- For grow: the backend simply doesn't know about new buffers yet (harmless)
- For shrink: the drain phase ensures all condemned buffers are already free
  and removed from the hash table, so no backend can reach them even with the
  old NBuffers value (the hash table won't return condemned IDs, and the clock
  sweep won't pick them because they're flagged)

### 9.3 Ordering Guarantees

The resize sequence must ensure:

```
For GROW:
  memory committed → descriptors initialized → barrier → NBuffers updated
  (Backends must not see new NBuffers before memory is ready)

For SHRINK:
  drain initiated → drain completed → barrier → NBuffers updated → memory freed
  (Memory must not be freed before all backends acknowledge)
```

These orderings are enforced by the barrier mechanism, which acts as a full
memory fence across all processes.

---

## 10. GUC and User Interface Changes

### 10.1 GUC Context Change

```
shared_buffers:      PGC_POSTMASTER → PGC_SIGHUP
max_shared_buffers:  new, PGC_POSTMASTER
```

When `max_shared_buffers` is 0 (default), `shared_buffers` remains
PGC_POSTMASTER-like (validated at startup, cannot exceed current allocation).
When `max_shared_buffers > shared_buffers`, `shared_buffers` becomes
dynamically adjustable via `SIGHUP`.

### 10.2 Validation Hooks

```c
/* GUC check hook for shared_buffers */
bool
check_shared_buffers(int *newval, void **extra, GucSource source)
{
    if (source == PGC_S_FILE || source == PGC_S_CLIENT)
    {
        /* Runtime change */
        if (*newval > MaxNBuffers)
        {
            GUC_check_errmsg("shared_buffers cannot exceed max_shared_buffers (%d)",
                             MaxNBuffers);
            return false;
        }
        if (*newval < MIN_SHARED_BUFFERS)
        {
            GUC_check_errmsg("shared_buffers must be at least %d",
                             MIN_SHARED_BUFFERS);
            return false;
        }
    }
    return true;
}

/* GUC assign hook for shared_buffers */
void
assign_shared_buffers(int newval, void *extra)
{
    if (IsUnderPostmaster && newval != NBuffers)
    {
        /* Initiate async resize -- actual work happens in postmaster */
        RequestBufferPoolResize(newval);
    }
}
```

### 10.3 SQL Interface

```sql
-- Check current and maximum values:
SHOW shared_buffers;         -- '1GB'
SHOW max_shared_buffers;     -- '4GB'

-- Grow:
ALTER SYSTEM SET shared_buffers = '2GB';
SELECT pg_reload_conf();

-- Shrink:
ALTER SYSTEM SET shared_buffers = '512MB';
SELECT pg_reload_conf();

-- Monitor resize progress:
SELECT * FROM pg_stat_buffer_pool_resize;
```

### 10.4 pg_stat_buffer_pool_resize View

| Column | Type | Description |
|---|---|---|
| `status` | text | 'idle', 'growing', 'draining', 'completing' |
| `current_buffers` | int8 | Current NBuffers |
| `target_buffers` | int8 | Target NBuffers (= current when idle) |
| `max_buffers` | int8 | Maximum NBuffers (from max_shared_buffers) |
| `condemned_remaining` | int8 | Buffers still to drain (shrink only) |
| `condemned_pinned` | int8 | Condemned buffers blocked by pins |
| `condemned_dirty` | int8 | Condemned buffers being flushed |
| `started_at` | timestamptz | When current resize started |

---

## 11. Edge Cases and Corner Cases

### 11.1 Concurrent Resize Requests

**Scenario:** DBA sets `shared_buffers = 2GB`, then immediately `shared_buffers = 4GB`
before the first resize completes.

**Solution:** Serialize resize operations. Only one resize can be in progress.
If a new target arrives while resizing:
- If same direction (both grow or both shrink): update target, continue
- If opposite direction: complete current operation first, then start new one
- A resize-in-progress flag in shared memory prevents concurrent requests

### 11.2 Crash During Resize

**Scenario:** Postmaster crashes or is killed mid-resize.

**For grow:** New memory was committed but NBuffers wasn't updated yet. On
restart, `shared_buffers` from config is used to compute NBuffers. The extra
committed memory is released when the old mapping is unmapped. No data loss.

**For shrink:** Drain was in progress but NBuffers wasn't reduced yet. On
restart, full buffer pool is available. Condemned buffers that were flushed
are simply empty buffers. No data loss.

**Key invariant:** The persistent `shared_buffers` in `postgresql.conf` is
always updated via `ALTER SYSTEM` *before* the resize begins. So on restart,
the new target value is used for fresh initialization.

### 11.3 Backend Startup During Resize

**Scenario:** New backend connects while resize is in progress.

**For grow:** New backend inherits the shared memory mapping via `fork()`.
It reads NBuffers from shared memory. If the barrier hasn't completed yet,
it gets the old value -- safe (just doesn't see new buffers yet). After
processing the barrier, it sees the new value.

**For shrink:** New backend reads NBuffers. If drain is still in progress,
it gets the old value. It won't access condemned buffers because:
1. Hash table entries for condemned pages are being removed
2. Clock sweep skips condemned buffers
3. When it processes the barrier, it gets the new value

### 11.4 Long-Running Queries Pinning Condemned Buffers

**Scenario:** A sequential scan holds pins on buffers in the condemned range
for the duration of a multi-hour query.

**Solutions (in order of preference):**
1. **Wait with timeout:** Default 5 minutes. If pins aren't released, log a
   WARNING with the PID and query, and cancel the shrink.
2. **Cooperative release:** When a backend unpins a condemned buffer, don't
   re-add it to the ring. The scan will allocate a new buffer from the
   surviving range.
3. **Admin override:** `pg_terminate_backend()` or `pg_cancel_backend()`
   as a last resort.

The shrink must NEVER force-unpin a buffer. That would corrupt the backend's
`PrivateRefCount` state and potentially the data.

### 11.5 Checkpointer During Resize

**Scenario:** A checkpoint is in progress when resize starts.

**For grow:** No issue. Checkpoint doesn't know about new buffers yet, but
they're all clean (unused). Next checkpoint will include them if dirtied.

**For shrink:** Checkpoint's `CkptBufferIds` array was allocated for old
NBuffers. The drain phase must wait for any in-progress checkpoint to
complete before it can deallocate the condemned portion of `CkptBufferIds`.

**Solution:** Add checkpoint-awareness to the resize protocol:
1. Before initiating shrink drain, request a checkpoint
2. After checkpoint completes, proceed with drain
3. The `CkptBufferIds` array for new NBuffers is a prefix of the old array
   (since we shrink from the high end), so no reallocation is needed

### 11.6 pg_buffercache and External Extensions

**Scenario:** `pg_buffercache` or third-party extensions iterate
`0..NBuffers-1` and read buffer descriptors.

**Risk:** If an extension caches NBuffers and iterates after a shrink,
it may access descriptors beyond the valid range.

**Solution:**
1. `pg_buffercache` and built-in code: update to read NBuffers at iteration
   start, not cache it
2. Third-party extensions: document the behavior change. After shrink,
   descriptors beyond NBuffers are zero-filled (PROT_NONE on the freed
   range will SIGSEGV, which is a loud failure mode -- better than silent
   corruption)
3. Provide a `BufferPoolGeneration` counter that extensions can check

### 11.7 Predicate Locks on Condemned Buffers

**Scenario:** Serializable transactions hold predicate locks at the buffer
level. A condemned buffer might have active predicate locks.

**Solution:** The predicate lock manager uses buffer IDs as lock targets.
During drain:
1. Before removing a condemned buffer from the hash table, transfer any
   buffer-level predicate locks to relation-level locks (coarser granularity)
2. This is consistent with existing behavior when buffers are evicted normally

### 11.8 Relation Cache and SMgr References

`SMgrRelation` objects cache information about which blocks are in the buffer
pool. These are per-backend and not affected by buffer pool resize, since the
buffer manager is the authoritative source.

### 11.9 WAL Replay (Startup Process)

**Scenario:** Buffer pool resize during WAL replay (recovery mode).

**Solution:** Do not allow resize during recovery. Validate this in the GUC
check hook. WAL replay assumes a stable buffer pool configuration.

### 11.10 Logical and Physical Replication

**Scenario:** Primary resizes buffer pool; replica does not.

**No issue.** `shared_buffers` is an independent per-instance setting. Buffer
pool size is not replicated. Each instance manages its own buffer pool
independently.

### 11.11 `temp_buffers` Interaction

`temp_buffers` (local buffers for temporary tables) are per-backend and
completely independent of shared buffers. No interaction.

### 11.12 Out-of-Memory During Grow

**Scenario:** System doesn't have enough physical memory when committing
new pages during grow.

**Solution:**
1. `mmap()` with `MAP_POPULATE` to force page allocation; check return value
2. If allocation fails, log ERROR and abort the grow operation
3. NBuffers remains unchanged -- fully recoverable
4. Alternatively, use `madvise(MADV_POPULATE_WRITE)` after `mmap()` to detect
   OOM before committing to the resize

### 11.13 Buffer Pool Resize and VACUUM

**Scenario:** VACUUM is running with a ring buffer during shrink.

**Risk:** The ring buffer may contain buffer IDs in the condemned range.

**Solution:** When processing the resize barrier, each backend checks its
active `BufferAccessStrategy`:
- If any ring buffer entry references a condemned ID, replace it with
  `InvalidBuffer` (the ring will allocate a new buffer from the surviving range)
- This is analogous to `StrategyRejectBuffer()`'s existing logic

### 11.14 Race Between PIN and NBuffers Update

**Scenario:** Backend A reads `NBuffers = 2000`, begins to pin buffer 1999.
Concurrently, backend B processes shrink barrier and updates its NBuffers to
1000. Can A successfully pin a condemned buffer?

**Analysis:** This cannot happen because:
1. The drain phase ensures buffer 1999 has refcount = 0 and no hash table entry
   BEFORE the barrier is emitted
2. Backend A can only reach buffer 1999 via:
   - Hash table lookup (entry already removed)
   - Clock sweep (condemned buffers are skipped)
3. If A already had a pin on 1999 from before the drain, the drain waits for
   A to release that pin before proceeding

### 11.15 Rapid Grow-Shrink Cycles

**Scenario:** External tooling rapidly adjusts `shared_buffers` up and down.

**Protection:**
- Minimum cooldown period between resize operations (configurable, default
  30 seconds)
- Each resize logs to the server log with timing and old/new values
- The `pg_stat_buffer_pool_resize` view shows history for monitoring

---

## 12. Huge Pages

### 12.1 The Challenge

When `huge_pages = on`, PostgreSQL allocates the shared memory segment using
2MB (or 1GB) huge pages via `mmap()` with `MAP_HUGETLB`. This improves TLB
coverage for the buffer pool.

**Problem with resize:**
- `mremap()` on `MAP_HUGETLB` regions has historically been unreliable on Linux
- Committing additional huge pages after startup may fail if the system's
  huge page pool is exhausted
- Huge pages cannot be partially committed -- you get a full 2MB page or nothing

### 12.2 Solution

**For grow with huge pages:**
1. At startup, reserve `max_shared_buffers` worth of huge pages (via
   `MAP_HUGETLB | MAP_NORESERVE`)
2. Growing commits additional huge pages from the pre-reserved range
3. If the OS huge page pool is exhausted, fall back to regular pages for the
   new portion (with a WARNING)

**For shrink with huge pages:**
1. After drain and barrier, use `madvise(MADV_DONTNEED)` to release huge pages
2. On Linux 4.5+, `MADV_FREE` can be used for lazy release

**Alternative (Dolgov's approach):** Replace `mremap()` with unmap+remap:
```c
munmap(old_addr + old_size, extend_size);
mmap(old_addr, new_size, ..., MAP_HUGETLB | MAP_FIXED, memfd, 0);
```
This works because the `memfd` preserves the data; we're just changing the
mapping, not the content.

### 12.3 `max_shared_buffers` and Huge Page Reservation

When `huge_pages = on` and `max_shared_buffers > shared_buffers`:
- The system must have enough huge pages for `max_shared_buffers` worth of
  virtual address reservation
- The `shared_memory_size_in_huge_pages` GUC should report the maximum
  reservation needed
- Document that DBAs must configure `vm.nr_hugepages` for the maximum, not
  just the initial `shared_buffers`

---

## 13. Portability

### 13.1 Linux (Primary Target)

Full support using:
- `memfd_create()` for shared anonymous file
- `mmap()` with `MAP_FIXED` for commit/decommit
- `mprotect()` for access control
- `madvise(MADV_DONTNEED)` for memory release
- `MAP_HUGETLB` for huge page support

### 13.2 FreeBSD

- `memfd_create()` available since FreeBSD 13
- `shm_open(SHM_ANON)` as alternative
- `MAP_HUGETLB` → `MAP_ALIGNED_SUPER`
- Otherwise similar to Linux

### 13.3 macOS

- No `memfd_create()` -- use `shm_open()` with immediate unlink
- No huge page support in `mmap()` (superpages via `VM_FLAGS_SUPERPAGE_SIZE_2MB`
  in Mach VM only)
- `mmap()` with `MAP_FIXED` works
- Practical limitation: macOS is rarely used for production PG

### 13.4 Windows (EXEC_BACKEND)

- Use `VirtualAlloc()` with `MEM_RESERVE` / `MEM_COMMIT`
- `CreateFileMapping()` with `SEC_RESERVE` for shared memory
- `MapViewOfFile()` for backend attachment
- `VirtualFree()` with `MEM_DECOMMIT` for shrink
- Large pages via `MEM_LARGE_PAGES`

Windows EXEC_BACKEND mode already re-attaches shared memory after `exec()`.
The resize protocol would extend `AttachSharedMemoryStructs()` to handle
variable-size regions.

### 13.5 Portability Abstraction Layer

Create a `pg_shmem_resize.h` abstraction:

```c
/* Reserve virtual address space without committing physical memory */
extern void *pg_shmem_reserve(Size size);

/* Commit physical memory within a reserved region */
extern bool pg_shmem_commit(void *addr, Size size, bool huge_pages);

/* Decommit physical memory (return to OS) */
extern void pg_shmem_decommit(void *addr, Size size);

/* Is this region committed? */
extern bool pg_shmem_is_committed(void *addr, Size size);
```

Platform-specific implementations in `src/backend/port/`.

---

## 14. Performance Impact

### 14.1 Steady-State Overhead (Not Resizing)

**Goal: Zero overhead when not resizing.**

Analysis of the proposed design:

| Component | Overhead | Explanation |
|---|---|---|
| `GetBufferDescriptor()` | **None** | Still direct array indexing |
| `BufHdrGetBlock()` | **None** | Still pointer arithmetic |
| `ClockSweepTick()` | **None** | `% NBuffers` unchanged (NBuffers is a local int) |
| `BufTableLookup()` | **Negligible** | Slightly larger hash table (over-provisioned) |
| `NBuffers` reads | **None** | Local cached copy, plain int |

The only measurable difference is a slightly larger hash table, which may
actually improve performance (fewer collisions at low fill ratio).

### 14.2 During Grow

- Memory allocation: OS kernel overhead for committing pages (~ms)
- Barrier propagation: Each backend processes barrier at next
  `CHECK_FOR_INTERRUPTS()` -- typically within milliseconds
- No query pauses or lock contention

**Expected impact: < 100ms for typical grow operations.**

### 14.3 During Shrink

- Drain phase: depends on how many condemned buffers are dirty and/or pinned
  - Best case (all clean, unpinned): milliseconds
  - Typical case (some dirty): seconds (bounded by flush speed)
  - Worst case (pinned by long queries): may need to wait minutes or cancel
- Barrier propagation: same as grow
- Memory decommit: OS kernel overhead (~ms)

**Expected impact: seconds for typical shrink operations, bounded by the
slowest-to-drain buffer.**

### 14.4 Benchmarking Plan

Measure with pgbench at various scales:
1. **Baseline:** Fixed shared_buffers, no resize capability compiled in
2. **Overhead test:** max_shared_buffers > shared_buffers but no resize occurs
3. **Grow test:** Grow from 1GB to 4GB under pgbench load, measure TPS impact
4. **Shrink test:** Shrink from 4GB to 1GB under pgbench load
5. **Stress test:** Rapid grow/shrink cycles to detect race conditions

---

## 15. Observability

### 15.1 Server Log Messages

```
LOG:  buffer pool resize started: 131072 -> 262144 buffers (1 GB -> 2 GB)
LOG:  buffer pool resize: committing memory for 131072 new buffers
LOG:  buffer pool resize: initializing new buffer descriptors
LOG:  buffer pool resize: waiting for all backends to acknowledge
LOG:  buffer pool resize completed in 127 ms
```

For shrink:
```
LOG:  buffer pool resize started: 262144 -> 131072 buffers (2 GB -> 1 GB)
LOG:  buffer pool resize: draining 131072 condemned buffers
LOG:  buffer pool resize: draining progress: 130000/131072 (1072 remaining, 42 pinned, 15 dirty)
LOG:  buffer pool resize: drain complete, waiting for barrier
LOG:  buffer pool resize completed in 3247 ms
```

### 15.2 Wait Events

New wait events:
- `BufferPoolResize` -- backend waiting during barrier processing
- `BufferPoolDrain` -- postmaster waiting for condemned buffers to drain

### 15.3 pg_stat_activity Integration

During resize, backends processing the barrier show:
```
wait_event_type = 'IPC'
wait_event = 'BufferPoolResize'
```

---

## 16. Testing Strategy

### 16.1 Unit Tests

- Grow from minimum (128kB) to 1GB in increments
- Shrink from 1GB to minimum
- Grow and shrink to same target (no-op)
- Exceed max_shared_buffers (must fail with clear error)
- Shrink below minimum (must fail)
- NBuffers boundary: test buffers at old_NBuffers-1 and new_NBuffers-1

### 16.2 Concurrency Tests (TAP Tests)

- Grow while pgbench is running
- Shrink while pgbench is running
- Grow while VACUUM is running (ring buffer interaction)
- Shrink while long-running SELECT holds pins on condemned buffers
- Grow while checkpoint is in progress
- Shrink while checkpoint is in progress
- Backend connects during resize
- Backend disconnects during resize
- Two concurrent resize requests (must serialize)

### 16.3 Crash Recovery Tests

- Kill postmaster during grow (between commit and NBuffers update)
- Kill postmaster during shrink (during drain)
- Kill postmaster during barrier propagation
- Kill individual backend during barrier processing
- OOM during grow (mmap fails)

### 16.4 Regression Tests

- `pg_buffercache` output before and after resize
- `EXPLAIN (BUFFERS)` output during resize
- `pg_stat_bgwriter` counters during resize
- Extension loading (`shared_preload_libraries`) with max_shared_buffers

### 16.5 Stress Tests

- Rapid grow/shrink cycles (every 5 seconds) under pgbench
- Grow to very large values (256GB) if hardware permits
- Shrink while all buffers are dirty
- 1000 concurrent backends, all active during resize

### 16.6 Platform Tests

- Linux x86_64 (primary)
- Linux aarch64
- FreeBSD
- macOS (development only)
- Windows (EXEC_BACKEND)
- With and without huge_pages = on

---

## 17. Migration and Compatibility

### 17.1 Default Behavior

When `max_shared_buffers = 0` (default), the system behaves identically to
current PostgreSQL:
- `shared_buffers` requires restart to change
- Buffer pool memory is allocated exactly as today
- No additional virtual address space reservation
- No performance overhead

Online resize is opt-in via setting `max_shared_buffers`.

### 17.2 Extension Compatibility

Extensions that access buffer internals must be updated:

| Extension | Impact | Required Change |
|---|---|---|
| `pg_buffercache` | Medium | Read NBuffers at scan start, not at load |
| `pg_prewarm` | Low | No change needed (calls existing buffer manager APIs) |
| `pg_stat_statements` | None | Doesn't access buffers directly |
| Custom bgworkers | Medium | Must handle `PROCSIGNAL_BARRIER_BUFFER_POOL_RESIZE` |

### 17.3 Upgrade Path

- pg_upgrade: No special handling (max_shared_buffers defaults to 0)
- Replication: No impact (shared_buffers is instance-local)
- Backup/restore: No impact

---

## 18. Phased Implementation Plan

### Phase 1: Foundation (Target: PostgreSQL 19)

**Goal:** Separate buffer pool memory from main shared memory segment.

1. Create `pg_shmem_resize.h` portability layer
2. Move buffer manager arrays to separate memory mapping
3. Add `max_shared_buffers` GUC (PGC_POSTMASTER)
4. Pre-size hash table for `max_shared_buffers` when set
5. Regression tests pass with no behavior change

**Validation:** All existing tests pass. No performance regression in pgbench.

### Phase 2: Online Grow (Target: PostgreSQL 19)

**Goal:** Allow increasing `shared_buffers` without restart.

1. Change `shared_buffers` context to PGC_SIGHUP (with max_shared_buffers guard)
2. Implement memory commit for new buffer chunks
3. Implement new descriptor initialization
4. Add `PROCSIGNAL_BARRIER_BUFFER_POOL_RESIZE` barrier type
5. Implement `NBuffers` update protocol
6. Add `pg_stat_buffer_pool_resize` view
7. Add TAP tests for online grow

**Validation:** Can double `shared_buffers` under pgbench load with < 100ms
interruption. No data corruption.

### Phase 3: Online Shrink (Target: PostgreSQL 20)

**Goal:** Allow decreasing `shared_buffers` without restart.

1. Implement drain protocol for condemned buffers
2. Add `BM_CONDEMNED` flag to buffer state
3. Implement cooperative buffer invalidation on unpin
4. Add memory decommit after drain
5. Handle SIGBUS prevention
6. Add timeout and cancellation for stuck drains
7. Add TAP tests for online shrink

**Validation:** Can halve `shared_buffers` under pgbench load. Dirty page
flushing completes within checkpoint_timeout. Pinned-buffer timeout works.

### Phase 4: Dynamic Hash Table (Target: PostgreSQL 20+)

**Goal:** Allow the buffer hash table to resize dynamically.

1. Remove `HASH_FIXED_SIZE` from `SharedBufHash`
2. Implement incremental rehashing across partitions
3. Remove the over-provisioning workaround from Phase 2
4. Benchmark to ensure no regression

### Phase 5: Observability and Polish (Ongoing)

1. Integrate with `pg_stat_io`
2. Add `log_buffer_pool_resize` GUC for detailed logging
3. Document in official PostgreSQL documentation
4. Write pg_buffercache extension updates
5. Consider auto-resize hooks (but NOT automatic tuning)

---

## 19. Open Questions

1. **Should shrink be interruptible?** If a DBA starts a shrink and realizes
   it was a mistake, can they cancel it by setting `shared_buffers` back up?
   (Proposed: yes, by detecting the new target during drain.)

2. **Chunk size configurability.** Should the unit of resize be configurable?
   MySQL uses 128MB chunks. We could default to 128MB but allow tuning for
   systems with very large or very small buffer pools.

3. **Memory overcommit.** On systems with `vm.overcommit_memory = 0` (heuristic),
   reserving virtual address space for `max_shared_buffers` may fail even though
   no physical memory is needed. Should we document this requirement, or detect
   it?

4. **Interaction with cgroups memory limits.** In containerized environments,
   growing the buffer pool may hit cgroup memory limits. Should we detect this
   proactively?

5. **WAL implications.** Does buffer pool resize create any WAL consistency
   issues? (Believed: no, because WAL replay operates on specific blocks, not
   buffer IDs. But needs careful analysis.)

6. **Relation to DSM registry work.** Can the DSM registry infrastructure
   (`GetNamedDSMSegment()`) be leveraged for the buffer pool mapping? Probably
   not -- the DSM registry is designed for extension-managed allocations that
   can be recreated, not for the core buffer pool which must be persistent and
   contiguous. But the DSM registry's patterns for safe cross-backend
   initialization are relevant to the coordination protocol.

7. **Future: online `max_connections` resize.** The same barrier infrastructure
   could be reused for online `max_connections` changes (another frequently
   requested feature). Should the coordination protocol be designed generically?

---

## 20. References

### PostgreSQL Source Code

- `src/backend/storage/buffer/buf_init.c` -- Buffer pool initialization
- `src/backend/storage/buffer/bufmgr.c` -- Buffer manager core
- `src/backend/storage/buffer/freelist.c` -- Clock sweep and strategy
- `src/backend/storage/buffer/buf_table.c` -- Buffer hash table
- `src/backend/storage/ipc/ipci.c` -- Shared memory setup
- `src/backend/storage/ipc/dsm_registry.c` -- DSM registry
- `src/backend/storage/ipc/procsignal.c` -- ProcSignalBarrier
- `src/backend/port/sysv_shmem.c` -- Shared memory allocation
- `src/include/storage/buf_internals.h` -- Buffer descriptor definitions

### PostgreSQL Mailing List

- Dmitry Dolgov, "Changing shared_buffers without restart" (October 2024)
  https://www.postgresql.org/message-id/cnthxg2eekacrejyeonuhiaezc7vd7o2uowlsbenxqfkjwgvwj@qgzu6eoqrglb
- Follow-up discussion with Robert Haas, Thomas Munro, Peter Eisentraut (2024-2025)
  https://www.postgresql.org/message-id/eqs6v4rsboazl67xz3wxc6xjkgrpfybitpl45y3lmb2br67wbj@o7czebb3rlgd

### Other Database Systems

- MySQL InnoDB online buffer pool resize (WL#6117):
  https://dev.mysql.com/doc/refman/8.4/en/innodb-buffer-pool-resize.html
- Oracle SGA dynamic resize:
  https://docs.oracle.com/en/database/oracle/oracle-database/19/tgdba/tuning-system-global-area.html
- SQL Server memory management:
  https://learn.microsoft.com/en-us/sql/relational-databases/memory-management-architecture-guide

### Academic Papers

- Storm et al., "Adaptive Self-Tuning Memory in DB2 (STMM)", VLDB 2006
- Tan et al., "iBTune: Individualized Buffer Tuning for Cloud Databases", VLDB 2019
- Leis et al., "Virtual-Memory Assisted Buffer Management (vmcache)", SIGMOD 2023
- "Evolution of Buffer Management in Database Systems", arXiv:2512.22995, December 2025
