# Logical Decoding from Archived WAL — SPEC

**Version:** 0.1  
**Status:** Draft — awaiting expert review  
**Date:** 2026-04-15  
**Author:** @NikolayS (PostgresAI)  
**Contributors:**  
- @x4m (Andrey Borodin) — main idea generator; architecture ideas from Postgres.tv hacking session  
- @kirkw (Kirk Wolak) — contributor

---

## Changelog

| Version | Date       | Author    | Changes |
|---------|------------|-----------|---------|
| 0.1     | 2026-04-15 | @NikolayS | Initial draft. Consolidated ideas from @x4m hacking session + research on PG community history (Craig Ringer 2020, Kukushkin 2025 revival, PG16–19 infrastructure). Three-phase PoC plan. |

---

## 1. Goal

**One-liner:** Produce a logical change stream (JSON / SQL / pgoutput protocol) from archived WAL files — without maintaining a replication slot on the production primary and without impacting production at all.

### Why it's needed

Logical replication in PostgreSQL today has a fundamental coupling problem: the logical replication slot lives on the primary (or, since PG16, on a standby that streams from the primary). This creates three categories of pain:

1. **Production risk.** A stalled logical consumer causes WAL retention to grow unboundedly on the primary — or, if `max_slot_wal_keep_size` is set, the slot gets invalidated and the entire replication pipeline breaks. Either outcome is operationally dangerous.

2. **No backward reach.** You can only start consuming from slot-creation time onward. There is no "logical point-in-time recovery" — you cannot say "give me all logical changes from last Tuesday." Physical PITR exists; logical PITR does not.

3. **Managed-service lock-in.** Most managed PostgreSQL providers (RDS, Cloud SQL, AlloyDB) don't expose WAL archives or superuser access. If we can logically decode from archived WAL, providers could expose a filtered/sanitized logical stream without granting superuser — unlocking escape hatches and cross-platform replication.

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
> **I want** to logically decode archived WAL from 14:00 to 14:31  
> **so that** I can extract the exact DML needed to restore the deleted rows — without restoring a full physical cluster to that point.

**Acceptance criteria:**
- Restore base backup to a temporary standby with `recovery_target_time` set to 14:31 UTC.
- Create logical slot, consume changes between two LSN/time boundaries.
- Output contains `DELETE FROM orders WHERE ...` statements (or JSON equivalent) for the affected rows.
- Manual verification: create a table, insert rows, delete them, archive the WAL. Restore and decode — confirm deleted rows appear in logical output as `DELETE` operations.

### US-3: PII-free staging via filtered logical replay

> **As** a platform engineer,  
> **I want** to replicate production data to a staging environment with PII stripped  
> **so that** developers have realistic data without compliance risk.

**Acceptance criteria:**
- Logical changes consumed from the archive-fed standby pass through a filter that masks PII columns (e.g., `email`, `phone`).
- The target staging database receives the masked data via logical apply.
- Manual verification: insert row with `email='secret@example.com'` on production. Confirm staging receives `email='***@***.com'` or equivalent.

### US-4: WAL correctness verification (step-by-step replay)

> **As** a PostgreSQL core developer,  
> **I want** to replay WAL one record at a time and run consistency checks after each record  
> **so that** I can detect bugs where the cluster is temporarily in an inconsistent state between two WAL records.

**Acceptance criteria:**
- An external orchestration script pauses replay, runs `amcheck` or custom verification queries, then advances one record.
- If inconsistency is detected, the script reports the exact LSN and WAL record type that caused it.
- Manual verification: replay a known WAL sequence record-by-record, run `SELECT count(*) FROM pg_class` after each step — confirm no errors.

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
| Step-replay controller | Python | For US-4: pauses/resumes replay, runs checks between steps. |

### 3.4 Constraints and limitations (PoC scope)

- **Requires PG16+** (logical decoding on standby).
- **Requires `wal_level = logical`** on the primary at the time the WAL was generated. PG19's dynamic `wal_level` helps but cannot retroactively decode `replica`-level WAL.
- **DDL during decode window:** PoC Phase 1 assumes no DDL. Phase 2+ handles DDL by letting the standby's physical replay apply catalog changes naturally — the logical decoder on the standby sees updated catalogs automatically.
- **Base backup required:** You need a base backup taken before the earliest WAL you want to decode. This is standard for any PITR scenario.
- **`hot_standby_feedback = on` required** for slot creation on standby.
- **Risk of slot invalidation:** If recovery reaches a point that would invalidate the logical slot (e.g., catalog changes conflicting with slot's `catalog_xmin`), the slot is invalidated. Phase 2 addresses this with controlled replay.

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
hot_standby = on
hot_standby_feedback = on
max_wal_senders = 5
wal_level = logical

# Fetch WAL from archive — this is the key
restore_command = 'cp /path/to/wal_archive/%f %p'
# For S3: restore_command = 'wal-g wal-fetch %f %p'

# Recovery behavior
recovery_target_action = 'pause'
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

#### 4.1.3 What to verify

| Check | Expected | Notes |
|-------|----------|-------|
| Standby starts in recovery and reaches hot_standby | Yes | Standard PG behavior |
| `pg_create_logical_replication_slot()` succeeds | Unknown — **this is the key test** | May fail if recovery hasn't reached CONSISTENT state |
| `pg_logical_slot_peek_changes()` returns decoded DML | Unknown | May require `pg_log_standby_snapshot()` on primary first |
| Changes from WAL archives (not just already-replayed WAL) appear | Unknown | Critical: do inserts on primary AFTER standby is set up, wait for archival, confirm they decode |
| Slot survives continued WAL replay | Unknown | May get invalidated by catalog changes |

#### 4.1.4 Known risks and mitigations

1. **Slot creation may fail during recovery.** PG16 docs say logical slot creation on standby requires `pg_log_standby_snapshot()` to be called on the primary. For a pure archive scenario (no primary connection), we need to verify if a regular checkpoint's `xl_running_xacts` suffices, or if we must have called `pg_log_standby_snapshot()` before archiving.

2. **`hot_standby_feedback` normally requires a primary connection.** On a restore_command-only standby, there's no primary to send feedback to. We need to confirm the standby doesn't error out — it may simply skip sending feedback, which is fine (we don't need the primary to retain WAL; we have the archive).

3. **WAL replay may outrun slot consumption.** If the standby replays WAL faster than the consumer reads the slot, the slot may be invalidated. Mitigation: pause replay, consume, resume.

### 4.2 Phase 2 — Controlled Replay

**Goal:** Prevent slot invalidation and enable step-by-step replay for debugging and controlled consumption.

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

#### 4.2.2 Risks with resume

**Critical issue from @x4m:** `pg_wal_replay_resume()` can promote the standby if recovery reaches the end of available WAL and `standby.signal` conditions aren't met correctly. Mitigations:

- Always use `standby.signal` (never `recovery.signal`).
- Never set `recovery_target` — let the standby follow indefinitely.
- Verify behavior: after resume, check `pg_is_in_recovery()` — if it returns `false`, the standby promoted.

#### 4.2.3 Future: function-based recovery target (core patch)

@x4m's vision — a new GUC that generalizes `recovery_min_apply_delay`:

```
# postgresql.conf
recovery_target_function = 'myschema.should_apply'
```

Function signature (proposed):

```sql
CREATE FUNCTION myschema.should_apply(
    lsn          pg_lsn,
    record_type  text,      -- 'HEAP_INSERT', 'XLOG_COMMIT', 'DDL', etc.
    relation_oid oid,       -- NULL if not relation-specific
    xid          xid,
    is_catalog   boolean    -- true if this modifies a catalog table
) RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
    -- Pause before any catalog-modifying record (prevents slot invalidation)
    IF is_catalog THEN RETURN false; END IF;
    RETURN true;
END;
$$;
```

Semantics:
- Called by the startup process before applying each WAL record.
- Returns `true` → apply and continue. Returns `false` → pause recovery (like `recovery_target_action = 'pause'`).
- Resume applies the pending record and calls the function again for the next one.
- **Never promotes** — this is a replay-control mechanism, not a recovery target in the promote-when-reached sense.

This is a **core PostgreSQL patch** — out of scope for PoC but documented here as the north star.

### 4.3 Phase 3 — Consumer Pipeline

**Goal:** A reusable consumer that connects to the standby's logical slot and produces filtered, transformed output.

#### 4.3.1 Consumer modes

| Mode | Output | Use case |
|------|--------|----------|
| `json` | JSONL file, one line per change | Audit trail, analytics ingest |
| `sql` | SQL statements (INSERT/UPDATE/DELETE) | Logical PITR, migration |
| `replay` | Apply to target PostgreSQL | PII-free staging, cross-version replication |
| `kafka` | Kafka producer | CDC pipeline |

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
2. Configures `restore_command`, `standby.signal`, `hot_standby`, `hot_standby_feedback`.
3. Starts PostgreSQL on `--pg-port`.
4. Waits for hot standby.
5. Creates logical slot.
6. Runs the pause/consume/resume loop.
7. Applies filters, writes output.
8. Tears down standby (if `--cleanup`).

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
| Step-replay controller | Integration tests | pytest + Docker | Verify pause/resume/consume cycle. |
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

### Sprint 0 — Validate Foundation (1 week)

**Goal:** Answer the single most important question: does logical slot creation work on a `restore_command`-only standby?

| Task | Owner | Depends on | Days |
|------|-------|------------|------|
| S0-1: Set up PG16 primary with `wal_level=logical`, `archive_mode=on`, local archive dir | Internals eng | — | 0.5 |
| S0-2: Take `pg_basebackup`, create test table, insert rows, force WAL switch, archive | Internals eng | S0-1 | 0.5 |
| S0-3: Provision standby with `restore_command`, `standby.signal`, `hot_standby=on`, `hot_standby_feedback=on` | Internals eng | S0-2 | 0.5 |
| S0-4: Attempt `pg_create_logical_replication_slot()` — **this is the gate** | Internals eng | S0-3 | 0.5 |
| S0-5: If S0-4 fails, investigate: do we need `pg_log_standby_snapshot()` on primary first? Does a checkpoint suffice? What error? | Internals eng | S0-4 | 1 |
| S0-6: If S0-4 succeeds, consume slot, verify decoded output matches inserted rows | Internals eng | S0-4 | 0.5 |
| S0-7: Document findings — update this spec with results | All | S0-6 | 0.5 |

**Gate decision:** If S0-4 fails and cannot be worked around, we need to evaluate:
- Is the issue `hot_standby_feedback` requiring a primary connection? (Likely solvable — feedback is optional for our use case.)
- Is the issue `snapbuild.c` not reaching CONSISTENT without `xl_running_xacts` from streaming? (May require `pg_log_standby_snapshot()` before archiving.)
- Is a core patch needed just for slot creation? (Changes scope significantly.)

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

### Sprint 2 — Controlled Replay & Robustness (2 weeks)

**Goal:** Handle DDL, prevent slot invalidation, enable step-by-step replay.

| Task | Owner | Depends on | Days | Parallelizable |
|------|-------|------------|------|----------------|
| S2-1: Controlled replay script (pause/consume/resume loop) | Internals eng | Sprint 1 ✓ | 3 | — |
| S2-2: Test: DDL during decode window (ADD COLUMN, DROP COLUMN, ALTER TYPE) | Internals eng | S2-1 | 2 | ∥ with S2-3 |
| S2-3: Test: slot invalidation scenarios — detect and report gracefully | DBA | S2-1 | 2 | ∥ with S2-2 |
| S2-4: Step-replay mode with amcheck verification after each record | Internals eng | S2-1 | 3 | — |
| S2-5: Test: resume-no-promote verification (10+ cycles) | DBA | S2-1 | 1 | ∥ with S2-4 |
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

### Gantt overview

```
Week:     1        2        3        4        5        6        7
          ├────────┼────────┼────────┼────────┼────────┼────────┤
Sprint 0: ████████
Sprint 1:          ████████████████
Sprint 2:                            ████████████████
Sprint 3:                                              ██████████
```

**Total: ~7 weeks to usable PoC.**

---

## 8. Future Work (Beyond PoC)

These are explicitly out of scope for the PoC but documented for roadmap planning:

1. **Core patch: `recovery_target_function`** — @x4m's proposal for function-based recovery target with next-record introspection. RFC for pgsql-hackers.

2. **Core patch: walsender `restore_command` integration** — Craig Ringer's 2020 proposal, revived by Kukushkin in 2025. Teach the logical walsender to fetch archived WAL segments when they're missing from `pg_wal`. This solves slot invalidation at the source.

3. **Catalog snapshot export** — Periodically serialize catalog state alongside WAL archives. Enables a true standalone decoder without a running PostgreSQL instance. Multi-year effort.

4. **Integration with DBLab** — Use DBLab Engine's ZFS cloning for instant standby provisioning. Instead of restoring a full backup (slow), clone a thin provision in seconds.

5. **Managed provider integration** — Work with Supabase, Neon, etc. to expose filtered WAL archives that can be logically decoded without superuser.

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
