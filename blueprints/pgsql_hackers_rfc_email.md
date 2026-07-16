# Draft email for pgsql-hackers

Subject: `[PATCH] Pause recovery on logical slot conflict (for archive-only logical decoding)`

Hi hackers,

I would like to propose a small GUC, `recovery_pause_on_logical_slot_conflict`, to
enable a use case the PostgreSQL recovery path does not currently
support: continuous logical decoding from a standby that consumes only
archived WAL (no streaming replication link to the primary).

Two patches on a branch at
https://github.com/NikolayS/postgres/tree/rfc-v1-recovery-pause-on-slot-conflict.
Squashed to 2 commits for reviewability, generated with `git
format-patch`: 0001 is the core change (6 files, 216 insertions), 0002
is a new `src/test/recovery/t/050_...` TAP test (~247 lines).

## Problem

On PG16+, you can create a logical replication slot on a standby. If
the standby is also receiving streaming replication and forwards
`hot_standby_feedback`, the primary holds its catalog horizon back and
everything works as expected.

But an **archive-only** standby — one that was started from a base
backup and uses `restore_command` without a streaming connection — has
no way to signal back to the primary. It has no walreceiver, so
`hot_standby_feedback` is a silent no-op. The primary keeps running
autovacuum; vacuum-on-catalog records accumulate in the WAL archive;
when the standby replays them, its logical slot's `catalog_xmin` gets
overtaken by the records' `snapshotConflictHorizon` and
`InvalidateObsoleteReplicationSlots()` kills the slot.

Empirically the Mean Time To Invalidation under default PG18
configuration is roughly 2 × `autovacuum_naptime` ≈ 120 seconds after
slot creation. A single `VACUUM pg_statistic` on the primary
invalidates the slot in ~3 seconds deterministically.

This makes CDC pipelines / PITR+decode / forensic replay tools that
want to read logical changes out of archived WAL (without coupling
them to the production primary via a long-lived replication slot)
essentially unable to sustain a slot long enough to do useful work.

## What the patch does

Introduces a `PGC_SIGHUP` bool, `recovery_pause_on_logical_slot_conflict`
(default off, preserves existing behavior).

When enabled and replay is about to apply a `Heap2/PRUNE_ON_ACCESS`
record on a catalog relation whose `snapshotConflictHorizon` would
invalidate an active (consistent) logical slot in the same database,
replay pauses instead. The operator can drain the slot via
`pg_logical_slot_get_changes` and call `pg_wal_replay_resume()` to
continue. On resume, the patch advances the drained slot's
`catalog_xmin` past the conflict horizon, so the subsequent
`InvalidateObsoleteReplicationSlots` call is a no-op; replay proceeds
to the next conflict and the cycle repeats.

With the GUC off, there is exactly one added check — an early return
at the top of `MaybePauseOnLogicalSlotConflict` — and no functional
change to existing recovery behavior.

## Design notes

The hook is in `ResolveRecoveryConflictWithSnapshot()`
(`src/backend/storage/ipc/standby.c`), right before the existing
`InvalidateObsoleteReplicationSlots(RS_INVAL_HORIZON, ...)` call. The
wait loop reuses the existing `SetRecoveryPause` /
`recoveryNotPausedCV` / `ConfirmRecoveryPaused` machinery that already
underlies `recovery_target_action=pause` and
`pg_wal_replay_pause/resume()`. No new shared-memory state.

Six edge cases we hit, the first three during prototyping and the last three caught in an adversarial pre-submission review:

1. **In-progress slot**: a slot still inside
   `DecodingContextFindStartpoint()` (has `s->data.catalog_xmin` but
   `s->effective_catalog_xmin` is still `InvalidTransactionId`) is
   skipped. Pausing for such a slot would deadlock — snapbuild is
   waiting for replay to advance to a path-(a) `RUNNING_XACTS` anchor,
   replay is paused waiting for drain, slot is not yet drainable. An
   in-progress slot hasn't produced output to any consumer, so letting
   it be invalidated is harmless — the caller just retries creation.

2. **Off-by-one vs `DetermineSlotInvalidationCause`**: that function
   uses `TransactionIdPrecedesOrEquals` when comparing the slot's xmin
   to the conflict horizon. Our pause-check must also use
   `TransactionIdPrecedesOrEquals`, not `TransactionIdPrecedes`,
   otherwise a slot whose `catalog_xmin` was just advanced to horizon+1
   by a previous pause cycle fails to trigger a pause on a subsequent
   record with horizon == horizon+1, yet still gets invalidated by the
   fall-through.

3. **On-resume advance**: after the operator drains, we need to
   actually move `catalog_xmin` past the horizon so the fall-through
   invalidation is a no-op. We walk the slots, and for each in the
   target database whose `confirmed_flush_lsn >= current replay LSN`
   (operator drained up to the conflict LSN), advance both `xmin` and
   `catalog_xmin` (and their `effective_` counterparts) to
   `TransactionIdAdvance(snapshotConflictHorizon)`. Slots the operator
   did NOT drain are untouched — they get invalidated as before.

4. **Promotion escape from the wait loop**: the wait loop checks
   `PromoteIsTriggered()` each iteration and returns on true, so a
   `pg_promote()` issued by an operator who has given up on the slot
   unblocks immediately. (`recoveryPausesHere` uses
   `CheckForStandbyTrigger`, which is `static` in xlogrecovery.c — we
   use the exposed `PromoteIsTriggered` instead.)

5. **Synced slots** (PG18 `sync_replication_slots`) are skipped in
   both the pause-check and advance scans. The slot-sync worker on the
   standby mutates `data.catalog_xmin`/`data.xmin`/`confirmed_flush`
   via `update_local_synced_slot`; us writing to those fields from the
   startup process would race. `ALTER_REPLICATION_SLOT` and
   `DROP_REPLICATION_SLOT` on a synced slot error out, so the
   operator-facing "drain or drop" recipe does not apply either.
   `src/test/recovery/t/040_standby_failover_slots_sync.pl` continues
   to pass with the filter in place.

6. **Durability gap (known limitation, deferred)**: the advance marks
   slots dirty but does not force an immediate `SaveSlotToPath`. If
   the standby crashes between resume and the next restartpoint, the
   on-disk `catalog_xmin` is the pre-advance value; on recovery
   restart replay re-encounters the same conflict record, re-pauses,
   and the operator re-drains. Idempotent, no data loss, but an
   operator-visible hiccup. `SaveSlotToPath` is currently `static` in
   slot.c and not trivially callable from the startup process (no
   `MyReplicationSlot`). A proper fix is out of scope for this
   prototype.

## Tests

Included: `src/test/recovery/t/050_recovery_pause_on_slot_conflict.pl`
(7 assertions, ~40s runtime). Two-phase flow:
Phase 1 creates slots on two standbys (GUC on, GUC off) against a
clean archive; Phase 2 runs catalog-churning workload on the primary
(transient tables + explicit VACUUM on `pg_class`, `pg_attribute`,
`pg_type`, `pg_depend`, `pg_statistic`) and waits for those segments
to archive. The GUC-on standby's orchestrator drains and resumes on
each pause; that slot ends in `wal_status=reserved`. The GUC-off
standby's slot ends in `wal_status=lost` — same workload, same
archive, exactly the existing upstream behavior.

Regression sweep on the lab VM against the squashed 2-commit series,
with `--enable-injection-points`: **100 tests pass** across
`006_logical_decoding`, `010_logical_decoding_timelines`,
`019_replslot_limit`, `028_pitr_timelines`, `035_standby_logical_decoding`,
`038_save_logical_slots_shutdown`, `040_standby_failover_slots_sync`,
`044_invalidate_inactive_slots`, `046_checkpoint_logical_slot`,
`047_checkpoint_physical_slot`, and our new 050.
`contrib/test_decoding`: 14 SQL + 6 TAP tests pass.

## End-to-end demo

On a lab VM, I ran the dead-primary recipe: primary generates 300s of
sustained INSERT workload with default autovacuum, primary killed,
standby brought up with archive only, slot created, orchestrator
loop drains/resumes. With the GUC off (stock PG18), slot is
invalidated at ~t+138s, recovering ~21 000 events (47% of the
window). With the GUC on, all 22 pause events are handled, the slot
survives, and all **45 469 decode events = 3 × 15 153 primary INSERTs
(100% coverage)** are drained cleanly.

## Not addressed in this patch

- **No timeout on the pause.** A long-running operator could hold the
  standby indefinitely. A companion
  `recovery_pause_on_logical_slot_conflict_timeout` is a reasonable
  followup.

- **Not integrated with `sync_replication_slots`** (PG18). That feature
  syncs slot state from a primary to a standby; we don't test the
  interaction here. 040_standby_failover_slots_sync passes against
  the patch, so nothing is visibly broken, but the semantics of
  synced-slot + pause-on-conflict should be deliberately thought
  through before this lands.

- **Two-phase decoding** (`two_phase=true` slots): same comment. Not
  specifically tested.

- **Observability**: we emit one `ereport(LOG)` on pause with the
  conflict LSN, horizon, and database OID, and one on resume with the
  slot name and new `catalog_xmin`. No `pg_stat_*` integration.

## Background

This grew out of work in
https://github.com/NikolayS/postgres/issues/25 on "logical decoding of
archived WAL" — a workflow for reading DML out of a point-in-time
PostgreSQL archive without needing a live primary. Full spec and
iteration history at
https://github.com/NikolayS/postgres/blob/blueprint/logical-decoding-archived-wals/blueprints/LOGICAL_DECODING_ARCHIVED_WALS.md.

I would welcome feedback on:
- the GUC name and placement
- the hook-point choice (`ResolveRecoveryConflictWithSnapshot` vs.
  something narrower inside `InvalidatePossiblyObsoleteSlot`)
- whether the on-resume `catalog_xmin` advance is the right shape of
  "I, the operator, drained" signal or if we should require an
  explicit SQL call instead (e.g. `pg_replication_slot_acknowledge_conflict`)
- whether an in-progress-slot skip is the right policy or whether
  we should find a way to not deadlock while still pausing.

Thanks.

---

## Attachments (not included in the email body, sent as separate patches)

- `0001-Pause-recovery-on-logical-slot-conflict.patch` — 377 lines (diff) / 216 insertions + 2 deletions across 6 files.
- `0002-Add-TAP-test-for-recovery_pause_on_logical_slot_conf.patch` — 296 lines (diff) / 247 lines added.

Patches available on branch `rfc-v1-recovery-pause-on-slot-conflict` at the GitHub fork linked above, or can be sent inline / as .patch attachments on request.
