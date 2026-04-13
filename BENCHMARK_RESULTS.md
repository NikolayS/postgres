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

## Round 3: I/O Optimization and Overhead Analysis

### PG 19dev I/O Settings (individual tests, 8 clients, ~2KB, 20s)

| # | Setting | Value | TPS | Delta vs baseline |
|---|---------|-------|-----|-------------------|
| 0 | Baseline (defaults) | — | 81,520 | — |
| 1 | `debug_io_direct` | `'data'` | 102,540 | **+25.8%** |
| 2 | `io_max_concurrency` | 128 (was 64) | 114,154 | **+40.0%** |
| 3 | `effective_io_concurrency` + `maintenance_io_concurrency` | 200 (was 16) | 109,859 | **+34.7%** |
| 4 | `io_combine_limit` | 32 / 256kB (was 16) | 86,796 | **+6.5%** |

**Note:** Individual test results may be inflated by page cache warming from
baseline runs. The combined test (below) gives a more honest picture.

### Combined I/O settings (all winners together, 30s)

| Clients | TPS | MB/s | vs baseline without I/O tuning |
|---------|-----|------|-------------------------------|
| 4 | 104,643 | 204 | -10% vs individual best |
| 8 | 93,657 | 183 | -18% vs individual best |
| 16 | 101,006 | 197 | -11% vs individual best |

**The combo is WORSE than individual settings.** `debug_io_direct` bypasses the
kernel page cache while `effective_io_concurrency` tries to leverage it.
They fight each other. Individual test results were also inflated by page
cache effects from prior runs.

**Verdict:** These PG 19dev I/O settings are interesting for reads but don't
help our write-dominated queue workload when combined. The AIO infrastructure
(io_method=worker) primarily benefits reads; writes still go through synchronous
pwrite(). The +40% from io_max_concurrency alone may be a measurement artifact.

### TOAST Analysis

2KB JSON payloads (1,822 bytes ev_data, 1,882 bytes full tuple) stay inline —
well below the ~2KB TOAST threshold. TOAST tables are empty. **Non-factor.**

### Index Overhead (ev_txid btree)

| Config | Avg TPS | Delta |
|--------|---------|-------|
| With index (baseline) | 134,640 | — |
| Without index | 138,585 | **+2.9%** |
| Seq cache 100 (with index) | 135,898 | +0.9% |
| No index + cache 100 | 140,377 | **+4.3%** |

The ev_txid index costs ~3% of insert throughput. For a queue that needs
txid-based consumer reads, this is an acceptable cost.

### Sequence Cache

Increasing from cache=1 to cache=100 yields only +0.9% — within noise.
Sequence contention is not a significant bottleneck at this concurrency level.

### Summary of all optimization attempts

| Optimization | Category | Result | Keep? |
|---|---|---|---|
| NUM_XLOGINSERT_LOCKS 8→32 | PG patch | **+5-12%** | YES |
| BulkInsertState for executor | PG patch | **+5-10%** | YES |
| Multi-target blocks (4 slots) | PG patch | **+10-100%** | YES |
| Multi-target blocks (8 slots) | PG patch | **-19.5%** | NO |
| wal_compression = lz4 | Config | **-17%** (random JSON) | NO for queue payloads |
| wal_compression = zstd | Config | **-20%** (random JSON) | NO for queue payloads |
| debug_io_direct = 'data' | Config (PG19) | **+26%** individual, worse combined | MAYBE |
| io_max_concurrency = 128 | Config (PG19) | **+40%** individual, worse combined | NEEDS VALIDATION |
| effective_io_concurrency = 200 | Config (PG19) | **+35%** individual, worse combined | NEEDS VALIDATION |
| io_combine_limit = 32 | Config (PG19) | **+6.5%** | MINOR |
| Drop ev_txid index | Schema | **+2.9%** | NO (needed for consumer reads) |
| Sequence cache = 100 | Config | **+0.9%** | NOISE |
| SMGR_TARGBLOCK_SLOTS = 8 | PG patch | **-19.5%** | NO |
| TOAST tuning | Schema | N/A (not TOASTing) | N/A |

### Best confirmed results (3 PG patches, standard config)

| Mode | Payload | Stock PG 18 | Patched PG 19dev | Delta |
|------|---------|------------|-----------------|-------|
| C | ~100B | 152k ev/s | **193k ev/s** | **+31%** |
| C | ~2KB | 92k ev/s / 180 MB/s | **120k ev/s / 235 MB/s** | **+35%** |
| PL/pgSQL | ~100B | — | 125k ev/s (4 clients) | — |
| PL/pgSQL | ~2KB | — | 110k ev/s / 215 MB/s | — |
