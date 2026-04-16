# Logical Decoding from Archived WAL — SPEC

**Version:** 0.6  
**Status:** Post Sprint 0 execution — findings incorporated; pgsql-hackers RFC draft ready  
**Date:** 2026-04-19  
**Author:** Claude Opus 4.6 (1M context)  
**Key researcher:** Claude Opus 4.6 (deep research mode)  
**Architecture lead:** [@x4m](https://github.com/x4m) (Andrey Borodin) — [Postgres.tv hacking session](https://www.youtube.com/watch?v=LjiU6kB6izw)  
**Contributors:**  
- [@NikolayS](https://github.com/NikolayS) (Nik Samokhvalov) — idea generator, AI coordinator  
- [@kirkw](https://github.com/kirkw) (Kirk Wolak)  

**Meeting secretary / transcription:** [Circleback.ai](https://circleback.ai) — transcribed the [Postgres.tv hacking session](https://www.youtube.com/watch?v=LjiU6kB6izw); transcript fed into the research and drafting phases.  
**Reviewers (four rounds of independent review):**  
- Claude Opus 4.6 (separate instance from the author)  
- Gemini 3.1 Pro  
- GPT 5.4

AI-authored under [@NikolayS](https://github.com/NikolayS)'s direction; architectural insights from [@x4m](https://github.com/x4m)'s [Postgres.tv session](https://www.youtube.com/watch?v=LjiU6kB6izw) with [@NikolayS](https://github.com/NikolayS).

---

## Changelog

| Version | Date       | Changes |
|---------|------------|---------|
| 0.1     | 2026-04-15 | Initial draft. Consolidated [@NikolayS](https://github.com/NikolayS)'s framing and [@x4m](https://github.com/x4m) architectural input (Postgres.tv hacking session) + research on PG community history (Craig Ringer 2020, Kukushkin 2025 revival, PG16–19 infrastructure). Three-phase PoC plan. |
| 0.2     | 2026-04-16 | Address three independent technical reviews. Corrections: (a) `hot_standby_feedback = on` is **not** required on an archive-only standby — it's a standby→primary mechanism and is a silent no-op without a walreceiver; (b) `pg_wal_replay_resume()` does **not** promote a `standby.signal` standby with no `recovery_target*` — the original framing was wrong; (c) the slot only decodes WAL **generated after slot creation** (fundamental `snapbuild` constraint) — US-2 rewritten accordingly; (d) `recovery_target_function` reframed from a semi-designed plpgsql API to "slot-aware replay throttling, mechanism TBD" after @reviewer-3 flagged infeasibility (performance, startup-process execution context, in-flight relmap); (e) Ringer/Kukushkin walsender patch clarified — it solves a complementary problem (walsender fetching archived segments for an existing consumer), not foundational to this PoC. Structural: Sprint 0 redefined as 4 gates (slot create → decode post-creation WAL → survive replay progress → survive restart/resume) budgeted at 2 weeks; slot invalidation elevated to project-level risk; US-4 step-replay marked experimental (the `sleep(0.1)` loop gives batch granularity, not per-record); added test matrix items (streaming large txns, 2PC, subtxn overflow, replica identity variants, TOAST pglz+lz4 mix, restart mid-decode, PG18 sequences); increased S2-2 DDL budget; tightened managed-service positioning from "why needed now" to "strategic upside if providers cooperate"; SQL output caveats in §4.3.1. |
| 0.3     | 2026-04-17 | Address second-round review (3 reviews). **Hard technical corrections:** (a) `recovery_target_*` GUCs are `PGC_POSTMASTER` — cannot be "cleared at runtime"; US-2 recipe and §4.4 step 7 rewritten with the correct mechanism (`pg_wal_replay_resume()` past the paused target; orchestrator-driven `pg_wal_replay_pause()` when replay LSN reaches `L_end`); (b) `pg_switch_wal()` does **not** produce `XLOG_RUNNING_XACTS` — §4.1.4 risk 1 and S0-1 loop corrected to use `pg_log_standby_snapshot()` (via `LogStandbySnapshot()`) plus dummy writes and optional `pg_switch_wal()` for prompt archival; (c) `pg_create_logical_replication_slot()` **blocks** inside `DecodingContextFindStartpoint()` waiting for snapshot-builder consistency — it does not return a transient error; orchestrator model changed from "retry on `ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE`" to "statement_timeout + cancel" with progress polling; (d) PG19 references softened — PG19 doesn't exist yet (Sept 2026 earliest) and both dynamic `wal_level` and `pg_waldump` tar support are pgsql-hackers threads still under review; (e) G4 wording directions corrected (on resume, consumer sees LSN > `confirmed_flush_lsn` already decoded, never LSN ≤ `confirmed_flush_lsn`); (f) architecture diagram now shows `pgoutput` (plugin policy says `test_decoding` is PoC-only); (g) `pg_get_wal_stats()` usage in US-4 correctly attributed to the `pg_walinspect` extension. **Strong reframings:** G1 expected result softened from "Should work" to "Plausible based on standby logical decoding internals, but unproven in restore-only mode"; US-2 gains label clarifier ("forward logical decoding from a rewound physical state — not backward decoding"); G4 for Sprint 0 narrowed to "slot exists, not corrupt, resumed consumption is explainable and bounded" (exact duplicate/gap semantics deferred to post-PoC); G3 reproducer design rewritten around the actual invalidation trigger (replay of vacuum-on-catalog WAL records) — temp object churn + explicit `VACUUM pg_class/pg_attribute/pg_type` on primary with autovacuum active; `max_slot_wal_keep_size` on the **standby** added as a separate invalidation vector; G3 budget increased from 2d → 4.5d. **New sections in §7:** "Out of scope for Sprint 0" box; two-outcome scope-split (Outcome A: continuous viable → US-1/US-3/Phase 3 in scope; Outcome B: forensic only → US-2 survives, US-1 questionable, Phase 3 narrows); Sprint 0 observability subsection (standby logs, `pg_replication_slots` snapshots, replay LSN progression, `restore_command` retries, error codes, WAL segment names). **Documentation completeness:** CLI validation logic section; `recovery_target_inclusive = true` caveat (slot created at paused target already has that record applied — `catalog_xmin` may start further ahead than intended). **Judgment call left open:** US-4 kept with "candidate for removal in v0.4" marker after @reviewer-3 questioned whether it's load-bearing (core devs already have `pg_waldump` + regression suite + TAP tests; §4.2.3's real motivation is slot invalidation, not US-4). Not cut unilaterally. |
| 0.4     | 2026-04-18 | **US-4 explicitly retained** after v0.3 "candidate for removal" marker. Although all three round-3 reviewers recommended cutting it, US-4 is a core idea from [@x4m](https://github.com/x4m) and part of the project's motivation, not brainstorm residue. The "EXPERIMENTAL" qualifier on US-4 remains because the user-space approximation of per-record stepping is genuinely coarse, but the user-story value does not. S2-4 retained in Sprint 2. Remaining round-3 corrections (Sprint 0 budget math, G1 failure wording, PG18-for-Sprint-0, CLI `--from-time` resolution, archive continuity, etc.) deferred to a follow-up revision. |
| 0.5     | 2026-04-19 | Pre-Sprint-0 cleanup addressing round-4 review convergence. **Must-fix-before-Sprint-0:** (a) Sprint 0 day budget reconciled — tasks sum to 11.5d (excluding contingent S0-8) or 14.5d (including it); Sprint 0 budget extended from 2 weeks → 3 weeks on the Gantt; S0-9 findings write-up budget bumped 1d → 2d; Sprint 1 start pushed by 1 week, total PoC timeline now ~9 weeks; (b) US-4 acceptance criteria rewritten around the "pause-at-LSN, run user-supplied hook, advance, repeat" framing that actually reflects US-4's value, replacing the narrower amcheck-between-batches description that v0.4's justification had already superseded; (c) Outcome A's "US-4 keep-or-cut decision still open" bullet corrected to "US-4 in scope per v0.4 retention" — v0.4 changelog and §7.0.2 were contradicting each other; (d) S0-9's deliverable reference corrected from "v0.4" (which is this revision's predecessor, pre-Sprint-0) to "v0.6 findings appendix (post-Sprint-0)"; (e) US-4 header "EXPERIMENTAL" all-caps tag removed — it reads as "speculative, may be cut," which is exactly the opposite of the v0.4 retention. Replaced with a softer "coarse-grained by design, per-record stepping is future work" note in the body. **Also fixed:** (f) G1 failure-interpretation matrix row rewritten to drop the `ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE` retry-model phrasing (contradicts v0.3's blocking model); new wording: "slot creation never reaches consistency before statement_timeout despite snapshot forcing and replay progress"; (g) §4.1.4 risk 3 (`pg_wal` overflow when consumer stalls) explicitly flagged as "deferred to Sprint 1 with monitoring + thresholds" rather than waved through as "operationally acceptable"; (h) changelog v0.4 entry's defensive tone around US-4 not altered (historical) but v0.5 references §2 US-4 for reasoning instead of re-arguing. **Genuinely-deferred-to-v0.6+:** archive-continuity full-sequence scan (§4.4.1 improvement); CLI `--from-time` → LSN resolution policy; PG18-for-Sprint-0 switch (already decided in v0.3 via the "single PG version, likely PG17" language — revisit if `pg_logicalinspect` observability proves load-bearing during G1 debugging). These remain known issues, not "etc." |
| 0.6     | 2026-04-19 | **Sprint 0 executed** on a lab VM (PG18 + PG17 cross-validated) instead of waiting for a team. All four gates resolved with full raw evidence. See new **§10 Sprint 0 Execution Findings**. Key outcomes: **G1 PASS, G2 PASS, G3 FAILS** reliably under any autovacuum workload (MTTI 30–126s, deterministic in ~3s with `VACUUM pg_statistic`), **G4 PASS**. **Major recipe correction in §2 US-2:** the v0.5 `recovery_target_lsn + pause + create slot` recipe **does not work** — slot creation on a paused standby blocks snapbuild. The working recipe is gated-archive: pre-stage archive segments up to but NOT including the segment containing a quiet-moment `pg_log_standby_snapshot()` record, start standby, launch slot creation (blocks), release the snapshot's segment — snapbuild reads the path-(a) running_xacts forward from `restart_lsn` and hits `SNAPBUILD_CONSISTENT` immediately. **Works with primary DEAD** during recovery provided production has recorded periodic quiet-moment snapshots. Production-side prerequisite now documented in §2 US-2 and §11. **§4.2.3 refined:** the "slot-aware replay throttling" core-patch direction has been drafted as a pgsql-hackers RFC with measured MTTI data, exact WAL trigger records, and design rationale addressing performance, execution-context, and argument-availability concerns from earlier reviews; draft lives in GitHub issue [#25](https://github.com/NikolayS/postgres/issues/25) comment thread, ready for human sanity-check before posting. **Outcome determined: Outcome B (forensic-only) is the shipping scope.** US-1 (continuous CDC) requires the core patch; US-2 (windowed extraction) is viable now with the corrected recipe. Three reproducer scripts committed to `/blueprints/repro_*.sh`. |
| 0.7     | 2026-04-16 | **Post-Sprint-0 follow-ups** from continued issue #25 iteration. **(a)** New static-analysis tool `blueprints/wal_archive_ceiling.sh` validated end-to-end against a real failed-recovery archive — its `--db <oid>` prediction of the invalidation LSN matches the standby's dynamic invalidation exactly (same LSN, same `snapshotConflictHorizon`, same rel/blk). Documented as §10.7. **(b)** US-2 ceiling empirically shown to be controlled by **primary-side** `autovacuum_naptime`, not any standby-side GUC — a 300s window with default autovacuum invalidates at t≈138s, the same workload with `autovacuum_naptime=600s` survives the full 300s and drains 30 413 rows cleanly. Added to §10.2 table and §11.5. **(c)** Per-database specificity of slot invalidation called out: `InvalidatePossiblyObsoleteSlot` check is gated by `slot->data.database`, so catalog prunes in other databases do NOT invalidate the slot. The tool's initial version over-predicted by matching any-DB prunes; fix (commit 3e21eee3e8d) adds `--db <oid>` flag. |
| 0.8     | 2026-04-16 | **Sprint 1 core patch delivered.** `recovery_pause_on_logical_slot_conflict` GUC implemented end-to-end (§4.2.3 moves from "TBD mechanism" to "shipped prototype"). ~215 lines of C across 5 files; all logic hooks into `ResolveRecoveryConflictWithSnapshot` at `src/backend/storage/ipc/standby.c:505`. **Fixes arc across 5 commits on `blueprint/logical-decoding-archived-wals`:** (1) [2d70df87982](https://github.com/NikolayS/postgres/commit/2d70df87982) initial pause mechanism via existing `SetRecoveryPause` + `recoveryNotPausedCV`; (2) [8a3b95dc0b9](https://github.com/NikolayS/postgres/commit/8a3b95dc0b9) call `ConfirmRecoveryPaused` from our wait loop so `pg_get_wal_replay_pause_state()` returns `paused` not `pause requested`; (3) [8761b6eba4b](https://github.com/NikolayS/postgres/commit/8761b6eba4b) on resume, advance slot's `catalog_xmin` past the conflict horizon if operator drained to the conflict LSN (using `TransactionIdAdvance` for horizon+1 semantics); (4) [bbd5d4e13bc](https://github.com/NikolayS/postgres/commit/bbd5d4e13bc) skip slots where `effective_catalog_xmin` is `InvalidTransactionId` (not-yet-consistent) to avoid deadlock with `DecodingContextFindStartpoint`; (5) [7d160949d87](https://github.com/NikolayS/postgres/commit/7d160949d87) use `TransactionIdPrecedesOrEquals` in pause check to match the invalidation-side semantics in `DetermineSlotInvalidationCause` (off-by-one previously caused one-prune-late invalidation). **TAP test lands passing** (`src/test/recovery/t/050_recovery_pause_on_slot_conflict.pl`, 5/5 assertions, 36s runtime; two-phase flow: Phase 1 quiet-archive slot creation, Phase 2 primary catalog churn + orchestrator drain/resume loop). **Regression sweep clean** across 102 existing tests including `006_logical_decoding`, `010_logical_decoding_timelines`, `019_replslot_limit`, `028_pitr_timelines`, `038_save_logical_slots_shutdown`, `040_standby_failover_slots_sync` (PG18 synced slots), `contrib/test_decoding/sql/*` (14/14). Hot-path overhead when GUC off: single boolean check at top of `MaybePauseOnLogicalSlotConflict`. **Outcome upgrade: A (continuous US-1 viable) is now the shipping scope.** Dead-primary US-1 demo at `/tmp/us1_v2.sh` on lab VM: 45 469 decoded events = 3 × 15 153 primary INSERTs (100% coverage), 2 pause events handled, slot `wal_status=reserved`. US-2 ceiling lifted completely — no longer bounded by primary `autovacuum_naptime`. Outcome B section retained for operators running unpatched PG18/PG17 but §7.0.2 now states A is the primary outcome. Future Work §8.1 ("Core patch: slot-aware replay throttling") converted from "problem statement on pgsql-hackers after PoC" to "post patch to pgsql-hackers for review." |

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
- **PG19 (proposed, unreleased as of 2026-04-17):** dynamic `wal_level` (Sawada, under review) and `pg_waldump` reading from tar archives (Sul, under review) are pgsql-hackers threads still in discussion. PG19's release is September 2026 at earliest. These are listed as potentially useful infrastructure, not as committed features.
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

### US-2: Windowed logical extraction from archived WAL

> **As** a developer who accidentally deleted production data at 14:32 UTC,  
> **I want** to extract logical changes from archived WAL for the 14:00–14:31 window  
> **so that** I can reconstruct the DML needed to restore the deleted rows — without restoring a full physical cluster to that point.

**One-line framing:** this is **forward logical decoding from a rewound physical state**, not backward decoding. The actual mechanism is to physically rewind the standby to *before* the window, create the slot there, and then decode forward through the window. That framing is why you need a base backup predating the decode window.

**Fundamental constraint:** a logical slot can only decode WAL **generated after the slot was created** — `snapbuild` assembles the historic catalog snapshot starting from the slot-creation LSN; earlier WAL cannot be replayed through the slot.

**Production-side prerequisite (required for US-2):** maintain a lightweight background task on the primary that calls `SELECT pg_log_standby_snapshot();` during quiet moments (no in-flight xacts). Each such call emits a `Standby/RUNNING_XACTS` WAL record with `oldestRunningXid == nextXid`, which snapbuild treats as a "path (a)" record — reaching `SNAPBUILD_CONSISTENT` in a single step upon replay. Without these records in the archive, slot creation on an archive-fed standby with a busy primary workload cannot reach consistency (source: `snapbuild.c` `SnapBuildFindSnapshot()`). Overhead: < 100 bytes of WAL per call. One snapshot per low-traffic period (hourly or less) is plenty.

**Correct recipe (gated archive + quiet-moment snapshot, validated in Sprint 0 — see §10):**

1. Identify the most recent quiet-moment snapshot's LSN before the incident: `L_QUIET`. Its segment: `S_QUIET`. The window to decode is `[L_QUIET, L_end]`.
2. Restore the base backup to a point **before** `L_QUIET`.
3. Pre-stage a "gated archive" directory with WAL segments up to but **NOT including** `S_QUIET`. (Important: excluding the segment that contains the snapshot record.)
4. Configure standby: `restore_command` pointing at the gated archive, `hot_standby = on`, `wal_retrieve_retry_interval = 1s` (makes step 7 snappy), no `recovery_target*`, no `recovery_min_apply_delay`.
5. Start standby. Replay stops at end of gated archive. `restart_lsn` at subsequent slot creation will land at end of segment-before-S_QUIET = start of `S_QUIET`.
6. Launch `pg_create_logical_replication_slot('recovery_slot', 'pgoutput')` in background. It blocks waiting for `SNAPBUILD_CONSISTENT`.
7. Copy `S_QUIET` into the gated archive directory. The standby's `restore_command` retry picks it up within `wal_retrieve_retry_interval`; replay advances into the segment; snapbuild reads the path-(a) running_xacts record forward from `restart_lsn`, hits CONSISTENT via path (a), slot creation completes (typically ~1 second).
8. Copy remaining segments through `S_L_end` into the gated archive. Replay advances through the decode window.
9. Pause replay via `pg_wal_replay_pause()` when `pg_last_wal_replay_lsn() >= L_end`.
10. Drain the slot with `pg_logical_slot_get_changes('recovery_slot', NULL, NULL)`. Output contains all decoded changes from `restart_lsn` through the paused point.

**This works with the primary DEAD.** Validated in Sprint 0: [blueprints/repro_us2_deadprim.sh](repro_us2_deadprim.sh) runs end-to-end in ~90s with the primary killed before recovery; 60-second sustained-OLTP window produced 5811 decoded changes including 98 DELETEs with full old-tuple data. See §10.3 for raw evidence.

**Deprecated v0.5 recipe note:** earlier versions of this blueprint described a `recovery_target_lsn = L_start + action = 'pause'` recipe. That variant does not work: creating a slot on a paused standby blocks snapbuild indefinitely because no forward WAL arrives on the startup-process read path. Sprint 0 testing proved this is a dead end. Retained in the changelog for historical transparency.

**Acceptance criteria:**
- Follow the 6-step procedure above, using a base backup predating the decode window.
- Output for UPDATE/DELETE requires affected tables have adequate `REPLICA IDENTITY` (DEFAULT with PK, FULL, or USING INDEX). On tables without coverage, the tool must **explicitly flag** missing old-tuple information rather than silently emitting `DELETE FROM t` with no `WHERE`.
- Output uses `pgoutput` with a pinned protocol version, or a purpose-built plugin — **not** `test_decoding`. The `sql` consumer mode emits SQL best-effort and is only safe when plugin + replica identity allow deterministic reconstruction.
- Manual verification: create a table with a primary key, insert rows, delete them, archive WAL. Restore per the recipe — confirm deleted rows appear in logical output as `DELETE` operations with primary-key identification.

### US-3: PII-free staging via filtered logical replay

> **As** a platform engineer,  
> **I want** to replicate production data to a staging environment with PII stripped  
> **so that** developers have realistic data without compliance risk.

**Acceptance criteria:**
- Logical changes consumed from the archive-fed standby pass through a filter that masks PII columns (e.g., `email`, `phone`).
- The target staging database receives the masked data via logical apply.
- Manual verification: insert row with `email='secret@example.com'` on production. Confirm staging receives `email='***@***.com'` or equivalent.

### US-4: WAL correctness verification via paused-state inspection

> **As** a PostgreSQL core developer,  
> **I want** to pause WAL replay at or near a chosen LSN, run a consistency check or ad-hoc query against the cluster state at that point, then advance and repeat,  
> **so that** I can inspect and verify cluster behavior across a specific WAL sequence that's hard to reproduce otherwise.

Originates with [@x4m](https://github.com/x4m). `pg_waldump` inspects WAL statically and the regression suite verifies known-good scenarios; neither provides a live "replay to LSN X, poke at cluster state from psql, advance, poke again" workflow. US-4 makes that repeatable.

**Granularity caveat:** replay control from user space is **coarse-grained by design** — pause/resume with a `sleep(N)` or polling loop gives a time- or LSN-bounded batch, not a single record. True per-record stepping would need core support (see §4.2.3); not a Sprint-gating dependency. The user-story value does not depend on per-record granularity.

**Acceptance criteria:**
- Orchestrator pauses replay at or near a user-specified LSN (via `recovery_target_lsn` + `recovery_target_action = 'pause'` for the initial position, or orchestrator-driven `pg_wal_replay_pause()` as replay crosses a target LSN for subsequent positions).
- A user-supplied hook runs against the standby while replay is paused. The hook is any SQL — an `amcheck` call, a `SELECT count(*) FROM pg_class`, a custom verifier. The hook output is captured alongside the replay LSN.
- Orchestrator advances replay by a user-specified bound (either a time budget or an LSN delta) via `pg_wal_replay_resume()` + orchestrator-driven pause when replay reaches the boundary.
- The hook runs again at the new paused state. Repeat until the end of the window.
- Consistency failures (or unexpected hook output) are reported with the replay-LSN range of the batch that contained the transition, plus the hook's output. Pin-pointing to the exact record would require core support.
- Ancillary: `pg_walinspect`'s `pg_get_wal_records_info(start_lsn, end_lsn)` (preferred over `pg_get_wal_stats()`) or `pg_waldump` is used to describe which WAL records were applied in each batch.
- Manual verification: replay a known WAL sequence in small bounded batches with a simple hook (e.g., `SELECT count(*) FROM pg_class`), confirm the loop completes without false alarms on hot-standby-specific quirks (`amcheck` has known edge cases during concurrent replay — worth a warning in the docs, not a blocker).

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
                                    │  │ (pgoutput,     │  │
                                    │  │  protocol      │  │
                                    │  │  version       │  │
                                    │  │  pinned)       │  │
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

Instead, we use what PG16 already provides: **a physical standby replaying WAL supports logical slot creation and decoding.** The insight from [@x4m](https://github.com/x4m) is that this standby doesn't need to stream from the primary — it can replay from archive via `restore_command`. Production has zero coupling to this process.

This is **Path 2** from the community research ("PITR-based logical decoding / restore and decode"), operationalized as a tool.

### 3.3 Components

| Component | Language | Description |
|-----------|----------|-------------|
| `pg-wal-logical-decode` (CLI) | Bash + Python | Orchestrator: provisions standby from backup, configures recovery, creates slot, streams changes, tears down. |
| Decoder Standby | PostgreSQL 16+ | Standard PG instance in recovery mode with `standby.signal`, `restore_command`, `hot_standby = on`. |
| Consumer library | Python (psycopg) | Connects to standby's logical slot via streaming replication protocol. Applies filters, emits output. |
| Paused-state inspection controller (US-4) | Python | Pauses replay at/near a target LSN, runs a user hook (SQL / amcheck / custom), advances in time- or LSN-bounded batches, repeats. Coarse-grained by design — per-record stepping is future work, not a Sprint 0 dependency. |

### 3.4 Constraints and limitations (PoC scope)

- **Requires PG16+** (logical decoding on standby).
- **Requires `wal_level = logical`** on the primary at the time the WAL was generated. PG19's dynamic `wal_level` helps but cannot retroactively decode `replica`-level WAL.
- **Slot only decodes post-creation WAL (fundamental).** A logical slot's `catalog_xmin` horizon is established at slot-creation time; `snapbuild` assembles the historic catalog snapshot going forward from there. You cannot create a slot at time T and decode WAL from T−1hr. To decode a past window, the standby must be rewound (via `recovery_target`) to before that window, the slot created at the rewound position, then replay resumed forward. This is not a quirk — it is how `snapbuild` works. US-2 reflects this.
- **DDL during decode window:** PoC Phase 1 assumes no DDL. Phase 2+ relies on the standby's physical replay applying catalog changes naturally — the logical decoder on the standby sees updated catalogs automatically. **Caveat:** decoder-side correctness (catalogs update) is separate from consumer-side schema evolution (downstream output format changes). Rewriting DDL (`ALTER TABLE ... TYPE`, `VACUUM FULL`, `CLUSTER`) interacts with historic catalog snapshots in ways that have had core patches shipped as recently as PG17; treat these as high-risk test cases.
- **Base backup required:** You need a base backup taken before the earliest WAL you want to decode. This is standard for any PITR scenario.
- **`hot_standby_feedback` is a no-op here — removed as a requirement.** It is a standby→primary mechanism that operates through the walreceiver connection. On a `restore_command`-only standby there is no walreceiver, so the setting is silently inert. What actually keeps a logical slot's needed catalog tuples alive is the slot's own `catalog_xmin`, enforced by the startup process during replay — nothing else.
- **Slot invalidation is a project-level risk, not a Phase 2 hardening task.** The moment a logical slot exists, its `catalog_xmin` horizon is pinned. Invalidation has two independent vectors:
  1. **Catalog vacuum conflict (primary-side cause).** When the primary vacuums catalog tuples whose `xmax ≥ slot.catalog_xmin`, the resulting `xl_heap_prune` / `xl_heap_vacuum` / `xl_btree_vacuum` WAL records, when replayed on the standby, trigger `InvalidatePossiblyObsoleteSlot` (via `ResolveRecoveryConflictWithLogicalSlot`). There is no `hot_standby_feedback` shield — the primary has already vacuumed, the WAL record exists, replay will hit it. The only standby-side knob is *when* we apply that WAL (throttled replay).
  2. **WAL-size limit on the standby (standby-side cause).** If `max_slot_wal_keep_size` is set on the standby and the consumer falls far enough behind that the slot's `restart_lsn` would require keeping more WAL than that limit permits, the slot is invalidated regardless of catalog state. Our architecture eliminates this vector if we set `max_slot_wal_keep_size = -1` (unlimited) on the decoder standby — but then we must be prepared for `pg_wal` on the standby growing unboundedly if the consumer stalls. Trade-off to be managed.

  Whether invalidation can be survived in practice — under what workloads, with what mitigations — is **one of the four Sprint 0 gates** (see §7, gate G3). If it fails consistently, the PoC remains useful for narrow forensic windows but not as a reusable replication tool.

---

## 4. Implementation Details

### 4.1 Phase 1 — Prove the Pipe (MVP)

> **Tracking issue:** [NikolayS/postgres#25](https://github.com/NikolayS/postgres/issues/25) — Sprint 0 gate experiment (all four gates G1–G4).

**Goal:** Confirm that a physical standby replaying WAL from archive (not streaming) can host a logical slot and produce decoded changes.

**Nobody has publicly verified this works.** The [@x4m](https://github.com/x4m) session concluded with "somebody needs to try it." This is the single highest-value experiment.

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
# decode window so the slot can be created; see §2 US-2 for the full recipe.
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
| G1 | `pg_create_logical_replication_slot()` succeeds on an archive-only standby | **Plausible based on standby logical decoding internals, but unproven in restore-only mode.** The call blocks inside `DecodingContextFindStartpoint()` until `snapbuild` reaches `SNAPBUILD_CONSISTENT`, which requires an `XLOG_RUNNING_XACTS` record plus completion of all xacts listed as running. Primary's bgwriter logs one every ~15s via `LogStandbySnapshot()`, and those records are in the archive. `pg_log_standby_snapshot()` on the primary forces one on demand. On a quiet system, slot creation can block for minutes waiting for running xacts to drain — drive the primary with dummy writes and call `pg_log_standby_snapshot()` on a short interval during S0 testing. |
| G2 | Slot decodes WAL **generated after slot creation** (not just already-replayed WAL) | Unknown — critical | Do inserts on primary AFTER standby is set up and the slot exists, wait for archival, confirm they decode. See §3.4 constraint — only post-creation WAL is in scope. |
| G3 | Slot survives continued WAL replay without immediate invalidation | Unknown — **the dragon** | Once the slot exists its `catalog_xmin` horizon is pinned. If replay hits vacuum-on-catalog WAL past that horizon, the slot is invalidated. Also: if `max_slot_wal_keep_size` is set on the standby and the consumer falls behind, the slot is invalidated independently of catalog state. G3 must characterize both vectors. |
| G4 | Slot survives restart cycles | **Sprint 0 bar:** slot still exists after restart, slot catalog state is not corrupt, resumed consumption is explainable and bounded (no obvious skipped/duplicated changes when cross-referenced against what the primary emitted post-flush). Exact "no duplicates at LSN > `confirmed_flush_lsn`, no gaps at LSN ≤ `confirmed_flush_lsn`" semantics are the eventual goal but deferred to post-PoC when the consumer-interface choice is stable. | Kill the standby, restart, verify slot state is sane. Different consumer interfaces (`pg_logical_slot_get_changes()` SQL vs streaming replication protocol) have different persistence/flush semantics — Sprint 0 fixes on one path (`pg_logical_slot_get_changes()` for simplicity). |

**If G1 works but G2–G4 fail, the PoC scope changes materially** — the tool becomes a forensic-window decoder, not a continuous-replication substrate. That is still useful (US-2 alone is a paying market), but it should be a scope decision made with data, not an assumption.

#### 4.1.4 Known risks and mitigations

1. **Slot creation blocks waiting for `SNAPBUILD_CONSISTENT`.** `pg_create_logical_replication_slot()` does **not** return a transient error that the orchestrator can retry — it blocks inside `DecodingContextFindStartpoint()` and is interruptible via query cancellation. The correct orchestrator model: issue the call with a statement_timeout (or a background task + cancel-after-N-seconds), poll `pg_replication_slots` / standby logs for progress indicators, and surface "still waiting for consistency" clearly. To unblock faster, produce `XLOG_RUNNING_XACTS` records on the primary: `LogStandbySnapshot()` is called automatically by bgwriter (~every 15s), by checkpoints, and on demand via `pg_log_standby_snapshot()` (PG16+). `pg_switch_wal()` forces a WAL segment switch (useful for prompt archival) but does **not** by itself produce a running-xacts record. S0 loop: dummy writes + periodic `pg_log_standby_snapshot()` + optional `pg_switch_wal()`.

2. **`catalog_xmin` horizon conflicts invalidate the slot (project-level risk — see §3.4).** There is no `hot_standby_feedback` shield here; the primary has already vacuumed, the WAL record exists, replay will hit it. The only knob on the standby side is *when* we apply that WAL (throttled replay). Whether that's enough in practice is a Sprint 0 gate.

3. **`max_slot_wal_keep_size` on the standby as a separate invalidation vector.** Independent of catalog conflicts, a slot can be invalidated if the consumer falls behind and the standby's own WAL retention limit is hit. Sprint 0 decision: set `max_slot_wal_keep_size = -1`. Trade-off: with unlimited retention, a stalled consumer causes `pg_wal` on the standby to grow unboundedly, and when the disk fills the standby PANICs (`XLogWrite: could not write to file ...: No space left on device`) — an abrupt crash, not graceful degradation. Acceptable for Sprint 0 (local archive, dev hardware, operator-attended). **Deferred to Sprint 1:** pick a production mitigation — monitor `pg_wal` size and alert before PANIC, use a bounded `max_slot_wal_keep_size`, or mount `pg_wal` on its own generously-sized volume. The tool should surface slot `restart_lsn` lag prominently so operators see pressure building.

4. **Archive gaps / missing segments.** `restore_command` failure mid-decode will stall recovery. The standby will keep retrying. The orchestrator needs to detect this (replay LSN not advancing while consumer is waiting) and surface it clearly rather than hanging.

### 4.2 Phase 2 — Controlled Replay

**Goal:** Mitigate slot invalidation via coarse-grained pause/consume/resume control, and provide the paused-state inspection controller for US-4. Coarse-grained by design — per-record stepping is future work (see US-4 and §4.2.3); the user-story value does not depend on per-record granularity.

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

`pg_wal_replay_resume()` does **not** promote a standby running with `standby.signal` and no `recovery_target*`. Such a standby will never auto-promote on its own — if it runs out of WAL in the archive it keeps retrying `restore_command` and sleeps. `pg_wal_replay_resume()` simply clears the paused state; it does not change recovery mode or trigger promotion. Promotion requires explicit `pg_promote()`, a promote trigger file, or hitting a configured `recovery_target_*` with `recovery_target_action = 'promote'`.

**Real risks to watch:**

- **If the operator sets a `recovery_target_*` (for US-2),** then after hitting the target `pg_wal_replay_resume()` will continue past it; depending on `recovery_target_action` that may eventually promote. Rule: for US-2, use `recovery_target_action = 'pause'` (never `'promote'`), and once the slot is created and you resume, clear the target or rely on the absence of further targets to keep the standby following indefinitely.
- **Use `standby.signal`, never `recovery.signal`** (the latter signals archive-recovery ending at a target; the former signals indefinite standby mode).
- **Replay granularity is coarse.** The pause/resume cycle with `sleep(N)` does not give per-record control (see US-4 note). If the resumed window contains a catalog-invalidating record, the slot dies before you can consume. This is why "slot-aware replay throttling" matters as a future feature (§4.2.3).
- **Sanity check after resume:** `pg_is_in_recovery()` should remain `true` — if it ever returns `false`, something (a misconfigured target, an operator command) triggered promotion.

#### 4.2.3 Future: slot-aware replay throttling (mechanism TBD — core patch territory)

The *need* is concrete: we want the startup process to be able to pause replay before applying a WAL record that would invalidate an existing logical slot's `catalog_xmin`. The PoC provides a coarse approximation via user-space pause/resume, but that loop cannot see the next record about to be applied — by the time we pause, damage may already be done.

An earlier sketch of this doc proposed a user-defined plpgsql function (`recovery_target_function`) invoked by the startup process per-record. That proposal has serious feasibility problems:

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
1. **Validates input** (see 4.4.1 below).
2. Copies backup to temp directory.
3. Configures `restore_command`, `standby.signal`, `hot_standby = on`, `max_slot_wal_keep_size = -1` (no `hot_standby_feedback` — see §3.4 / §4.1.1 notes).
4. For US-2: sets `recovery_target_lsn = L_start` + `recovery_target_action = 'pause'` to land the standby at `L_start`. (Reminder: `recovery_target_*` are `PGC_POSTMASTER`; they cannot be reloaded at runtime.)
5. Starts PostgreSQL on `--pg-port`.
6. Waits for hot standby.
7. Creates the logical slot at the paused position (call may block for minutes — use timeout + progress polling, not retry).
8. Calls `pg_wal_replay_resume()`. Replay continues past `L_start`; the target GUC becomes inert and is not touched again.
9. Orchestrator polls `pg_last_wal_replay_lsn()`. When it reaches `L_end` (for US-2) or indefinitely (for continuous modes), calls `pg_wal_replay_pause()`.
10. Drains the slot via the consume loop.
11. Applies filters, writes output.
12. Tears down standby (if `--cleanup`).

#### 4.4.1 Input validation (pre-flight)

The tool should fail fast with a clear diagnostic before any standby is provisioned:

- `--backup-path` exists and contains expected files (`backup_label`, `PG_VERSION`, `global/`, etc.).
- `--backup-path` is readable; required files are not zero-length.
- For US-2 mode: `--from-time` or `--from-lsn` is **after** the base backup's start (read from `backup_label`). Decoding from before the backup is not recoverable.
- For US-2 mode: `--to-time > --from-time` (or `--to-lsn > --from-lsn`). Zero-length windows are probably a user error.
- `--wal-archive` is readable. The earliest segment needed (derivable from `backup_label`'s `START WAL LOCATION`) is present. Scan for obvious gaps in the segment sequence covering the decode window; warn loudly if detected.
- `--pg-port` is free.
- `--output-file` path is writable.
- `--filter-config` (if supplied) parses and all referenced tables/columns are plausible (don't verify until the slot exists, since catalogs may have evolved).

None of this is stylistic — any one of these failing silently late in the pipeline costs minutes or hours of wasted standby bring-up.

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
| Paused-state inspection controller (US-4) | Integration tests | pytest + Docker | Verify pause-at-LSN → hook → advance → hook cycle holds across multiple iterations. |
| Slot invalidation scenarios | Integration tests | pytest + Docker | DDL on primary, verify standby behavior. |

### 5.2 CI test matrix

Per-scenario version gating: the `postgres-versions` list is the default set for each scenario, but individual scenarios may restrict or extend (e.g., `sequence-replication` is PG18+ only). CI implementers should honor per-scenario gating rather than running every scenario on every version — mismatches are expected and not bugs.

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
      # Sprint 0 uses a softer bar (§4.1.3 G4): slot still exists after restart,
      # catalog state not corrupt, resumed consumption is explainable and bounded.
      # The strict bar below is the post-consumer-interface-choice target that
      # applies once Sprint 1+ settles on the streaming replication protocol
      # consumer path (different flush/persistence semantics than the SQL interface).
      pass: slot state is sane; on resume the consumer sees all changes with LSN > confirmed_flush_lsn that were already decoded, and never changes with LSN <= confirmed_flush_lsn (those are already acknowledged)

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

### Sprint 0 — Validate Foundation (3 weeks, with early-exit)

> **Tracking issue:** [NikolayS/postgres#25](https://github.com/NikolayS/postgres/issues/25).

**Budget:** task day-sums are 11.5d without the contingent S0-8 (internals deep-dive) and 14.5d with it, allocated to 3 weeks (15d) on the Gantt. Early exit: if G1–G4 all pass cleanly by day 8, close Sprint 0 and move to Sprint 1.

Sprint 0 answers four gates, not one (see §4.1.3): slot creation, decode of post-creation WAL, slot survives replay progress, slot survives restart. If any gate hits an obstacle that requires a `snapbuild.c` / `standby.c` source-level investigation, allocate days, not hours.

**Scope the MVP narrowly** — this is a feasibility experiment, not a product build:

- Single PG version (pick one, likely PG17 for broadest applicability).
- Local archive directory, not S3 (network variables add noise).
- `test_decoding` plugin only.
- One append-only table with a primary key.
- No DDL during the window.
- Dummy-write loop on primary during the whole experiment (forces `XLOG_RUNNING_XACTS` records to stream into the archive promptly).

| Task | Owner | Depends on | Days |
|------|-------|------------|------|
| S0-1: Set up PG17 primary with `wal_level=logical`, `archive_mode=on`, local archive dir. Drive with dummy writes + periodic `pg_log_standby_snapshot()` (forces `XLOG_RUNNING_XACTS` into the archive on demand) + optional `pg_switch_wal()` (forces prompt segment archival — note: does **not** by itself emit a running-xacts record, contrary to v0.2 wording) | Internals eng | — | 0.5 |
| S0-2: Take `pg_basebackup`, create test table with PK, insert starter rows, let archive catch up | Internals eng | S0-1 | 0.5 |
| S0-3: Provision standby with `restore_command`, `standby.signal`, `hot_standby=on`, `max_slot_wal_keep_size=-1`, no `hot_standby_feedback`, and (for US-2-style tests) `recovery_target_action='pause'` with a chosen `recovery_target_lsn`. For continuous tests, no `recovery_target*`. | Internals eng | S0-2 | 0.5 |
| S0-4 **(Gate 1)**: `pg_create_logical_replication_slot('archive_decoder', 'test_decoding')` succeeds. The call **blocks** inside `DecodingContextFindStartpoint()` — orchestrator must use statement_timeout (or background-task + cancel-after-N-seconds), poll `pg_replication_slots` and standby logs for progress, and surface "still waiting for `SNAPBUILD_CONSISTENT`" clearly. No retry loop — blocking is the expected behavior. | Internals eng | S0-3 | 1 |
| S0-5 **(Gate 2)**: After slot creation, do fresh inserts on primary, archive, confirm decode of post-creation WAL. Only post-creation WAL is in scope (see §3.4). | Internals eng | S0-4 | 1.5 |
| S0-6 **(Gate 3)**: Characterize slot invalidation under three explicit scenarios (see "G3 reproducer scenarios" below). **This is the dragon** — it determines Outcome A vs Outcome B (see "two possible outcomes" below). | Internals eng | S0-5 | 4.5 |
| S0-7 **(Gate 4)**: Restart the standby mid-decode. Resume consumption via `pg_logical_slot_get_changes()` (Sprint 0 fixes on this interface). Verify slot still exists, catalog state sane, resumed consumption explainable. Exact duplicate/gap semantics deferred to post-PoC. | Internals eng | S0-5 | 1 |
| S0-8: If any gate fails unexpectedly, read `snapbuild.c` / `standby.c` / `slot.c` with debugger; map exact error codes; decide scope | Internals eng | any gate | 3 |
| S0-9: Write Sprint 0 findings — land as a new appendix + v0.6 changelog entry on this spec (v0.5 is this pre-Sprint-0 revision, so findings cannot live inside it). For each gate: pass/fail, observed behavior, interpretation matrix outcome, scope implication | All | S0-7 | 2 |

**Early-exit rule:** if G1–G4 all pass cleanly by day 8, declare Sprint 0 done and move to Sprint 1. The 3-week budget exists to absorb investigation time if a gate fails in a non-obvious way and to give G3 its full 4.5-day characterization window without pressure to compress.

**Gate interpretation matrix** — for each gate, concrete failure symptoms mapped to scope impact:

| Observed failure | Interpretation | Scope impact |
|------------------|----------------|--------------|
| G1: slot creation never reaches consistency before statement_timeout despite snapshot forcing and replay progress | `SNAPBUILD_CONSISTENT` not reachable from archive alone — missing some condition present on streaming standbys (recall that `pg_create_logical_replication_slot()` **blocks** inside `DecodingContextFindStartpoint()`; it does not return a transient error we could retry) | Likely a core patch needed before anything else; PoC pauses |
| G1: slot creation works but only after `pg_log_standby_snapshot()` on primary at archive time | Dependency on primary cooperation | Tool must document this requirement; acceptable constraint |
| G2: slot created but no decoded changes for post-creation WAL | Archive replay isn't advancing past slot's LSN (or decoding is silently empty) | Instrumentation / config issue, not scope change |
| G3: slot invalidated within minutes of replay | Catalog vacuum records invalidate `catalog_xmin` quickly under normal load | Scope shrinks to narrow forensic windows; US-1 continuous use at risk |
| G4: slot state corrupt after restart | Unexpected; would be a PG bug | Escalate to pgsql-hackers, pause PoC |

#### Sprint 0 — G3 reproducer scenarios

G3 is the gate most likely to reshape the project. The v0.2 language ("moderate catalog churn") was insufficient — a reviewer noted that slot invalidation isn't triggered by catalog DDL per se; it's triggered by replay of **vacuum-on-catalog** WAL records (`xl_heap_prune`/`xl_heap_vacuum`/`xl_btree_vacuum` against catalog relations past the slot's `catalog_xmin`). The orchestrator needs to provoke those records deterministically on the standby. Three scenarios, run in order:

**G3-A: Low-churn baseline.** Primary runs a steady INSERT-only workload on a non-catalog table with autovacuum defaults. Measure time-to-invalidation (if any) over a 1-hour window. *Purpose: establish the floor. If the slot invalidates here, the PoC is probably dead for continuous use before we even stress it.*

**G3-B: Temp object churn (the standard trigger).** Primary runs a loop creating and dropping many temp tables and functions (e.g., 100–1000/minute), generating dead tuples in `pg_class`, `pg_attribute`, `pg_type`, `pg_proc`. Leave autovacuum active. Measure time-to-invalidation. *Purpose: this is the normal case on many real workloads; if the slot can't survive this, US-1 is dead.*

**G3-C: Forced catalog vacuum (stress).** After slot creation, primary runs `VACUUM pg_class; VACUUM pg_attribute; VACUUM pg_type; VACUUM pg_proc` explicitly, with dead tuples already present. Measure time-to-invalidation on the standby as those vacuum WAL records replay. *Purpose: direct reproducer of the worst case. Establishes "yes this does kill the slot" or "the slot survived this too, which is surprising."*

For each scenario: record time from slot creation to invalidation (or "survived N minutes, still alive"), the exact slot state from `pg_replication_slots` at failure, and the WAL LSN + record type that caused the conflict (from logs — the standby emits a distinctive message on `InvalidatePossiblyObsoleteSlot`). Output a small data table: scenario → MTTI → trigger record.

**Success definition for G3:** not a binary pass/fail, but a characterization. The decision is "under what workload regime (if any) can this approach sustain a slot indefinitely?" The answer drives the "two possible outcomes" scope-split below.

**Decision thresholds:**

| Observation | Interpretation | Outcome |
|-------------|----------------|---------|
| Slot survives G3-A **and** G3-B for ≥1 hour without invalidation (with or without replay throttling) | The continuous-decode path is credible for at least moderate-churn OLTP workloads | **Outcome A** — continuous viable |
| Slot survives G3-A but dies quickly (minutes) in G3-B | US-1 continuous replication not viable under any realistic catalog churn; forensic windows still useful | **Outcome B** — forensic only |
| Slot survives G3-B but dies under G3-C | Continuous use may be possible with narrow workload assumptions (no explicit catalog VACUUMs, autovacuum-tuned primaries); document the constraint clearly | **Outcome A with caveats** — continuous viable for restricted workloads |
| Slot dies in G3-A (low-churn baseline) | Unexpected; something fundamental is wrong, not workload-dependent | Escalate — investigate before declaring Outcome B |

"Quickly" in this table means <10 minutes; "sustained" means ≥1 hour. These are first-pass thresholds; Sprint 0 may refine them based on what the data actually looks like.

#### Sprint 0 — out of scope (explicit)

To prevent scope creep into Sprint 0, the following are **deliberately not tested** in Sprint 0 and any related claim is deferred:

- S3 / cloud-storage `restore_command` (local archive only).
- `pgoutput` plugin (sprint-0 uses `test_decoding` only — plugin migration is Sprint 1).
- DDL tolerance (no DDL during G1–G4).
- Sequence decoding (PG18-specific; Sprint 3 ancillary test).
- Two-phase commit decoding.
- Large-transaction streaming (`logical_decoding_work_mem` spill path).
- Concurrent consumers on the same slot.
- Consumer via streaming replication protocol (Sprint 0 uses `pg_logical_slot_get_changes()` SQL interface).
- Any promise of continuous replication.

The purpose of Sprint 0 is to answer feasibility, not to demo a product. These items return in Sprint 1–3 after the gates are known.

#### Sprint 0 — two possible outcomes (scope split)

Sprint 0 doesn't just pass or fail — it splits the project into one of two futures, and the team composition and remaining sprints look different in each. Make this explicit before Sprint 0 starts so that the post-Sprint-0 planning session is fast.

**Outcome A: continuous decode viable.** G1 passes, G2 passes, G3 demonstrates that the slot survives at least a realistic operational window (hours under low-churn, survives temp-object-churn with some throttling mitigation), G4 passes.
- US-1 (decouple continuous replication from primary): in scope.
- US-2 (windowed extraction): in scope, easy case.
- US-3 (PII-free staging): in scope.
- US-4 (correctness verification): in scope — the paused-state inspection primitive is not contingent on Sprint 0 outcome. See §2 US-4.
- Sprints 1–3 proceed roughly as planned.

**Outcome B: forensic-only viable.** G1 passes, G2 passes, G3 shows the slot is invalidated quickly (minutes) under anything but the lightest workload, G4 passes.
- US-1: **at serious risk**. Not removed, but demoted to "for low-churn OLTP only, with explicit workload caveats." May be cut.
- US-2 (windowed extraction): **the primary surviving use case**. Phase 3 refocuses on this.
- US-3: at risk (relies on same continuous-slot assumption as US-1). May be cut or reframed.
- US-4: narrows substantially — the continuous-replication demo goes away — but the paused-state inspection primitive may still be useful for internal debug / correctness workflows. Keep as an internal tool, don't feature in the shipped product positioning.
- Sprint 1 becomes a US-2-focused sprint. Sprint 2 DDL testing narrows to whether DDL affects US-2 windows. Sprint 3 CLI becomes a forensic-extraction CLI, not a CDC tool.

**Outcome C (unlikely): total failure.** G1 doesn't pass on any configuration. Escalate as a pgsql-hackers problem statement; PoC pauses pending core-level investigation. Spin down the team until the investigation completes.

The decision of "A vs B" is made in the S0-9 findings write-up, based on the characterization from G3-A/B/C.

#### Sprint 0 — observability requirements

Before Sprint 0 starts, wire up capture for these signals. Without them, a failed gate is frustrating to interpret post-hoc.

- **Standby logs** at `log_min_messages = debug1` or higher for the replication/recovery subsystem. Rotate aggressively.
- **Periodic snapshots of `pg_replication_slots`** (every 10s): columns `slot_name`, `active`, `xmin`, `catalog_xmin`, `restart_lsn`, `confirmed_flush_lsn`, `wal_status`, `safe_wal_size`, `conflicting`, `invalidation_reason` (PG17+). Stored as a CSV time-series. **G1-specific interpretation:** during slot creation blocking, `catalog_xmin` null = snapshot builder hasn't started; `catalog_xmin` populated + `confirmed_flush_lsn` null = scanning WAL for consistency; both populated = slot ready. Surface this as "waiting for snapshot consistency / scanning WAL / ready" during orchestrator polling instead of a bare "still blocked" message. If `catalog_xmin` lags behind the primary's current `xmin`, an uncommitted primary transaction is holding the horizon — warning sign for G3.
- **Periodic replay LSN progression**: `pg_last_wal_replay_lsn()`, `pg_last_wal_receive_lsn()` (should be NULL on archive-only), `pg_wal_replay_paused()`.
- **LSN-gap metric:** track `pg_last_wal_replay_lsn()` minus slot's `restart_lsn`. When that gap's byte-size approaches the standby's `pg_wal` volume size, we're on the trajectory toward a `pg_wal`-full PANIC (see §4.1.4 risk 3). Early-warning threshold: 60% of volume size. This is the key operational signal that distinguishes "consumer is catching up" from "consumer will crash the standby."
- **`restore_command` activity**: count of retries, timings per segment, failures. Tail `restore_command` stderr into its own log. The orchestrator should parse this and expose "waiting for segment N" clearly.
- **Error codes verbatim** on any ERROR from the standby. Don't paraphrase — committers will ask for exact codes.
- **WAL segment names and timestamps** around events of interest (slot creation, G3 invalidation event, G4 restart). Let someone reading the report reconstruct the timeline.
- **Primary-side: `pg_stat_activity`, `pg_locks`, `pg_stat_all_tables` for catalog relations** at capture intervals. Helps correlate "what did the primary do that triggered the invalidation."

The observability capture is a one-time investment (a small Python script + a docker-compose log aggregator) and is reusable for Sprint 2 slot-invalidation testing.

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

**Goal:** Handle DDL (non-rewriting and rewriting), build a slot-invalidation cookbook, and land the paused-state inspection controller for US-4.

| Task | Owner | Depends on | Days | Parallelizable |
|------|-------|------------|------|----------------|
| S2-1: Controlled replay script (pause → consume → resume loop — batch granularity, not per-record; see US-4 correction) | Internals eng | Sprint 1 ✓ | 3 | — |
| S2-2: Test: DDL during decode window — split into two subtasks | Internals eng | S2-1 | 5 | ∥ with S2-3 |
| &nbsp;&nbsp;S2-2a: Non-rewriting DDL (ADD COLUMN, DROP COLUMN, RENAME) | Internals eng | S2-1 | 2 | — |
| &nbsp;&nbsp;S2-2b: Rewriting DDL (ALTER TYPE, VACUUM FULL, CLUSTER) — historic catalog snapshot stress; this is where novel risk lives | Internals eng | S2-2a | 3 | — |
| S2-3: Test: slot invalidation scenarios — detect and report gracefully; build a small invalidation cookbook (which primary ops cause it, on what timescales) | DBA | S2-1 | 3 | ∥ with S2-2 |
| S2-4: US-4 paused-state inspection controller — pause-at-LSN + user-hook + bounded-advance loop; example hooks: `amcheck`, cluster-wide row counts. Coarse-grained, not per-record (see US-4). | Internals eng | S2-1 | 2 | — |
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

### Gantt overview

```
Week:     1        2        3        4        5        6        7        8        9
          ├────────┼────────┼────────┼────────┼────────┼────────┼────────┼────────┤
Sprint 0: ████████████████████████
Sprint 1:                          ████████████████
Sprint 2:                                          ████████████████████
Sprint 3:                                                                ██████████
```

**Total: ~9 weeks to usable PoC.** Early Sprint 0 exit (all four gates pass cleanly by day 8) pulls this in to ~8 weeks.

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

13. [@x4m](https://github.com/x4m) (Andrey Borodin), Postgres.tv hacking session — architectural input for this PoC: https://www.youtube.com/watch?v=LjiU6kB6izw (transcription by [Circleback.ai](https://circleback.ai))

14. Sprint 0 execution on lab VM — full raw evidence, reproducer scripts, and 35+ comments of review: https://github.com/NikolayS/postgres/issues/25

---

## 10. Sprint 0 Execution Findings (added in v0.6)

Sprint 0 was executed on a lab VM with PostgreSQL 18.3 (PGDG Ubuntu 24.04) and cross-validated on PG17.9. Three reproducer scripts committed to the blueprint repo; ~35 comments on [issue #25](https://github.com/NikolayS/postgres/issues/25) capture the full iteration history and raw data.

### 10.1 Gate-by-gate results

| Gate | Outcome | Evidence |
|------|---------|----------|
| **G1** — slot creation on archive-only standby | **PASS** | `pg_create_logical_replication_slot()` succeeds (< 4 s) once primary produces `XLOG_RUNNING_XACTS` records. Verified on PG17 + PG18. |
| **G2** — decode post-creation WAL | **PASS** | INSERT/UPDATE/DELETE decoded correctly. REPLICA IDENTITY FULL emits full old-tuple for DELETEs — blueprint's caveat validated. |
| **G3** — slot survives replay progress | **FAIL by design** | Under any autovacuum-enabled workload, `Heap2/PRUNE_ON_ACCESS` records on `pg_statistic` (rel 1663/5/2619) trigger `InvalidatePossiblyObsoleteSlot()` when their `snapshotConflictHorizon` crosses the slot's `catalog_xmin`. MTTI 30–126 s natural, ~3 s deterministic with forced `VACUUM pg_statistic`. Identical trigger mechanism on PG17 and PG18. |
| **G4** — slot survives restart | **PASS** | `(catalog_xmin, restart_lsn, confirmed_flush_lsn)` preserved exactly across fast-shutdown + restart. Resumed consumption delivers post-`confirmed_flush_lsn` changes once, no duplicates/gaps. |

### 10.2 G3 MTTI characterization (raw data from issue #25 runs)

| Scenario | Autovacuum | Primary workload | MTTI |
|----------|-----------|------------------|------|
| Control | **off** | 1 INS/sec on non-catalog table | **> 600 s (not invalidated in 10 min observation)** |
| G3-A baseline | on, default `naptime=60s` | 1 INS/sec | ~126 s |
| G3-A amplified | on, `naptime=10s` | 2 INS/sec | ~44 s |
| G3-B temp-object churn | on, default | ~100 temp CREATE/DROP per sec | ~30 s |
| G3-C forced catalog VACUUM | on, default | + explicit `VACUUM pg_statistic` | **~3 s (deterministic)** |
| **v0.7 300s ceiling (baseline)** | on, default | sustained OLTP for 300 s | invalidation at LSN 0/33004780 ≈ t+138s ([raw evidence](https://github.com/NikolayS/postgres/issues/25#issuecomment-4260569185)) |
| **v0.7 300s ceiling (tuned primary)** | on, **`naptime=600s`** | same 300 s OLTP | **survived full window, 30 413 rows decoded, 501 DELETEs** ([raw evidence](https://github.com/NikolayS/postgres/issues/25#issuecomment-4260731579)) |

**Mechanism in every case**: `Heap2/PRUNE_ON_ACCESS` on `pg_statistic` (rel 1663/5/2619), `isCatalogRel: T`, `snapshotConflictHorizon >= slot.catalog_xmin`. Invalidation reason: `rows_removed`. No `hot_standby_feedback` channel shields an archive-only standby (correctly identified in §3.4 as a silent no-op in this configuration).

### 10.3 US-2 working recipe validation

The §2 US-2 recipe (gated-archive + quiet-moment snapshot) **works end-to-end with the primary dead during recovery**. Reproducer: [`blueprints/repro_us2_deadprim.sh`](repro_us2_deadprim.sh).

Representative run (60-second sustained-OLTP window, primary killed before recovery):

```
slot created at 12:42:01, restart_lsn=0/5000000, catalog_xmin=755
replay past L_end (0/1B000000): 2 seconds for 352 MB of WAL on local disk
slot drain: 5811 total changes, 98 DELETEs including full old-tuple data

 lsn     | xid  |                                                            data
---------+------+------------------------------------------------------------------------------------------------
0/1A000868 | 2658 | table public.orders: DELETE: id[integer]:3 customer[text]:'carol' amount[numeric]:9.99
0/1A0008B8 | 2658 | table public.orders: DELETE: id[integer]:6 customer[text]:'busy-0' amount[numeric]:0
 ...
```

Slot creation took ~1 second. Replay advanced linearly (~176 MB/sec local disk).

### 10.4 US-1 verdict: requires core patch

**US-1 continuous CDC is not viable in the blueprint's archive-only architecture without a core patch.** The G3 failure fires deterministically under any write-active primary; the earliest bypass the community has discussed (Ringer 2020, Kukushkin 2025) solves adjacent but different problems (walsender archive fetch, primary-side WAL retention). A new problem statement is drafted in issue #25 ([comment 4260187347](https://github.com/NikolayS/postgres/issues/25#issuecomment-4260187347)) proposing a standby-side GUC `recovery_pause_on_logical_slot_conflict` that pauses replay before applying a WAL record that would invalidate any active logical slot's `catalog_xmin` horizon. TBDs prior to external posting: human sanity-check of the mechanism description (blueprint's architecture lead). `two_phase`, failover-slot, and synced-slot interactions verified as requiring no special handling via PG18 source inspection (issue #25 [comment 4260312575](https://github.com/NikolayS/postgres/issues/25#issuecomment-4260312575)).

### 10.5 Outcome determination

Per the blueprint's §7 scope-split:

- **Outcome A (continuous US-1)**: not viable without core patch. Elevated to `Future Work > §8.1` as the primary unblocker.
- **Outcome B (windowed US-2)**: **viable with the corrected recipe in §2.** Production-side prerequisite (periodic `pg_log_standby_snapshot()` at quiet moments) is a hard requirement, documented in §11.
- **Outcome C**: not reached.

The project is a real shippable forensic-recovery product. Sprints 1–3 focus on tool-building around the US-2 workflow and the companion reproducers.

### 10.6 Reproducer scripts

Committed to this repository for reviewer verification:

- [`blueprints/repro_g3.sh`](repro_g3.sh) — deterministic G3 invalidation in ~20 s.
- [`blueprints/repro_us2_gated.sh`](repro_us2_gated.sh) — US-2 with live primary and continuous primer.
- [`blueprints/repro_us2_deadprim.sh`](repro_us2_deadprim.sh) — US-2 with **dead primary**. The recipe that backs §2 US-2.

All scripts self-contained (~150 lines each), run under an unprivileged user on any Ubuntu host with PGDG PG18 installed, and complete in ≤ 2 minutes.

### 10.7 Static ceiling analysis tool (added in v0.7)

[`blueprints/wal_archive_ceiling.sh`](wal_archive_ceiling.sh) — given an existing WAL archive directory, reports two LSNs that fully determine the US-2 viability of that archive:

- **path-(a) anchor** — earliest `XLOG_RUNNING_XACTS` with `oldestRunningXid == nextXid`, i.e. the earliest LSN at which `snapbuild.c` can bootstrap a logical slot in one step via path (a) of `SnapBuildFindSnapshot`.
- **MTTI ceiling** — first `Heap2/PRUNE_ON_ACCESS` on a catalog relation at-or-after the anchor that would invalidate the slot during replay. Per-database via `--db <oid>` (logical slots are per-database; the check in `InvalidatePossiblyObsoleteSlot` is gated by `slot->data.database`, so prunes in other databases are irrelevant).

Byte-distance between the two is the archive's practical US-2 window.

**Validation:** run against the real 300s-window failed-recovery archive, compared against the standby's actual invalidation LSN:

| | Tool prediction (`--db 5`) | Standby invalidation |
|---|---|---|
| LSN | `0/33004780` | `0/33004780` |
| snapshotConflictHorizon | 3383 | 3383 |
| rel | 1663/5/2619 (pg_statistic in postgres) | 1663/5/2619 |
| block | 18 | 18 |

Full raw evidence on [issue #25](https://github.com/NikolayS/postgres/issues/25#issuecomment-4260999478).

This closes the loop for operator workflow: run the tool on an archive **before** committing to recovery, get a go/no-go answer (and the precise LSN the paused-recovery GUC proposal would need to stop at once it lands).

---

## 11. Production-Side Prerequisites (added in v0.6)

### 11.1 `pg_log_standby_snapshot()` backgrounder on the primary

Required for US-2 recovery to succeed without live-primary access during recovery. The prerequisite is a small, low-frequency backgrounder that calls `SELECT pg_log_standby_snapshot();` during quiet moments.

**Implementation options:**

| Option | Pros | Cons |
|--------|------|------|
| Cron job on primary, hourly | Trivial to set up. | Only fires at scheduled times, regardless of activity. |
| Triggered by `pg_cron` with quiet-detection | Integrated into PG. | Requires pg_cron extension. |
| External service watching `pg_stat_activity` | Fires opportunistically when no xacts are running — always produces path-(a) record. | Requires separate service. |

**Minimum viable:**

```sql
-- cron: 0 * * * * (every hour at :00)
SELECT pg_log_standby_snapshot();
```

Even a single call per hour provides a recovery anchor that's usable for forensic windows up to several hours later, as long as the archive retains those segments.

**Operator also logs**: timestamp + LSN of each call, so incident responders can identify the nearest `L_QUIET` without scanning the archive.

### 11.2 WAL archive continuity

Archive retention must cover the longest forensic window the operator cares about. For a 1-hour window at ~100 MB/min of WAL (realistic OLTP), that's 6 GB. Standard backup tools (WAL-G, pgBackRest) handle this natively.

### 11.3 Base backup cadence

Operator must retain a base backup predating the oldest L_QUIET they want to recover to. For hourly quiet-moment snapshots and weekly base backups, any incident within the past 7 days is recoverable.

### 11.4 What is NOT required

- `hot_standby_feedback` on the production primary-to-standby channel (irrelevant for archive-only architecture; documented in §3.4).
- Live primary access during incident response (validated in §10.3).
- A long-lived logical slot on the primary (that would recouple us to production; the blueprint's point).

### 11.5 Primary-side autovacuum tuning (added in v0.7)

The US-2 practical window ceiling is controlled **entirely by the primary's autovacuum cadence at WAL-generation time**. The invalidating records (`Heap2/PRUNE_ON_ACCESS` with `snapshotConflictHorizon` on catalog relations) are baked into the primary's WAL; no standby-side GUC alters what's already on disk.

**Rule of thumb:** for an N-second recoverable US-2 window on the primary's default configuration:

> `autovacuum_naptime ≥ 2 × N`

or equivalently, schedule autovacuum suppression on catalog relations for the planned window duration.

**Validated:** §10.2 rows "v0.7 300s ceiling (baseline)" vs "v0.7 300s ceiling (tuned primary)" — identical workload, the only difference being `autovacuum_naptime`. With 60s default → invalidation at t≈138s; with 600s → survived the full 300s window.

**Beyond the tuning limit:** arbitrary-window recovery requires the proposed paused-recovery GUC (see §4.2.3 / Future Work §8.1). Until that lands, operators should use `blueprints/wal_archive_ceiling.sh --db <oid>` to discover the actual ceiling of a given archive up-front rather than discovering it mid-incident.

---

## 12. Sprint 1 Core Patch: `recovery_pause_on_logical_slot_conflict` (added in v0.8)

The §4.2.3 / §8.1 "slot-aware replay throttling" direction has been implemented as a 215-line prototype on `blueprint/logical-decoding-archived-wals`. This section documents the shipped mechanism.

### 12.1 What it does

Adds a `PGC_SIGHUP` bool GUC, default off. When enabled, and the WAL replay on a standby is about to apply a record that would invalidate an active logical replication slot in the same database via `RS_INVAL_HORIZON` (a `Heap2/PRUNE_ON_ACCESS` on a catalog relation with `snapshotConflictHorizon >= slot.catalog_xmin`), replay pauses instead.

The operator can then drain the slot via `pg_logical_slot_get_changes` and call `pg_wal_replay_resume()`. On resume, the patch advances the drained slot's `catalog_xmin` past the conflict horizon so the subsequent invalidation call is a no-op; replay continues to the next conflict, and the cycle repeats. Continuous CDC from an archive-only standby becomes viable.

### 12.2 Implementation

Single hook point in `ResolveRecoveryConflictWithSnapshot()` (`src/backend/storage/ipc/standby.c`, line 505):

```c
if (IsLogicalDecodingEnabled() && isCatalogRel)
{
    MaybePauseOnLogicalSlotConflict(locator.dbOid, snapshotConflictHorizon);
    InvalidateObsoleteReplicationSlots(RS_INVAL_HORIZON, 0, locator.dbOid,
                                       snapshotConflictHorizon);
}
```

`MaybePauseOnLogicalSlotConflict()`:

1. Return early if GUC off.
2. Scan replication slots under `LW_SHARED` on `ReplicationSlotControlLock`. For each slot in `dboid` that has reached `SNAPBUILD_CONSISTENT` (its `effective_catalog_xmin` is valid) and whose `catalog_xmin` `TransactionIdPrecedesOrEquals` the conflict horizon → `would_invalidate = true`.
3. If no such slot → return (fall through to normal invalidation, which will also be a no-op for different reasons).
4. Else `SetRecoveryPause(true)` and wait on `XLogRecoveryCtl->recoveryNotPausedCV` with `ConditionVariableTimedSleep`, calling `ConfirmRecoveryPaused()` each tick so SQL-level observers see `paused` not `pause requested`.
5. On resume (operator called `pg_wal_replay_resume()`), scan slots again. For each slot in `dboid` with `confirmed_flush_lsn >= current_replay_lsn` and `catalog_xmin <= horizon`, advance `catalog_xmin` and `xmin` (and their `effective_` counterparts) to `TransactionIdAdvance(horizon)` — strictly past the horizon. Mark slot dirty. The fall-through `InvalidateObsoleteReplicationSlots` now finds nothing to invalidate.

### 12.3 Edge cases handled

- **In-progress slot** (still inside `DecodingContextFindStartpoint`): skipped. An in-progress slot has not produced output; invalidation is harmless. Pausing for it would deadlock — snapbuild needs WAL to advance, the pause holds WAL back.
- **Operator ignores the pause**: fall-through invalidation fires as it would without the GUC. No state corruption, slot is lost.
- **Off-by-one vs `DetermineSlotInvalidationCause`**: we use `TransactionIdPrecedesOrEquals` in the pause-trigger check to match the invalidation semantics. Without that, a slot whose `catalog_xmin` was just advanced to `horizon+1` by a previous pause would fail to trigger a pause on the next record whose horizon is `horizon+1`, yet would still be invalidated by the fall-through (which uses `PrecedesOrEquals`).

### 12.4 Validation

**TAP test** `src/test/recovery/t/050_recovery_pause_on_slot_conflict.pl` lands passing: 5/5 assertions (GUC registered, slot consistent in clean phase, slot survives prune replay, ≥1 pause handled, ≥2000 decoded events). Two-phase flow so the slot is fully consistent before catalog-prune WAL lands in the archive. ~36s runtime.

**Bash end-to-end demo** `/tmp/us1_v2.sh` on the lab VM: 45 469 decoded events = 3 × 15 153 primary INSERTs (100% coverage), 2 pause events handled, final slot `wal_status=reserved`.

**Regression sweep**: 102 existing tests pass including `006_logical_decoding`, `010_logical_decoding_timelines`, `019_replslot_limit`, `028_pitr_timelines`, `038_save_logical_slots_shutdown`, `040_standby_failover_slots_sync` (PG18 synced slots), and `contrib/test_decoding` (14 SQL + 6 TAP).

### 12.5 Files and lines changed

| File | Lines |
|---|---|
| `src/backend/storage/ipc/standby.c` | +158 (new `MaybePauseOnLogicalSlotConflict`) |
| `src/backend/access/transam/xlogrecovery.c` | +15 (variable declaration + rationale; `ConfirmRecoveryPaused` no longer static) |
| `src/backend/utils/misc/guc_parameters.dat` | +8 (GUC entry) |
| `src/backend/utils/misc/postgresql.conf.sample` | +2 (doc line) |
| `src/include/access/xlogrecovery.h` | +2 (`extern` for variable + `ConfirmRecoveryPaused`) |
| `src/include/storage/standby.h` | +2 (`MaybePauseOnLogicalSlotConflict` prototype) |
| `src/test/recovery/t/050_recovery_pause_on_slot_conflict.pl` | +218 (new TAP test) |
| **Total** | **~215 lines core C + ~218 lines TAP = ~435 lines** |

### 12.6 Remaining work before posting to pgsql-hackers

- Confirm behavior under `--enable-injection-points` build (lab VM build doesn't have it, gating the two invalidation-injecting tests).
- Add a GUC-off baseline assertion to TAP (currently only exercises GUC-on).
- Prepare the patch series as `git format-patch -5` with email-ready commit messages.
- Send to pgsql-hackers with a problem statement that cites this blueprint and issue #25 for the workload / MTTI / ceiling data.

### 12.7 Relationship to blueprint directions

§4.2.3 ("slot-aware replay throttling, mechanism TBD") is now **concrete**. Future Work §8.1 becomes **in-flight**.

Outcome A (continuous US-1 viable) is the shipping scope: unpatched PG is the Outcome B fallback via §2 US-2 / §10.3 gated-archive recipe; patched PG adds arbitrary-window US-1 on top.

