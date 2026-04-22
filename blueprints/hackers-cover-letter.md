# [PATCH] recovery_pause_on_logical_slot_conflict: enable continuous logical decoding from an archive-only standby

Draft cover letter for pgsql-hackers. Not yet sent.

---

Hackers,

This patch adds a new GUC, `recovery_pause_on_logical_slot_conflict`
(`PGC_SIGHUP`, default `off`), that makes WAL replay on a standby pause —
and later auto-resume — instead of invalidating an otherwise-healthy
logical replication slot when a catalog `PRUNE_ON_ACCESS` record's
`snapshotConflictHorizon` has overtaken the slot's `catalog_xmin`.

## Motivation

A logical replication slot created on a standby that receives WAL only
via `restore_command` — no streaming link to the primary — cannot feed
`hot_standby_feedback` upstream, so it has no natural way to keep the
primary's catalog horizon pinned. Without this GUC, such a slot is
invalidated the first time replay applies a catalog vacuum record whose
horizon exceeds the slot's `catalog_xmin`, typically within
~`2 * autovacuum_naptime` of slot creation.

That makes continuous logical decoding from an archive-only standby
(a useful building block for CDC off a compliance / read-replica / cold
tier) effectively impossible today. With this GUC on, the same workload
runs as a service:

1. Replay encounters a conflicting prune record.
2. The startup process requests a recovery pause and waits.
3. The downstream consumer drains the slot past the pause LSN.
4. A periodic re-scan notices the slot no longer blocks, clears the
   pause, and advances `catalog_xmin` past the horizon so the subsequent
   `InvalidateObsoleteReplicationSlots()` call is a no-op.
5. Replay continues to the next conflict; the cycle repeats.

No operator action is required between drain and resume. A
drain-aware consumer turns this into a true continuous pipeline;
`pg_wal_replay_resume()` remains available as the "give up on this slot"
escape hatch.

## What the patch does

- Adds the GUC (`bool`, `PGC_SIGHUP`, default `off`,
  group `REPLICATION_STANDBY`). One boolean early-return on the hot path
  when `off`; no new shared-memory state.
- Hooks a single choke point: `ResolveRecoveryConflictWithSnapshot()`
  calls `MaybePauseOnLogicalSlotConflict()` before
  `InvalidateObsoleteReplicationSlots()` for the
  `RS_INVAL_HORIZON` / `isCatalogRel` case.
- Reuses the existing `recoveryNotPausedCV` /
  `SetRecoveryPause` / `ConfirmRecoveryPaused` machinery.
  `RECOVERY_PAUSE_REQUESTED → RECOVERY_PAUSED` is driven from inside
  `MaybePauseOnLogicalSlotConflict` so
  `pg_get_wal_replay_pause_state()` reflects reality.
- Wait loop:
  - `ProcessStartupProcInterrupts()`
  - `CheckForStandbyTrigger()` — escape so `pg_promote()` doesn't stall
  - `AnySlotStillBlocksConflict()` — auto-resume predicate
  - `ConfirmRecoveryPaused()`
  - `ConditionVariableTimedSleep(&recoveryNotPausedCV, 1s, ...)`
- Auto-resume predicate treats a slot as no longer blocking when any
  of the following holds:
  - `data.invalidated != RS_INVAL_NONE` (dropped, WAL-removed, etc.)
  - `data.synced` (managed by the slot-sync worker — upstream's
    concern, not ours)
  - `catalog_xmin` has advanced past the horizon
    (`pg_replication_slot_advance()`)
  - `confirmed_flush_lsn` has reached the pause-point LSN (drained)
- On wait exit, advance `catalog_xmin` (and `xmin`) past the horizon on
  drained slots so the fall-through invalidation is a no-op. Slots that
  weren't drained are left alone and get invalidated normally — that is
  the "give up" path when an operator uses `pg_wal_replay_resume()`
  manually.

## Edge cases we thought about

- **In-progress slots.** Slots whose `effective_catalog_xmin` is still
  `InvalidTransactionId` (still inside `DecodingContextFindStartpoint`)
  are skipped in both the pause check and the advance. Pausing for one
  would deadlock: `DecodingContextFindStartpoint` needs replay to move
  forward to reach `SNAPBUILD_CONSISTENT`. Invalidating an in-progress
  slot is harmless — the caller retries.

- **Synced slots.** Slots with `data.synced = true` are skipped. Writing
  their fields from the startup process would race with the slot-sync
  worker, and `ALTER` / `DROP_REPLICATION_SLOT` error out on a synced
  slot so the operator-facing recipe doesn't apply.

- **`PrecedesOrEquals` vs `Precedes`.** We use
  `TransactionIdPrecedesOrEquals` to match
  `DetermineSlotInvalidationCause`. With strict `Precedes`, a slot whose
  `catalog_xmin` was just advanced to exactly `horizon` by a previous
  pause-and-advance cycle would fail to re-pause on the next prune
  record with `horizon == catalog_xmin`, yet would still be invalidated
  by the fall-through.

- **`pg_promote()` during pause.** `CheckForStandbyTrigger()` — which
  actually consumes `PROMOTE_SIGNAL_FILE`, not just reads the flag — is
  called in the wait loop. Without that, `pg_promote(wait => true)`
  stalls for the full `wait_seconds` and returns false.

- **`max_slot_wal_keep_size` while paused.** The checkpointer is a
  separate process and runs restartpoints even while the startup process
  is asleep in the wait loop, so `RS_INVAL_WAL_REMOVED` can be applied
  out of band. The auto-resume predicate picks that up on the next tick
  and lets replay continue. The same mechanism handles an operator
  dropping or advancing the slot.

## Known limitations

- **Persistence of the post-wait advance.** We mark slots dirty but do
  not force `SaveSlotToPath`. If the standby crashes between resume and
  the next restartpoint, the on-disk `catalog_xmin` is the pre-advance
  value and replay re-encounters the same conflict on restart, re-pauses,
  and the consumer re-drains. The drain is idempotent so there is no
  data loss, but it is an operator-visible hiccup. `SaveSlotToPath` is
  currently static in `slot.c` and not trivially callable from the
  startup process (no `MyReplicationSlot`); we'd appreciate feedback on
  whether to expose it or accept the current behavior.

- **No backstop timeout.** If no consumer ever drains, the standby sits
  paused indefinitely. We considered a timeout GUC but chose not to wire
  one in — it is orthogonal and can be added later. Promote is already
  an escape.

- **Scope: `RS_INVAL_HORIZON` only.** Non-horizon invalidation causes
  (WAL-removed, idle-timeout) reflect explicit operator policy and
  should continue to invalidate; the patch does not touch them.

- **Opt-in, default off.** Upstream behavior is unchanged for every
  existing deployment; only operators who want continuous decoding from
  a WAL-shipping standby flip the GUC on.

## Tests

New TAP test `src/test/recovery/t/050_recovery_pause_on_slot_conflict.pl`
(~30 s wall-clock, 10 assertions). Three archive-only standbys from the
same basebackup:

1. **GUC on**: pauses on conflict; orchestrator drains; slot stays
   `reserved`; ≥2000 decoded events across ≥1 pause cycle.
2. **GUC off (baseline)**: under identical WAL, slot goes to `lost` —
   proves the conflict actually fires *and* that upstream behavior is
   unchanged.
3. **GUC on + `pg_promote(wait=>true, wait_seconds=>30)`**: asserts
   promote returns `t` in under 10 s. Guards the
   `CheckForStandbyTrigger()` escape in the wait loop.

The Phase-1 / Phase-2 split in the test is deliberate: slot creation
must reach `SNAPBUILD_CONSISTENT` before any conflicting prune record is
replayed, or `DecodingContextFindStartpoint` and our pause code
deadlock. The test takes basebackup, runs `pg_log_standby_snapshot()` +
`pg_switch_wal()` twice, waits for the anchor segment to archive,
creates slots, *then* runs the catalog-churning workload. The rationale
is commented inline.

## Files

    src/backend/access/transam/xlogrecovery.c      ~25 +/-
    src/backend/storage/ipc/standby.c              ~320 +/-
    src/backend/utils/misc/guc_parameters.dat        9 ++
    src/backend/utils/misc/postgresql.conf.sample    4 ++
    src/include/access/xlogrecovery.h                3 ++
    src/include/storage/standby.h                    2 ++
    src/test/recovery/t/050_recovery_pause_on_slot_conflict.pl 296 +++

Two functions are promoted from static to extern so the new code in
`standby.c` can drive them: `ConfirmRecoveryPaused()` and
`CheckForStandbyTrigger()`. Both are called only from the wait loop and
are direct parallels to how `recoveryPausesHere()` uses them today.

## Open questions

1. **GUC name.** `recovery_pause_on_logical_slot_conflict` is long but
   descriptive. An alternative: `logical_slot_conflict_action` with
   enum values (`invalidate` | `pause`). Happy to rename.

2. **Single GUC, auto-resume always.** We could have added a second knob
   for "pause only, never auto-resume", but we couldn't find a use case
   where a standby that pauses on conflict actually wants to keep
   sitting paused after the consumer has drained. Manual
   `pg_wal_replay_resume()` still works as the "give up on this slot"
   escape. If people want the explicit two-step behavior back, we can
   add a mode flag.

3. **Persistence.** Force `SaveSlotToPath` on advance, or accept the
   crash-redo behavior?

4. **Broader invalidation causes.** The patch scopes to
   `RS_INVAL_HORIZON`. Other causes (WAL-removed, idle-timeout) reflect
   operator policy and are probably right to keep invalidating — but
   someone might have a use case we haven't seen.

Feedback and review appreciated.

Thanks,

—

## Appendix: commit layout

The series on the working branch is:

- `1ef78be` Pause recovery on logical slot conflict
  (core feature + GUC + wait loop + manual-resume behavior)
- `ffd897c` Add TAP test for recovery_pause_on_logical_slot_conflict
- `cd2b7be` Refactor `050_recovery_pause_on_slot_conflict.pl` for
  readability (extracts helpers; no behavior change)
- `39adedd` Auto-resume recovery once the logical slot conflict is
  resolved (extracts `AnySlotStillBlocksConflict` helper, re-scans in
  the wait loop, flips pause state when nothing blocks; keeps manual
  `pg_wal_replay_resume()` as the escape)

For a single-patch submission we'd likely squash to two commits
(feature+test, documentation) or three (feature, test, docs); the
refactor commit exists to keep diff review tractable and would fold in.
