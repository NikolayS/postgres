# Logical Decoding from Archived WAL — SPEC

**Version:** 0.2  
**Status:** Draft — post first-round review  
**Date:** 2026-04-16  
**Author:** @NikolayS (Nik Samokhvalov)  
**Contributors:**  
- @x4m (Andrey Borodin) — main idea generator; architecture ideas from Postgres.tv hacking session  
- @kirkw (Kirk Wolak) — contributor

---

## Changelog

| Version | Date       | Author    | Changes |
|---------|------------|-----------|---------|
| 0.1     | 2026-04-15 | @NikolayS (Nik Samokhvalov) | Initial draft. Consolidated ideas from @x4m hacking session + research on PG community history (Craig Ringer 2020, Kukushkin 2025 revival, PG16–19 infrastructure). Three-phase PoC plan. |
| 0.2     | 2026-04-16 | @NikolayS (Nik Samokhvalov) | Address three independent technical reviews. Corrections: (a) `hot_standby_feedback = on` is **not** required on an archive-only standby — it's a standby→primary mechanism and is a silent no-op without a walreceiver; (b) `pg_wal_replay_resume()` does **not** promote a `standby.signal` standby with no `recovery_target*` — the original framing was wrong; (c) the slot only decodes WAL **generated after slot creation** (fundamental `snapbuild` constraint) — US-2 rewritten accordingly; (d) `recovery_target_function` reframed from a semi-designed plpgsql API to "slot-aware replay throttling, mechanism TBD" after @reviewer-3 flagged infeasibility (performance, startup-process execution context, in-flight relmap); (e) Ringer/Kukushkin walsender patch clarified — it solves a complementary problem (walsender fetching archived segments for an existing consumer), not foundational to this PoC. Structural: Sprint 0 redefined as 4 gates (slot create → decode post-creation WAL → survive replay progress → survive restart/resume) budgeted at 2 weeks; slot invalidation elevated to project-level risk; US-4 step-replay marked experimental (the `sleep(0.1)` loop gives batch granularity, not per-record); added test matrix items (streaming large txns, 2PC, subtxn overflow, replica identity variants, TOAST pglz+lz4 mix, restart mid-decode, PG18 sequences); increased S2-2 DDL budget; tightened managed-service positioning from "why needed now" to "strategic upside if providers cooperate"; SQL output caveats in §4.3.1. |

---

## 1. Goal

**One-liner:** Produce a logical change stream (JSON / SQL / pgoutput protocol) from archived WAL files — without maintaining a replication slot on the production primary and without impacting production at all.

### Why it's needed

Logical replication in PostgreSQL today has a fundamental coupling problem: the logical replication slot lives on the primary (or, since PG16, on a standby that streams from the primary). This creates three categories of pain:

1. **Production risk.** A stalled logical consumer causes WAL retention to grow unboundedly on the primary — or, if `max_slot_wal_keep_size` is set, the slot gets invalidated and the entire replication pipeline breaks. Either outcome is operationally dangerous.

2. **No backward reach.** You can only start consuming from slot-creation time onward. There is no "logical point-in-time recovery" — you cannot say "give me all logical changes from last Tuesday." Physical PITR exists; logical PITR does not.

3. **Managed-service lock-in (strategic upside, not near-term).** Most managed PostgreSQL providers (RDS, Cloud SQL, AlloyDB) don't expose WAL archives or superuser access today. *If* a provider chose to expose WAL archives plus a suitable base backup, this approach would let them offer a filtered/sanitized logical stream without granting superuser. That is a cooperation question, not a technical one — listed here as aspirational, not as an assumption the PoC relies on.

### What exists today and why it's not enough

- **PG16** added logical decoding on standbys — a standby replaying WAL can host logical slots. This is the closest existing mechanism. But it requires a live standby streaming from the primary, which still couples the consumer to the primary's WAL retention.
- **PG17** added failover slots and slot synchronization.
- **PG18** added `pg_logicalinspect` — visibility into serialized logical snapshot state.
- **PG19** adds dynamic `wal_level` and `pg_waldump` reading from tar archives.
- **Craig Ringer's 2020 proposal** to teach xlogreader's page-read callback to invoke `restore_command` when segments are missing from `pg_wal` remains unimplemented but was revived on pgsql-hackers in July 2025 by Alexander Kukushkin.
- **No external tool** (wal2json, Debezium, pglogical, pg_waldump, WAL-G's walparser) can perform logical decoding offline. Every one requires a running PostgreSQL server.

### The fundamental barrier

WAL records reference relations by `RelFileLocator` (physical file identity), not by name. Decoding `INSERT INTO users (name, email) VALUES (...)` from a heap-insert WAL record requires live catalog lookups against `pg_class`, `pg_attribute`, and `pg_type` via shared buffers, relcache, and syscache. The `snapbuild.c` machinery constructs historic MVCC snapshots for catalog reads, but the actual catalog heap pages must be physically present and readable. WAL is differential — it contains changes to catalog tables, not their full contents. Reconstructing catalog state from WAL alone requires a base state plus every subsequent WAL record applied in order.

**This is, functionally, what a physical standby does.** Our PoC embraces that fact rather than fighting it.

---

## 2. User Stories

### US-1: Decouple logical replication from primary

> **As** a DBA operating a high-traffic OLTP PostgreSQL cluster,  
> **I want** to consume logical changes from WAL archives stored in S3  
> **so that** my primary never has to retain extra WAL for logical consumers, and a stalled consumer cannot cause WAL bloat on production.

**Acceptance criteria:**
- A physical standby is provisioned from a base backup and replays WAL via `restore_command` pointing at an S3 archive.
- A logical replication slot is created on this standby.
- Changes from the archive appear in `pg_logical_slot_peek_changes()`.
- The primary has zero logical slots and zero awareness of this consumer.
- Manual verification: insert 1000 rows on primary, wait for WAL archival, confirm all 1000 appear in logical output on the archive-fed standby.

### US-2: Logical point-in-time recovery

> **As** a developer who accidentally deleted production data at 14:32 UTC,  
> **I want** to logically decode archived WAL between 14:00 and 14:31  
> **so that** I can extract the exact DML needed to restore the deleted rows — without restoring a full physical cluster to that point.

**Fundamental constraint (added in v0.2):** a logical slot can only decode WAL **generated after the slot was created** — `snapbuild` assembles the historic catalog snapshot starting from the slot-creation LSN; earlier WAL cannot be replayed through the slot. That means US-2 cannot be served by "restore to 14:35 then decode backwards." The correct recipe:

1. Restore the base backup to a point **before** the earliest WAL you want to decode (e.g., 13:59 UTC).
2. Start recovery with `recovery_target_time = '14:00 UTC'` (or preferably `recovery_target_lsn = <LSN>` — `recovery_target_time` is imprecise; it pauses at the first commit *after* the target) and `recovery_target_action = 'pause'`.
3. Wait for the standby to pause. Create the logical slot.
4. Clear the target (or set a new one at 14:31) and resume. Consume changes as they decode.

**Acceptance criteria:**
- Follow the 4-step procedure above, using a purpose-chosen base backup predating the decode window.
- Output for UPDATE/DELETE requires the affected tables have adequate `REPLICA IDENTITY` (DEFAULT with PK, FULL, or USING INDEX). This is a consumer-side caveat, not a tool limitation: on tables without replica identity coverage, UPDATE/DELETE will decode without old-tuple information.
- Output uses `pgoutput` or a production-grade plugin — **not** `test_decoding`, which has no stability guarantees. The `sql` consumer mode emits SQL *best-effort* and is only safe when plugin + replica identity allow deterministic reconstruction.
- Manual verification: create a table with a primary key, insert rows, delete them, archive WAL. Restore per the recipe — confirm deleted rows appear in logical output as `DELETE` operations with primary-key identification.

### US-3: PII-free staging via filtered logical replay

> **As** a platform engineer,  
> **I want** to replicate production data to a staging environment with PII stripped  
> **so that** developers have realistic data without compliance risk.

**Acceptance criteria:**
- Logical changes consumed from the archive-fed standby pass through a filter that masks PII columns (e.g., `email`, `phone`).
- The target staging database receives the masked data via logical apply.
- Manual verification: insert row with `email='secret@example.com'` on production. Confirm staging receives `email='***@***.com'` or equivalent.

### US-4: WAL correctness verification (step-by-step replay) — **EXPERIMENTAL**

> **As** a PostgreSQL core developer,  
> **I want** to replay WAL in small controlled batches and run consistency checks between them  
> **so that** I can detect bugs where the cluster ends up in an inconsistent state after a burst of replay.

**Honesty note (v0.2):** true per-record stepping is **not** achievable from user space. `pg_wal_replay_pause()` / `pg_wal_replay_resume()` with a `sleep(N)` between them gives a time-bounded *batch* of replay, not a single record — the startup process may apply 1 or 10,000 records depending on how busy it is during that window. Calling this "step-by-step" is inaccurate and was removed. The coarser "pause → consume → resume" loop is still useful as a debugging aid but is an approximation of the real ask. Real per-record determinism would require a core patch (see §4.2.3); until then, US-4 is **experimental** and should not gate the PoC.

**Acceptance criteria (experimental):**
- Orchestration script runs a pause → resume-for-N-ms → pause → check loop. Reports replay LSN before/after each iteration and which WAL records were applied in between (via `pg_get_wal_stats()` / walinspect or `pg_waldump`).
- If a consistency check fails (e.g., `amcheck`), report the LSN range rather than the exact record — the exact-record-pinpoint claim from v0.1 was overstated.
- Manual verification: replay a known WAL sequence in small batches, run checks after each — confirm the loop completes without false alarms.

---

## 3. Architecture

### 3.1 High-level design

```
┌──────────────┐
│  Production   │
│  Primary      │──archive_command──▶ [WAL Archive (S3/local)]
│  (untouched)  │                              │
└──────────────┘                               │
                                               │ restore_command
                                               ▼
                                    ┌─────────────────────┐
                                    │  Decoder Standby     │
                                    │  (physical standby   │
                                    │   replaying from     │
                                    │   archive only)      │
                                    │                      │
                                    │  ┌────────────────┐  │
                                    │  │ Logical Slot   │  │
                                    │  │ (pgoutput /    │  │
                                    │  │  test_decoding)│  │
                                    │  └───────┬────────┘  │
                                    └──────────┼───────────┘
                                               │
                                               ▼
                                    ┌─────────────────────┐
                                    │  Consumer            │
                                    │  (Python/Go script)  │
                                    │                      │
                                    │  → JSON files        │
                                    │  → Target PG         │
                                    │  → Kafka             │
                                    │  → Filtered replay   │
                                    └─────────────────────┘
```

### 3.2 Key architectural decision: standby-as-decoder

We do NOT attempt to build a standalone offline WAL decoder. The research is conclusive: that path requires embedding a minimal PostgreSQL catalog engine with MVCC, CLOG, relcache, syscache, TOAST, and type I/O. It is a multi-year effort suitable for PG21+ at earliest.

Instead, we use what PG16 already provides: **a physical standby replaying WAL supports logical slot creation and decoding.** The insight from @x4m is that this standby doesn't need to stream from the primary — it can replay from archive via `restore_command`. Production has zero coupling to this process.

This is **Path 2** from the community research ("PITR-based logical decoding / restore and decode"), operationalized as a tool.

### 3.3 Components

| Component | Language | Description |
|-----------|----------|-------------|
| `pg-wal-logical-decode` (CLI) | Bash + Python | Orchestrator: provisions standby from backup, configures recovery, creates slot, streams changes, tears down. |
| Decoder Standby | PostgreSQL 16+ | Standard PG instance in recovery mode with `standby.signal`, `restore_command`, `hot_standby = on`. |
| Consumer library | Python (psycopg2/3) | Connects to standby's logical slot via streaming replication protocol. Applies filters, emits output. |
| Batched-replay controller (US-4, experimental) | Python | Pauses/resumes replay in time-bounded batches, runs checks between batches. Not per-record — see US-4 note. |

### 3.4 Constraints and limitations (PoC scope)

- **Requires PG16+** (logical decoding on standby).
- **Requires `wal_level = logical`** on the primary at the time the WAL was generated. PG19's dynamic `wal_level` helps but cannot retroactively decode `replica`-level WAL.
- **Slot only decodes post-creation WAL (fundamental).** A logical slot's `catalog_xmin` horizon is established at slot-creation time; `snapbuild` assembles the historic catalog snapshot going forward from there. You cannot create a slot at time T and decode WAL from T−1hr. To decode a past window, the standby must be rewound (via `recovery_target`) to before that window, the slot created at the rewound position, then replay resumed forward. This is not a quirk — it is how `snapbuild` works. US-2 reflects this.
- **DDL during decode window:** PoC Phase 1 assumes no DDL. Phase 2+ relies on the standby's physical replay applying catalog changes naturally — the logical decoder on the standby sees updated catalogs automatically. **Caveat:** decoder-side correctness (catalogs update) is separate from consumer-side schema evolution (downstream output format changes). Rewriting DDL (`ALTER TABLE ... TYPE`, `VACUUM FULL`, `CLUSTER`) interacts with historic catalog snapshots in ways that have had core patches shipped as recently as PG17; treat these as high-risk test cases.
- **Base backup required:** You need a base backup taken before the earliest WAL you want to decode. This is standard for any PITR scenario.
- **`hot_standby_feedback` is a no-op here — removed as a requirement.** It is a standby→primary mechanism that operates through the walreceiver connection. On a `restore_command`-only standby there is no walreceiver, so the setting is silently inert. What actually keeps a logical slot's needed catalog tuples alive is the slot's own `catalog_xmin`, enforced by the startup process during replay — nothing else.
- **Slot invalidation is a project-level risk, not a Phase 2 hardening task.** The moment a logical slot exists, its `catalog_xmin` horizon is pinned. If subsequently-replayed WAL represents "the primary vacuumed catalog tuples whose xmax ≥ slot.catalog_xmin," replay on the standby invalidates the slot (this is conflict resolution, not query cancellation — there is no `hot_standby_feedback` channel back to the primary to hold vacuum off). Whether this can be survived in practice, under what workloads, with what mitigations, is **one of the four Sprint 0 gates** (see §7). If this fails consistently, the PoC remains useful for narrow forensic windows but not as a reusable replication tool.

---

## 4. Implementation Details

### 4.1 Phase 1 — Prove the Pipe (MVP)

**Goal:** Confirm that a physical standby replaying WAL from archive (not streaming) can host a logical slot and produce decoded changes.

**Nobody has publicly verified this works.** The @x4m session concluded with "somebody needs to try it." This is the single highest-value experiment.

#### 4.1.1 Standby provisioning

```bash
# 1. Take base backup from source (PG16+, wal_level=logical)
pg_basebackup -h $PRIMARY -D /tmp/decoder_standby -Fp -Xs -P

# 2. Configure standby
cat >> /tmp/decoder_standby/postgresql.conf << 'EOF'
hot_standby = on               # required — enables read-only connections to query / consume the slot
# NOTE: hot_standby_feedback deliberately omitted. It is a standby→primary
#   channel that requires a walreceiver connection; on a restore_command-only
#   standby there is no walreceiver, so it would be a silent no-op. What
#   actually protects the slot's needed catalog tuples from vacuum is the
#   slot's own catalog_xmin, enforced during replay.
max_wal_senders = 5
wal_level = logical

# Fetch WAL from archive — this is the key
restore_command = 'cp /path/to/wal_archive/%f %p'
# For S3: restore_command = 'wal-g wal-fetch %f %p'

# IMPORTANT: do NOT set recovery_target* for continuous-decode mode.
# For US-2 (logical PITR) a target is set transiently to pause before the
# decode window so the slot can be created; see §4.2 for the correct recipe.
EOF

# 3. Signal standby mode
touch /tmp/decoder_standby/standby.signal

# 4. Start
pg_ctl -D /tmp/decoder_standby start
```

#### 4.1.2 Slot creation and consumption

```sql
-- Wait for hot standby to be available, then:

-- Create logical slot
SELECT pg_create_logical_replication_slot(
    'archive_decoder',
    'test_decoding'  -- simplest output plugin for PoC
);

-- Peek at changes (non-destructive)
SELECT * FROM pg_logical_slot_peek_changes('archive_decoder', NULL, NULL);

-- Or consume (advances slot position)
SELECT * FROM pg_logical_slot_get_changes('archive_decoder', NULL, NULL);
```

#### 4.1.3 What to verify (the four Sprint 0 gates)

Slot-creation alone is not sufficient evidence that the approach works. Sprint 0 must answer all four:

| Gate | Check | Expected | Notes |
|------|-------|----------|-------|
| G1 | `pg_create_logical_replication_slot()` succeeds on an archive-only standby | Should work | Requires `snapbuild` to reach `SNAPBUILD_CONSISTENT`, which requires an `XLOG_RUNNING_XACTS` record plus completion of all xacts listed as running. Primary's bgwriter logs one every ~15s via `LogStandbySnapshot()`, and those records are in the archive. `pg_log_standby_snapshot()` only speeds this up; it is not strictly required. On a quiet system, slot creation can hang for minutes waiting for running xacts to drain — include a dummy write loop on the primary during S0 testing. |
| G2 | Slot decodes WAL **generated after slot creation** (not just already-replayed WAL) | Unknown — critical | Do inserts on primary AFTER standby is set up and the slot exists, wait for archival, confirm they decode. The "decode historic WAL" reading of v0.1 was wrong; see §3.4 constraint. |
| G3 | Slot survives continued WAL replay without immediate invalidation | Unknown | Once the slot exists its `catalog_xmin` horizon is pinned. If replay hits vacuum-of-catalog records past that horizon, the slot is invalidated. Mitigation unclear without deeper instrumentation. |
| G4 | Slot survives restart / pause / resume cycles | Unknown | Kill the standby, restart, verify slot state is sane, no duplicates or gaps on next consume. |

**If G1 works but G2–G4 fail, the PoC scope changes materially** — the tool becomes a forensic-window decoder, not a continuous-replication substrate. That is still useful (US-2 alone is a paying market), but it should be a scope decision made with data, not an assumption.

#### 4.1.4 Known risks and mitigations

1. **Slot creation may stall waiting for `SNAPBUILD_CONSISTENT`.** On a quiet primary, several minutes can pass before a fresh `XLOG_RUNNING_XACTS` record plus all its running xacts have drained. Mitigation: during S0, run a lightweight insert loop on the primary with periodic `pg_switch_wal()`. `pg_log_standby_snapshot()` can help but is not strictly required. The orchestrator should catch `ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE` and retry.

2. **`catalog_xmin` horizon conflicts invalidate the slot (project-level risk — see §3.4).** There is no `hot_standby_feedback` shield here; the primary has already vacuumed, the WAL record exists, replay will hit it. The only knob we have on the standby side is *when* we apply that WAL — i.e., throttled replay. Whether that's enough in practice is a Sprint 0 gate.

3. **Archive gaps / missing segments.** `restore_command` failure mid-decode will stall recovery. The standby will keep retrying. The orchestrator needs to detect this (replay LSN not advancing while consumer is waiting) and surface it clearly rather than hanging.

### 4.2 Phase 2 — Controlled Replay

**Goal:** Mitigate slot invalidation via coarse-grained pause/consume/resume control, and provide a batched-replay + consistency-check loop as an experimental aid for US-4. (True per-record stepping is not achievable from user space — see US-4 note and §4.2.3.)

#### 4.2.1 External orchestration (no core patch needed)

```python
#!/usr/bin/env python3
"""
Controlled replay: pause → consume → resume → pause cycle.
"""
import psycopg2
import time

STANDBY_DSN = "host=/tmp dbname=mydb"

def get_replay_lsn(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT pg_last_wal_replay_lsn()")
        return cur.fetchone()[0]

def pause_replay(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT pg_wal_replay_pause()")

def resume_replay(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT pg_wal_replay_resume()")

def consume_slot(conn, slot_name='archive_decoder'):
    with conn.cursor() as cur:
        cur.execute("""
            SELECT lsn, xid, data
            FROM pg_logical_slot_get_changes(%s, NULL, NULL)
        """, (slot_name,))
        return cur.fetchall()

def run_checks(conn):
    """Run consistency checks — e.g., amcheck, row counts, etc."""
    with conn.cursor() as cur:
        # Example: verify no corrupted indexes
        cur.execute("""
            SELECT bt_index_check(c.oid)
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid
            WHERE c.relam = 403  -- btree
            LIMIT 10
        """)
    return True

def main():
    conn = psycopg2.connect(STANDBY_DSN)
    conn.autocommit = True

    pause_replay(conn)

    while True:
        lsn_before = get_replay_lsn(conn)

        # Consume available logical changes
        changes = consume_slot(conn)
        for lsn, xid, data in changes:
            print(f"LSN={lsn} XID={xid}: {data}")

        # Resume replay briefly to apply more WAL
        resume_replay(conn)
        time.sleep(0.1)  # let some records replay
        pause_replay(conn)

        lsn_after = get_replay_lsn(conn)
        if lsn_after == lsn_before:
            print("No more WAL to replay. Done.")
            break

        # Run consistency checks
        if not run_checks(conn):
            print(f"INCONSISTENCY DETECTED at LSN {lsn_after}")
            break

if __name__ == '__main__':
    main()
```

#### 4.2.2 Risks with resume (corrected in v0.2)

**Previous version of this doc was wrong:** `pg_wal_replay_resume()` does **not** promote a standby running with `standby.signal` and no `recovery_target*`. Such a standby will never auto-promote on its own — if it runs out of WAL in the archive it will keep retrying `restore_command` and sleep. `pg_wal_replay_resume()` simply clears the paused state; it does not change recovery mode or trigger promotion. Promotion in this environment requires one of: explicit `pg_promote()`, a promote trigger file, or hitting a configured `recovery_target_*` with `recovery_target_action = 'promote'`.

**Real risks to watch:**

- **If the operator sets a `recovery_target_*` (for US-2),** then after hitting the target `pg_wal_replay_resume()` will continue past it; depending on `recovery_target_action` that may eventually promote. Rule: for US-2, use `recovery_target_action = 'pause'` (never `'promote'`), and once the slot is created and you resume, clear the target or rely on the absence of further targets to keep the standby following indefinitely.
- **Use `standby.signal`, never `recovery.signal`** (the latter signals archive-recovery ending at a target; the former signals indefinite standby mode).
- **Replay granularity is coarse.** The pause/resume cycle with `sleep(N)` does not give per-record control (see US-4 note). If the resumed window contains a catalog-invalidating record, the slot dies before you can consume. This is why "slot-aware replay throttling" matters as a future feature (§4.2.3).
- **Sanity check after resume:** `pg_is_in_recovery()` should remain `true` — if it ever returns `false`, something (a misconfigured target, an operator command) triggered promotion.

#### 4.2.3 Future: slot-aware replay throttling (mechanism TBD — core patch territory)

**Revised in v0.2 after feasibility pushback.**

The *need* is concrete: we want the startup process to be able to pause replay before applying a WAL record that would invalidate an existing logical slot's `catalog_xmin`. The PoC provides a coarse approximation via user-space pause/resume, but that loop cannot see the next record about to be applied — by the time we pause, damage may already be done.

A v0.1 of this doc proposed a user-defined plpgsql function (`recovery_target_function`) invoked by the startup process per-record. That proposal has serious feasibility problems:

1. **Performance.** Startup replays WAL at hundreds of MB/s on well-configured systems — commonly >100k records/sec. A plpgsql callback per record is not a 2× slowdown; it's orders of magnitude. Even a C hook would be painful.
2. **Execution context.** The startup process is not a normal backend. It cannot invoke plpgsql in the usual sense — there is no SPI context available during redo, shared catalog state is mid-flight (being mutated by the very record you would be asking a question about), and invoking a function requires transaction infrastructure the startup process doesn't have. This is why `recovery_min_apply_delay` works by sleeping, not by calling user code.
3. **Argument availability.** `is_catalog` cannot be cheaply derived — it requires resolving `RelFileLocator` against a relmap, which requires the relmap to be current, which is precisely the kind of state being mutated mid-replay.

**Reframed as a need, not a design:**

> We need *some* form of slot-aware replay throttling in the startup process. The user-facing knob should probably be declarative (a mode like "pause if next record would conflict with any active logical slot's catalog_xmin horizon"), driven by data the startup process already has, not by user code.

Concrete shapes worth exploring (not commitments):

- A built-in `recovery_pause_on_logical_conflict` GUC that checks active slot horizons before applying WAL records tagged as vacuum-on-catalog.
- Per-record classification flags emitted at `XLogInsert` time so startup doesn't pay relmap-resolution costs during redo.
- A C-level hook (not plpgsql) gated behind a debug/extension interface, for research use only.

This belongs on pgsql-hackers as a problem statement after the PoC demonstrates the need empirically. **Do not depend on this feature in the PoC plan.**

### 4.3 Phase 3 — Consumer Pipeline

**Goal:** A reusable consumer that connects to the standby's logical slot and produces filtered, transformed output.

#### 4.3.1 Consumer modes

| Mode | Output | Use case | Caveat |
|------|--------|----------|--------|
| `json` | JSONL file, one line per change | Audit trail, analytics ingest | — |
| `sql` | SQL statements (INSERT/UPDATE/DELETE) | Logical PITR, migration | **Best-effort.** UPDATE/DELETE reconstruction requires the source table to have `REPLICA IDENTITY DEFAULT` (with a PK), `FULL`, or `USING INDEX`. On tables without adequate replica identity, old tuples are not present in WAL, so reconstructed UPDATE/DELETE will have no `WHERE` that identifies the row. The consumer must detect and flag this — silently emitting incomplete SQL is not safe. Plugin choice matters: use `pgoutput` (protocol version pinned) or a purpose-built plugin. `test_decoding` is for proving the pipe, not for production semantics. |
| `replay` | Apply to target PostgreSQL | PII-free staging, cross-version replication | Requires target table schemas to match (or a schema-evolution strategy). |
| `kafka` | Kafka producer | CDC pipeline | — |

**Plugin policy.** PoC uses `test_decoding` for the Sprint 0 "does the pipe work" gate. All production consumer modes target `pgoutput` with a pinned protocol version. `test_decoding` is a testing tool with no stability guarantees and must not end up in the shipped tool's default path.

**Interface policy.** Consumer connects via the streaming replication protocol for `json`/`replay`/`kafka` modes (proper flush positions, keepalives). The `sql` mode is fine over a regular SQL connection using `pg_logical_slot_get_changes()`. Don't mix: `pg_logical_slot_peek_changes()` does **not** advance the slot but **does** decode — using peek in a hot loop is a backend CPU trap and confuses `confirmed_flush_lsn` bookkeeping.

#### 4.3.2 PII filtering

Filtering happens in the consumer, not in PostgreSQL. The consumer receives full logical changes from the slot and applies column-level transformations before emitting output.

```yaml
# filter-config.yaml
filters:
  - table: public.users
    columns:
      email: mask_email     # secret@example.com → s***@e***.com
      phone: redact         # → [REDACTED]
      name: fake            # → generated fake name
  - table: public.payments
    columns:
      card_number: hash     # → SHA-256 hash (preserves join-ability)
```

### 4.4 CLI tool design

```
pg-wal-logical-decode \
    --backup-path /backups/base_20260415 \
    --wal-archive /wal_archive/ \
    --output-format json \
    --output-file changes.jsonl \
    --from-time "2026-04-15 14:00:00 UTC" \
    --to-time "2026-04-15 14:31:00 UTC" \
    --filter-config filter.yaml \
    --pg-port 15432 \
    --cleanup  # remove standby after completion
```

Under the hood this:
1. Copies backup to temp directory.
2. Configures `restore_command`, `standby.signal`, `hot_standby = on` (no `hot_standby_feedback` — see §3.4 / §4.1.1 notes).
3. For US-2 (PITR): sets `recovery_target_lsn` or `_time` + `recovery_target_action = 'pause'` to land the standby before the decode window.
4. Starts PostgreSQL on `--pg-port`.
5. Waits for hot standby.
6. Creates logical slot at the paused position.
7. Clears the target (or sets a new end-of-window target) and resumes replay.
8. Runs the consume loop (and pause/resume throttling if needed).
9. Applies filters, writes output.
10. Tears down standby (if `--cleanup`).

---

## 5. Testing Strategy

### 5.1 Red/Green TDD — where and how

We use TDD for the orchestrator and consumer logic. The WAL decode verification is integration-tested against real PostgreSQL.

| Component | TDD? | Framework | Notes |
|-----------|------|-----------|-------|
| Consumer: PII filter transformations | **Yes — strict TDD** | pytest | Pure functions: input tuple → output tuple. Red/green for each masking strategy. |
| Consumer: output formatters (JSON, SQL) | **Yes — strict TDD** | pytest | Input: decoded change dict. Output: formatted string. |
| CLI argument parsing & config | **Yes — TDD** | pytest | Validate all flag combinations, error cases. |
| Orchestrator: standby lifecycle | Integration tests | pytest + Docker | Spins up primary + standby in containers. Not TDD — too slow for red/green cycles. |
| Core verification: "does the pipe work" | Integration tests | TAP / pg_regress style | The Phase 1 experiment, automated. |
| Batched-replay controller (experimental) | Integration tests | pytest + Docker | Verify pause/resume/consume cycle holds across multiple iterations. |
| Slot invalidation scenarios | Integration tests | pytest + Docker | DDL on primary, verify standby behavior. |

### 5.2 CI test matrix

```yaml
# Conceptual CI structure
test-matrix:
  postgres-versions: [16, 17, 18]
  scenarios:
    - name: basic-decode
      desc: "Insert rows on primary, archive WAL, decode on standby"
      steps:
        - start primary (wal_level=logical, archive_mode=on)
        - create table, insert 100 rows
        - force WAL switch + archive
        - provision standby from backup with restore_command
        - create logical slot on standby
        - consume and verify all 100 rows appear
      pass: all 100 rows decoded correctly

    - name: multi-type-decode
      desc: "INSERT, UPDATE, DELETE across multiple tables"
      steps:
        - create 3 tables with varied column types (int, text, jsonb, timestamp, bytea, numeric)
        - perform mixed DML
        - archive and decode
      pass: all operations correctly decoded with proper types

    - name: ddl-during-replay
      desc: "ALTER TABLE ADD COLUMN between inserts"
      steps:
        - insert rows, ALTER TABLE ADD COLUMN, insert more rows
        - archive and decode
      pass: pre-DDL and post-DDL rows both decode correctly (different column sets)

    - name: slot-invalidation-handling
      desc: "Consumer falls behind, catalog changes invalidate slot"
      steps:
        - create slot, let replay advance past catalog changes without consuming
        - verify slot status
      pass: detect invalidation gracefully, report error, suggest re-provisioning

    - name: toast-decode
      desc: "Large values stored via TOAST"
      steps:
        - insert rows with >2KB text values
        - archive and decode
      pass: full values reconstructed (not truncated)

    - name: resume-no-promote
      desc: "Verify pg_wal_replay_resume() does not promote standby"
      steps:
        - pause, resume, check pg_is_in_recovery()
      pass: remains in recovery after 10 pause/resume cycles

    - name: concurrent-transactions
      desc: "Multiple concurrent writers, verify ordering"
      steps:
        - 5 concurrent sessions inserting to same table
        - archive and decode
      pass: all rows present, commit ordering preserved

    # --- Added in v0.2 after reviewer feedback ---

    - name: streaming-large-txn
      desc: "Txn exceeds logical_decoding_work_mem — STREAM START/COMMIT path (PG14+)"
      steps:
        - set logical_decoding_work_mem to a small value (e.g., 64kB)
        - one large txn with tens of thousands of rows
        - archive and decode via pgoutput with streaming=on
      pass: streamed changes assemble into correct final state; no data loss

    - name: two-phase-commit
      desc: "PREPARE TRANSACTION + COMMIT PREPARED decode path"
      steps:
        - BEGIN; ... ; PREPARE TRANSACTION 'txn1'
        - later: COMMIT PREPARED 'txn1'
        - archive and decode
      pass: prepared and committed phases both appear correctly

    - name: subtransaction-overflow
      desc: "Function with >64 savepoints crosses PGPROC_MAX_CACHED_SUBXIDS"
      steps:
        - execute a function doing 70+ savepoints with interleaved inserts
        - archive and decode
      pass: all rows decoded with correct xid association

    - name: replica-identity-variants
      desc: "UPDATE/DELETE on tables with DEFAULT (with PK), FULL, USING INDEX, and NOTHING"
      steps:
        - 4 tables with each replica identity setting
        - UPDATE and DELETE rows on each
        - archive and decode
      pass: DEFAULT/FULL/USING INDEX produce usable old-tuple info; NOTHING is explicitly flagged as non-reconstructable (consumer must not silently emit broken SQL)

    - name: toast-compression-mix
      desc: "TOAST values with mix of pglz and lz4 compression (PG14+)"
      steps:
        - insert large text values with default compression = pglz
        - ALTER TABLE ... SET (toast_tuple_target, compression = 'lz4')
        - insert more large values
        - archive and decode
      pass: both compression algorithms decompress correctly

    - name: restart-mid-decode
      desc: "Kill and restart standby while slot is actively being consumed"
      steps:
        - start consuming, SIGKILL standby partway through
        - restart standby
        - resume consumption
      pass: slot state is sane; no duplicates past confirmed_flush_lsn; no gaps before it

    - name: sequence-replication
      desc: "PG18 logical replication of sequences"
      steps:
        - create sequence, call nextval() many times on primary
        - archive and decode (PG18 only)
      pass: sequence changes decoded (behavior documented, decoded or skipped, but not silently wrong)

    - name: rewriting-ddl
      desc: "ALTER TABLE ... TYPE, VACUUM FULL, CLUSTER — historic catalog snapshot stress"
      steps:
        - mix inserts with ALTER TABLE ... ALTER COLUMN TYPE
        - mix inserts with VACUUM FULL / CLUSTER
        - archive and decode
      pass: no snapbuild errors; pre- and post-rewrite rows decode correctly with their respective column sets
```

### 5.3 Manual test protocol (for US verification)

Each user story has a corresponding manual test runbook. These are also automated in CI but can be run manually for demos and validation.

---

## 6. Team Composition

### Ideal team of veteran experts

| Role | Count | Key skills | Why |
|------|-------|------------|-----|
| **PostgreSQL internals engineer** | 1 | Deep knowledge of `xlogreader.c`, `snapbuild.c`, WAL replay, recovery modes, standby behavior. Familiar with pgsql-hackers culture. | Phase 1 verification, Phase 2 controlled replay, future core patch design. Must understand the startup process, `standby.signal` vs `recovery.signal`, slot creation during recovery. |
| **PostgreSQL DBA / DBRE** | 1 | Production experience with logical replication, pgBackRest/WAL-G, PITR, slot management, `pg_basebackup`. | Validates real-world scenarios, writes integration tests, stress tests. Knows the pain points firsthand. |
| **Backend/CLI developer** | 1 | Python, system programming, Docker, CI/CD. Experience building CLI tools with proper error handling, signal handling, cleanup. | Builds the orchestrator CLI, consumer pipeline, PII filters, output formatters. |
| **QA / test engineer** | 0.5 (part-time) | PostgreSQL testing, TAP tests, Docker Compose, CI matrix design. | Designs the test matrix, maintains CI, catches edge cases. Can be combined with the DBA role. |

**Total: 3 full-time + 1 part-time = ~3.5 FTE**

---

## 7. Implementation Plan

### Sprint 0 — Validate Foundation (2 weeks, with early-exit)

**Revised in v0.2.** The v0.1 plan treated slot creation as the single gate. It isn't — it's one of four gates (see §4.1.3). Even if slot creation succeeds, the harder questions are whether it decodes newly-restored WAL, whether it survives replay progress, and whether it survives restart cycles. Budget two weeks with an early exit if the answers are clean; if any gate hits an obstacle that requires a `snapbuild.c` / `standby.c` source-level investigation, two weeks is the realistic minimum (not 1–2 days).

**Scope the MVP narrowly** — this is a feasibility experiment, not a product build:

- Single PG version (pick one, likely PG17 for broadest applicability).
- Local archive directory, not S3 (network variables add noise).
- `test_decoding` plugin only.
- One append-only table with a primary key.
- No DDL during the window.
- Dummy-write loop on primary during the whole experiment (forces `XLOG_RUNNING_XACTS` records to stream into the archive promptly).

| Task | Owner | Depends on | Days |
|------|-------|------------|------|
| S0-1: Set up PG17 primary with `wal_level=logical`, `archive_mode=on`, local archive dir, plus a dummy-write + `pg_switch_wal()` loop | Internals eng | — | 0.5 |
| S0-2: Take `pg_basebackup`, create test table with PK, insert starter rows, force WAL switch, archive | Internals eng | S0-1 | 0.5 |
| S0-3: Provision standby with `restore_command`, `standby.signal`, `hot_standby=on` (no `hot_standby_feedback`), `recovery_target_action='pause'` (for US-2-style tests), or no target (for continuous) | Internals eng | S0-2 | 0.5 |
| S0-4 **(Gate 1)**: `pg_create_logical_replication_slot('archive_decoder', 'test_decoding')` succeeds. Orchestrator retries on `ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE` until `SNAPBUILD_CONSISTENT` is reached | Internals eng | S0-3 | 1 |
| S0-5 **(Gate 2)**: After slot creation, do fresh inserts on primary, archive, confirm decode. **Critical:** v0.1 implied we could decode WAL from before slot creation — we cannot. Only post-creation WAL is in scope. | Internals eng | S0-4 | 1.5 |
| S0-6 **(Gate 3)**: Let replay advance with moderate catalog churn (CREATE/DROP on non-test schemas, a manual `VACUUM` on a catalog table if we can provoke it) — does the slot survive? Capture the failure mode if not. | Internals eng | S0-5 | 2 |
| S0-7 **(Gate 4)**: Restart the standby mid-decode. Resume consumption. Verify no duplicates past `confirmed_flush_lsn` and no gaps before it. | Internals eng | S0-5 | 1 |
| S0-8: If any gate fails, read `snapbuild.c` / `standby.c` / `slot.c` with debugger; map exact error codes; decide scope | Internals eng | any gate | 3 |
| S0-9: Write findings section on this spec (v0.3) — for each gate: pass/fail, error codes, what the failure tells us about scope | All | S0-7 | 1 |

**Early-exit rule:** if G1–G4 all pass cleanly by day 5, declare Sprint 0 done and move to Sprint 1. The 2-week budget exists to absorb investigation time if a gate fails in a non-obvious way.

**Gate interpretation matrix** — for each gate, concrete failure symptoms mapped to scope impact:

| Observed failure | Interpretation | Scope impact |
|------------------|----------------|--------------|
| G1: slot creation returns `ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE` even after hours of replay | `SNAPBUILD_CONSISTENT` not reachable from archive alone — missing some condition present on streaming standbys | Likely a core patch needed before anything else; PoC pauses |
| G1: slot creation works but only after `pg_log_standby_snapshot()` on primary at archive time | Dependency on primary cooperation | Tool must document this requirement; acceptable constraint |
| G2: slot created but no decoded changes for post-creation WAL | Archive replay isn't advancing past slot's LSN (or decoding is silently empty) | Instrumentation / config issue, not scope change |
| G3: slot invalidated within minutes of replay | Catalog vacuum records invalidate `catalog_xmin` quickly under normal load | Scope shrinks to narrow forensic windows; US-1 continuous use at risk |
| G4: slot state corrupt after restart | Unexpected; would be a PG bug | Escalate to pgsql-hackers, pause PoC |

### Sprint 1 — Basic Pipeline (2 weeks)

**Goal:** End-to-end: insert on primary → archive → decode on standby → JSON output.

| Task | Owner | Depends on | Days | Parallelizable |
|------|-------|------------|------|----------------|
| S1-1: Dockerized test harness (primary + standby in containers, shared WAL archive volume) | CLI dev | Sprint 0 ✓ | 3 | — |
| S1-2: Consumer script — connect to slot via streaming replication, emit JSONL | CLI dev | S1-1 | 2 | — |
| S1-3: Test: multi-type DML (INSERT/UPDATE/DELETE, varied column types) | DBA | S1-2 | 2 | ∥ with S1-4 |
| S1-4: Test: TOAST values, NULLs, empty strings, large transactions | DBA | S1-2 | 2 | ∥ with S1-3 |
| S1-5: TDD: PII filter module (mask_email, redact, hash, fake) | CLI dev | — | 2 | ∥ with S1-3 |
| S1-6: TDD: output formatters (JSON, SQL) | CLI dev | — | 1 | ∥ with S1-3 |
| S1-7: CI pipeline — run test matrix on PG16, PG17 | QA | S1-3, S1-4 | 2 | — |

### Sprint 2 — Controlled Replay & Robustness (2.5 weeks)

**Goal:** Handle DDL (non-rewriting and rewriting), build a slot-invalidation cookbook, and provide an experimental batched-replay + consistency-check loop (US-4).

| Task | Owner | Depends on | Days | Parallelizable |
|------|-------|------------|------|----------------|
| S2-1: Controlled replay script (pause → consume → resume loop — batch granularity, not per-record; see US-4 correction) | Internals eng | Sprint 1 ✓ | 3 | — |
| S2-2: Test: DDL during decode window — split into two subtasks | Internals eng | S2-1 | **5** (was 2) | ∥ with S2-3 |
| &nbsp;&nbsp;S2-2a: Non-rewriting DDL (ADD COLUMN, DROP COLUMN, RENAME) | Internals eng | S2-1 | 2 | — |
| &nbsp;&nbsp;S2-2b: Rewriting DDL (ALTER TYPE, VACUUM FULL, CLUSTER) — historic catalog snapshot stress; this is where novel risk lives | Internals eng | S2-2a | 3 | — |
| S2-3: Test: slot invalidation scenarios — detect and report gracefully; build a small invalidation cookbook (which primary ops cause it, on what timescales) | DBA | S2-1 | 3 | ∥ with S2-2 |
| S2-4: Experimental: controlled-batch replay with amcheck verification between batches (US-4 experimental, not a PoC blocker) | Internals eng | S2-1 | 2 | — |
| S2-5: Test: resume does not promote — verify `pg_is_in_recovery()` stays `true` across 10+ cycles with no `recovery_target*` set | DBA | S2-1 | 1 | ∥ with S2-4 |
| S2-6: Integrate PII filter into consumer pipeline | CLI dev | S1-5, S1-6 | 2 | ∥ with S2-1 |
| S2-7: CLI tool skeleton (`pg-wal-logical-decode` with argument parsing, config loading) | CLI dev | — | 2 | ∥ with S2-1 |

### Sprint 3 — CLI & Polish (1.5 weeks)

**Goal:** Usable CLI tool, documentation, demo.

| Task | Owner | Depends on | Days | Parallelizable |
|------|-------|------------|------|----------------|
| S3-1: CLI: full lifecycle orchestration (provision → decode → cleanup) | CLI dev | S2-7 | 3 | — |
| S3-2: WAL-G / pgBackRest integration for `restore_command` | DBA | S3-1 | 2 | ∥ with S3-3 |
| S3-3: PG18 testing — verify with `pg_logicalinspect` visibility | Internals eng | Sprint 2 ✓ | 1 | ∥ with S3-2 |
| S3-4: README, usage examples, architecture diagram | All | S3-1 | 2 | — |
| S3-5: Demo script: end-to-end logical PITR with PII masking | CLI dev | S3-1 | 1 | — |
| S3-6: Record demo, write blog post draft | All | S3-5 | 2 | — |

### Gantt overview (v0.2 — Sprint 0 expanded to 2 weeks, Sprint 2 to 2.5 weeks)

```
Week:     1        2        3        4        5        6        7        8
          ├────────┼────────┼────────┼────────┼────────┼────────┼────────┤
Sprint 0: ████████████████
Sprint 1:                  ████████████████
Sprint 2:                                  ████████████████████
Sprint 3:                                                      ██████████
```

**Total: ~8 weeks to usable PoC** (was ~7; Sprint 0 expanded to absorb investigation time, Sprint 2 expanded for DDL + invalidation testing). If Sprint 0 exits early (all four gates pass cleanly by day 5), revert to the ~7-week timeline.

---

## 8. Future Work (Beyond PoC)

These are explicitly out of scope for the PoC but documented for roadmap planning:

1. **Core patch: slot-aware replay throttling** — the revised, reframed version of v0.1's `recovery_target_function` proposal (see §4.2.3). Shape TBD: likely a declarative built-in mode, not user plpgsql. The *need* is pausing replay before applying a WAL record that would invalidate an active logical slot's `catalog_xmin`. Start as a problem statement on pgsql-hackers after the PoC demonstrates the need empirically.

2. **Core patch: walsender `restore_command` integration — complementary, not foundational.** Craig Ringer's 2020 proposal, revived by Kukushkin in 2025. This patch lets a **primary's walsender** fetch archived segments when a downstream logical replica has fallen behind and the primary has already recycled the segment. It keeps existing logical replication alive across retention gaps. It is **not** the mechanism this PoC uses — we don't run a walsender on the primary at all. The two efforts are complementary (the walsender patch improves robustness of today's logical replication; this PoC decouples replication from the primary entirely) and should not be conflated.

3. **Catalog snapshot export** — Periodically serialize catalog state alongside WAL archives. Enables a true standalone decoder without a running PostgreSQL instance. Multi-year effort.

4. **Integration with DBLab** — Use DBLab Engine's ZFS cloning for instant standby provisioning. Instead of restoring a full backup (slow), clone a thin provision in seconds. If DBLab is available during Sprint 1, pull this forward — it radically accelerates the test matrix.

5. **Managed provider integration (aspirational).** If Supabase / Neon / similar chose to expose WAL archives plus a matching base backup, this approach would let them offer a filtered logical stream without granting superuser. This is a cooperation question, not a technical one — listed as strategic upside, not a near-term commitment.

6. **Docs / devrel resourcing.** The 3.5 FTE team composition in §6 has zero allocation for docs, blog posts, conference talks, or the eventual pgsql-hackers RFC. For a tool trying to land in the community, that is a gap. Budget ~1 senior-week of writing time per major milestone (Sprint 0 findings, Sprint 3 launch).

---

## 9. References

1. Craig Ringer, "Logical archiving" thread, pgsql-hackers, December 2020 — the original `restore_command` proposal for logical walsenders:
   https://www.postgresql.org/message-id/2B44FA4B-7500-4B37-82BD-BFACA20001AD@yandex-team.ru

2. Alexander Kukushkin et al., "Requested WAL segment has already been removed" — July 2025 revival of `restore_command` for walsenders:
   https://www.postgresql.org/message-id/CAGjGUALfTQz4aCfN38ZRtiPmtzbdmacAm=Pse4aLbxYX4j0Cjw@mail.gmail.com

3. Bertrand Drouvot, "Allow logical decoding on standbys" — PG16 commit `0fdab27`:
   https://github.com/postgres/postgres/commit/0fdab27a

4. Bertrand Drouvot, blog post "Postgres 16 highlight: Logical decoding on standby":
   https://bdrouvot.github.io/2023/04/19/postgres-16-highlight-logical-decoding-on-standby/

5. `pg_logicalinspect` contrib module (PG18) — commit `7cdfeee`:
   https://git.postgresql.org/gitweb/?a=commit&h=7cdfeee320e72162b62dddddee638e713c2b8680&p=postgresql.git

6. `pg_logicalinspect` documentation (PG18):
   https://www.postgresql.org/docs/18/pglogicalinspect.html

7. Masahiko Sawada, "POC: enable logical decoding when wal_level = 'replica' without a server restart" — dynamic `wal_level` (PG19):
   https://www.postgresql.org/message-id/CAD21AoCVLeLYq09pQPaWs+Jwdni5FuJ8v2jgq-u9_uFbcp6UbA@mail.gmail.com

8. Amul Sul, "pg_waldump: support decoding of WAL inside tarfile" — tar archive support (PG19, under review):
   https://www.mail-archive.com/pgsql-hackers@lists.postgresql.org/msg203786.html

9. PostgreSQL source — `snapbuild.c` (historic catalog snapshot machinery):
   https://github.com/postgres/postgres/blob/master/src/backend/replication/logical/snapbuild.c

10. PostgreSQL source — `xlogreader.c` (WAL reading API, usable by frontend and backend):
    https://github.com/postgres/postgres/blob/master/src/backend/access/transam/xlogreader.c

11. Gunnar Morling, "Using Stand-by Servers for Postgres Logical Replication" — practical PG16 standby decoding walkthrough:
    https://www.decodable.co/blog/postgres-logical-replication

12. PostgreSQL 16 Release Notes — logical decoding on standbys entry:
    https://www.postgresql.org/docs/16/release-16.html

13. @x4m (Andrey Borodin), Postgres.tv hacking session — architecture ideas for this PoC (transcript in project files)
