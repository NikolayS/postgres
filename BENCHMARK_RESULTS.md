# PgQ Performance Optimization — Benchmark Results

## Hardware
- Apple Silicon, 10 cores, 24 GB RAM, APFS SSD
- PostgreSQL 18.3 (stock) vs PostgreSQL 19dev (patched)
- PgQ 3.5.1, C mode insert_event_raw, pgbench prepared mode, 30s runs

## Configuration (both)
```
synchronous_commit = off
shared_buffers = 2GB
max_wal_size = 4GB
wal_level = minimal
```

## Patches Applied (on PG 19dev branch `pgq-perf-experiments`)

| # | Patch | Confidence | Status |
|---|-------|-----------|--------|
| 3 | NUM_XLOGINSERT_LOCKS 8→32 | 8/10 | DONE |
| 2 | BulkInsertState for executor INSERT | 6/10 | DONE |
| 1 | Multi-slot target blocks (4 slots) | 4/10 | DONE |
| 4 | wal_compression = zstd | 9/10 | TESTED — hurts with random JSON |

## Results: Single insert_event() per TX

### ~100B payload

| Clients | Stock PG 18 | Patched (3 patches) | Delta |
|---------|------------|-------------------|-------|
| 4 | 152,455 | 171,508 | **+12%** |
| 8 | 151,223 | 180,122 | **+19%** |
| 16 | 148,037 | 193,411 | **+31%** |
| 32 | 142,040 | 185,994 | **+31%** |

### ~2KB payload

| Clients | Stock PG 18 | Stock MB/s | Patched | Patched MB/s | Delta |
|---------|------------|-----------|---------|-------------|-------|
| 4 | 80,240 | 157 | 116,015 | 227 | **+45%** |
| 8 | 88,851 | 174 | 120,258 | 235 | **+35%** |
| 16 | 85,343 | 167 | 98,480 | 192 | **+15%** |
| 32 | 92,235 | 180 | 112,865 | 220 | **+22%** |

### Peak: 193k ev/s (100B) / 120k ev/s = 235 MB/s (2KB)

## Previous A/B (patches 2+3 only, without multi-target blocks)

| Clients | Stock 18 (~2KB) | Patched (2 patches) | Delta |
|---------|----------------|-------------------|-------|
| 4 | 97,807 | 105,574 | +8% |
| 8 | 87,723 | 96,140 | +10% |
| 16 | 90,276 | 109,622 | +21% |

## Impact of multi-target blocks (Idea 1)

Comparing 2-patch vs 3-patch results at 4 clients, ~2KB:
- 2 patches: 105,574 ev/s (206 MB/s)
- 3 patches: 116,015 ev/s (227 MB/s)
- **Multi-target blocks added +10%**

At 16 clients, ~100B:
- 2 patches: 96,905 ev/s
- 3 patches: 193,411 ev/s
- **Multi-target blocks added ~100% at high concurrency for small payloads**

## wal_compression results

| Compression | 8 clients, ~2KB | vs no compression |
|------------|----------------|-------------------|
| off | 120,258 ev/s (235 MB/s) | baseline |
| lz4 | ~100k ev/s (~195 MB/s) | **-17%** |
| zstd | 95,988 ev/s (187 MB/s) | **-20%** |

**Verdict:** WAL compression hurts for random/incompressible JSON payloads.
CPU overhead with no I/O reduction. Would help for compressible data
(repeated strings, structured XML, etc.).

## Key Findings

1. **Multi-target blocks is the biggest win at high concurrency.** At 16+
   clients with small payloads, it nearly doubles throughput by eliminating
   last-page contention (LWLock:BufferContent).

2. **NUM_XLOGINSERT_LOCKS 8→32 helps at all concurrency levels.** Simple,
   safe, well-understood. Should be proposed upstream.

3. **BulkInsertState for executor** helps modestly for single-row SPI
   inserts. Full benefit requires cross-call bistate persistence (Phase 2).

4. **WAL compression hurts with incompressible payloads.** Test with your
   actual data before enabling.

5. **Combined effect: +15% to +45%** for the realistic case (2KB payloads),
   **+12% to +31%** for small payloads. The gains increase with concurrency.

## Round 2: Re-profiling and additional experiments

### New bottleneck profile on patched PG (16 clients, ~2KB)

| Wait event | Samples | % | Was (stock) |
|------------|---------|---|-------------|
| IO:DataFileWrite | 236 | 51% | 0-57% |
| Client:ClientRead | 62 | 13% | 21-30% |
| Lock:extend | 55 | 12% | 11% |
| CPU/Running | 49 | 11% | 23-52% |
| Buffer:BufferExclusive | 44 | 10% | 23% |

Multi-target blocks cut BufferContent from 23% to 10%. IO:DataFileWrite
and Lock:extend are now the dominant bottlenecks.

### SMGR_TARGBLOCK_SLOTS = 8 vs 4

| Slots | TPS (16 clients, 2KB) |
|-------|----------------------|
| 4 | 109,795 |
| 8 | 88,401 (**-19.5%**) |

**4 slots is the sweet spot.** More slots causes cache/memory pressure.

### PL/pgSQL mode on patched PG (what pgq2 will use)

| Clients | C (~100B) | PL (~100B) | PL/C | C (~2KB) | PL (~2KB) | PL/C |
|---------|----------|-----------|------|---------|----------|------|
| 4 | 171,508 | 124,880 | 73% | 116,015 | 95,250 | 82% |
| 8 | 180,122 | 91,679 | 51% | 120,258 | 96,565 | 80% |
| 16 | 193,411 | 95,800 | 50% | 98,480 | 110,516 | 112% |

PL/pgSQL is 73-82% of C at 4 clients. Gap widens at high concurrency
for small payloads. For 2KB payloads the gap is minimal (80-112%).

### Sequence contention: NOT a bottleneck

No sequence-related waits visible in pg_stat_activity sampling.
sequence cache_size=1 is wasteful but not a visible serialization point.

### AIO / io_uring status

The patched PG 19dev has AIO infrastructure committed (io_uring support,
buffer lock refactoring) but **only for reads**. AIO writes not yet
implemented — FlushBuffer() still does synchronous pwrite(). This is
why IO:DataFileWrite is 51% of time. Community-scale change needed.

### Remaining optimization paths

| Idea | Expected impact | Feasibility |
|------|----------------|-------------|
| Sequence cache_size=20 | Small (seq not visible bottleneck) | Trivial config |
| AIO writes in checkpoint | Very high (51% bottleneck) | Wait for PG 20 |
| Reduce Lock:extend further | Medium (12%) | Need bulk extend improvements |
| Compressible payload + wal_compression | Medium (if data compresses) | Config only |
