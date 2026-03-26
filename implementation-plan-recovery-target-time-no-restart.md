# Implementation Plan: Make `recovery_target_time` Reloadable Without Restart

**Version**: 2
**Last updated**: 2026-03-26

## Implementation Progress

### Patch 1: GUC Safety Cleanup
- [x] 1.1 Change GUC context to PGC_SIGHUP in guc_parameters.dat
- [x] 1.2 Add target_type_conflict_exists() helper function
- [x] 1.3 Add parse_recovery_target_time_safe() shared helper
- [x] 1.4 Rewrite check_recovery_target_time() with safe parsing and conflict check
- [x] 1.5 Simplify assign_recovery_target_time() (remove error_throwing)
- [x] 1.6 Update validateRecoveryParameters() to use shared parser

### Patch 2: Paused-Target-Forward-Resume Semantics
- [x] 2.1 Add RecoveryPauseReason enum to xlogrecovery.h
- [x] 2.2 Add pause reason state management functions
- [x] 2.3 Modify recoveryPausesHere() for target-change detection
- [x] 2.4 Add redo label and goto for replay loop re-entry
- [x] 2.5 Add logging for target-change resume events

### Documentation
- [x] Update config.sgml (SIGHUP context, reload behavior, timezone note)

### Testing
- [x] Write TAP test (9 assertions covering 5 core scenarios)
- [x] Build and compile successfully (Docker debian:bookworm)
- [x] Run TAP tests in Docker container — ALL PASS
- [x] Verified: pause at target, advance target, resume, re-pause
- [x] Verified: same/earlier target reload is no-op
- [x] Verified: pg_wal_replay_resume() promotes (not re-enter replay)
- [x] Verified: mutual exclusion of recovery target types

### Integration
- [x] Post testing evidence to PR #22
- [x] Update spec doc with final status

## Changelog

### v2 (2026-03-26) — Post-review revision

Incorporates feedback from three expert reviews. Key changes from v1:

1. **Reframed scope** (Review 2): This is not a generic "GUC reloadability" patch.
   It is specifically: "Allow moving a paused PITR time-based stop point forward
   via config reload during recovery." The feature is scoped to
   `recovery_target_action = 'pause'` + `recovery_target_time` only.

2. **Split into two patches** (Review 2): Patch 1 is pure GUC safety cleanup
   (useful on its own). Patch 2 adds paused-target-forward-resume semantics.

3. **Fixed unsafe timestamp parsing** (Reviews 1, 3): Removed `DirectFunctionCall3(timestamptz_in)`
   from check hook — it throws ERROR on bad input, which corrupts GUC state.
   Now uses safe manual `ParseDateTime`/`DecodeDateTime`/`tm2timestamp` path
   throughout, storing parsed `TimestampTz` in `*extra`.

4. **Fixed fragile mutual-exclusion check** (Review 3): Check hook now inspects
   raw GUC string variables (`recovery_target_string`, `recovery_target_lsn_string`,
   etc.) instead of the derived `recoveryTarget` enum, avoiding order-dependent
   intermediate state during SIGHUP processing.

5. **Replaced `goto` with outer loop** (Review 3): Instead of `goto redo_loop_start`,
   use `while (!reachedFinalTarget)` wrapping the replay loop. More code but
   more reviewable.

6. **Added explicit "paused-at-target" state** (Review 2): New recovery sub-state
   instead of implicitly toggling `reachedRecoveryTarget`. Makes the state
   transition from "target reached" to "target superseded, resume replay" explicit.

7. **Simplified backward-target semantics** (Reviews 1, 2): Removed check-hook
   state inspection (`GetLatestXTime()` is unsafe in check hooks). New rule:
   accept any valid timestamp; during active replay a past target means "stop at
   next commit"; while paused at target an equal-or-earlier value is a no-op.

8. **Kept startup validation authoritative** (Review 3): `validateRecoveryParameters()`
   remains the canonical startup path. Replaced the `Assert` idea with a shared
   parsing helper used by both startup and the check hook.

9. **Added missing analysis**: `recovery_min_apply_delay` interaction,
   `pg_control` / crash-recovery safety, timezone-on-reload semantics,
   mid-transaction stop safety (Review 3).

10. **Expanded test plan** (Reviews 2, 3): Added cases for no-change reload,
    `pg_wal_replay_resume()` interaction, timezone reload, backward move during
    active replay, and post-promotion no-op.

### v1 (2026-03-26) — Initial draft

Initial analysis and implementation plan.

---

## Problem Statement

Operators managing standby servers doing point-in-time recovery (PITR) must
restart PostgreSQL to change `recovery_target_time`. The concrete operator
story this patch enables:

1. Standby is in archive/PITR recovery
2. `recovery_target_action = 'pause'`, `recovery_target_time` is set
3. Recovery pauses at the target
4. Admin updates `recovery_target_time` to a later value
5. `pg_reload_conf()` — startup process resumes WAL replay toward the new target

This is scoped to time-based targets with pause action. Other target types
remain `PGC_POSTMASTER`. Changing target *type* (e.g., time to XID) still
requires a restart.

## Current Architecture

### GUC Definition (`src/backend/utils/misc/guc_parameters.dat:2407`)

```perl
{ name => 'recovery_target_time', type => 'string', context => 'PGC_POSTMASTER',
  variable => 'recovery_target_time_string',
  check_hook => 'check_recovery_target_time',
  assign_hook => 'assign_recovery_target_time',
},
```

### Key Variables (`src/backend/access/transam/xlogrecovery.c`)

| Variable | Type | Purpose |
|----------|------|---------|
| `recovery_target_time_string` | `char *` | Raw GUC string value |
| `recoveryTargetTime` | `TimestampTz` | Parsed timestamp used in comparisons |
| `recoveryTarget` | `RecoveryTargetType` | Enum indicating which target type is active |
| `recoveryTargetInclusive` | `bool` | Whether the target is inclusive |
| `recoveryTargetAction` | `RecoveryTargetActionType` | What to do when target is reached |

### Recovery Flow

1. **Startup**: `StartupXLOG()` → `InitWalRecovery()` → `validateRecoveryParameters()` parses `recovery_target_time_string` into `recoveryTargetTime` (line 1105-1111)
2. **WAL Replay Loop** (line ~1614-1802): For each WAL record:
   - `ProcessStartupProcInterrupts()` handles signals including SIGHUP for config reload
   - `recoveryStopsBefore()` checks if this record's timestamp exceeds `recoveryTargetTime` (line 2651-2662)
   - `recoveryStopsAfter()` does the same for post-apply checks
   - If target reached: `reachedRecoveryTarget = true`, breaks out of loop
3. **Post-target** (line 1808-1840): Based on `recoveryTargetAction`: shutdown, pause, or promote

### Why It Currently Requires Restart

1. **`PGC_POSTMASTER` context** — GUC framework rejects SIGHUP changes
2. **Assign hook throws ERROR** (`error_multiple_recovery_targets()` at line 4784) — violates GUC contract; only safe because PGC_POSTMASTER limits this to startup (acknowledged as "broken by design" in comment at line 4776)
3. **One-time parsing** — `recoveryTargetTime` is parsed once during `validateRecoveryParameters()` and never refreshed
4. **No mechanism to resume paused recovery** when target changes

---

## Patch Series

### Patch 1: Make GUC Internally Safe for Reload

Pure GUC cleanup. Useful on its own even if Patch 2 is deferred. Does not
promise resume-after-pause yet.

#### 1.1 Change GUC Context to `PGC_SIGHUP`

**File**: `src/backend/utils/misc/guc_parameters.dat`

```perl
{ name => 'recovery_target_time', type => 'string', context => 'PGC_SIGHUP',
  ...
},
```

Only `recovery_target_time` changes. All other `recovery_target_*` parameters
remain `PGC_POSTMASTER`.

#### 1.2 Fix Mutual-Exclusion Check (Move to Check Hook)

**File**: `src/backend/access/transam/xlogrecovery.c`

**Problem**: `assign_recovery_target_time()` calls `error_multiple_recovery_targets()`
which throws `ERROR`. With `PGC_SIGHUP`, this corrupts GUC state.

**Solution**: Move the check into `check_recovery_target_time()`, which can
safely return `false`. Critically, check the **raw GUC string variables**
(`recovery_target_string`, `recovery_target_lsn_string`,
`recovery_target_name_string`, `recovery_target_xid_string`) rather than the
derived `recoveryTarget` enum, to avoid order-dependent intermediate state
during SIGHUP processing:

```c
bool
check_recovery_target_time(char **newval, void **extra, GucSource source)
{
    if (strcmp(*newval, "") != 0)
    {
        /*
         * Reject if a different recovery target type is already configured.
         * Check raw GUC strings, not the derived recoveryTarget enum, to
         * avoid sensitivity to GUC processing order during SIGHUP.
         */
        if (target_type_conflict_exists(RECOVERY_TARGET_TIME))
        {
            GUC_check_errdetail("Another recovery target type is already set.");
            return false;
        }

        /* ... safe timestamp parsing (see 1.3) ... */
    }
    return true;
}
```

Introduce `target_type_conflict_exists()` helper that checks raw GUC strings.
Use this helper from both startup validation and all check hooks.

Simplify the assign hook to be purely mechanical:

```c
void
assign_recovery_target_time(const char *newval, void *extra)
{
    if (newval && strcmp(newval, "") != 0)
    {
        recoveryTarget = RECOVERY_TARGET_TIME;
        recoveryTargetTime = *((TimestampTz *) extra);
    }
    else
        recoveryTarget = RECOVERY_TARGET_UNSET;
}
```

#### 1.3 Safe Timestamp Parsing via `*extra`

**File**: `src/backend/access/transam/xlogrecovery.c`

**Critical safety rule**: Never call `DirectFunctionCall3(timestamptz_in, ...)`
inside a check hook. It throws `ereport(ERROR)` on bad input, which corrupts
GUC state during SIGHUP. Instead, use the manual safe-parsing path already
present in the existing check hook:

```c
bool
check_recovery_target_time(char **newval, void **extra, GucSource source)
{
    if (strcmp(*newval, "") != 0)
    {
        /* mutual exclusion check (see 1.2) ... */

        /* Safe timestamp parsing — no ereport(ERROR) on bad input */
        {
            char       *str = *newval;
            fsec_t      fsec;
            struct pg_tm tt, *tm = &tt;
            int         tz;
            int         dtype, nf, dterr;
            char       *field[MAXDATEFIELDS];
            int         ftype[MAXDATEFIELDS];
            char        workbuf[MAXDATELEN + MAXDATEFIELDS];
            DateTimeErrorExtra dtextra;
            TimestampTz timestamp;
            TimestampTz *parsed_ts;

            dterr = ParseDateTime(str, workbuf, sizeof(workbuf),
                                  field, ftype, MAXDATEFIELDS, &nf);
            if (dterr == 0)
                dterr = DecodeDateTime(field, ftype, nf,
                                       &dtype, tm, &fsec, &tz, &dtextra);
            if (dterr != 0)
                return false;
            if (dtype != DTK_DATE)
                return false;
            if (tm2timestamp(tm, fsec, &tz, &timestamp) != 0)
            {
                GUC_check_errdetail("Timestamp out of range: \"%s\".", str);
                return false;
            }

            /* Stash parsed value for the assign hook */
            parsed_ts = (TimestampTz *) guc_malloc(LOG, sizeof(TimestampTz));
            if (!parsed_ts)
                return false;
            *parsed_ts = timestamp;
            *extra = parsed_ts;
        }
    }
    return true;
}
```

Note: `guc_malloc`-allocated `*extra` is managed by the GUC framework — it
handles freeing previous values on reassignment. No manual free needed.

#### 1.4 Shared Parsing Helper for Startup and Check Hook

**File**: `src/backend/access/transam/xlogrecovery.c`

Extract a shared helper `parse_recovery_target_time_safe()` used by both
`check_recovery_target_time()` and `validateRecoveryParameters()`. The startup
path in `validateRecoveryParameters()` remains authoritative — it is not
replaced by an Assert or removed. Both paths call the same function:

```c
static bool
parse_recovery_target_time_safe(const char *str, TimestampTz *result)
{
    /* Manual ParseDateTime/DecodeDateTime/tm2timestamp — no ereport */
    ...
    *result = timestamp;
    return true;
}
```

#### 1.5 Timezone-on-Reload Semantics

**Decision**: `recovery_target_time` is re-parsed under the current timezone on
every reload. This means if the timezone GUC changes and `recovery_target_time`
contains a zone-ambiguous string, the effective `TimestampTz` may change even if
the text is unchanged.

This is the correct behavior: it matches how the parameter works at startup
(parsed after timezone is finalized). Document this explicitly and require
fully-qualified timestamps (with explicit timezone offset) in documentation
examples to avoid surprises.

---

### Patch 2: Paused-Target-Forward-Resume Semantics

Only applies when:
- `recovery_target_action = 'pause'`
- `recovery_target` type is `RECOVERY_TARGET_TIME`
- Recovery is still in progress (not promoted, not shut down)

#### 2.1 Explicit Recovery Sub-State

**File**: `src/backend/access/transam/xlogrecovery.c`

Introduce a distinct "paused-at-target" state rather than implicitly toggling
`reachedRecoveryTarget`:

```c
typedef enum
{
    RECOVERY_PAUSE_NONE,
    RECOVERY_PAUSE_REQUESTED,       /* pg_wal_replay_pause() */
    RECOVERY_PAUSE_AT_TARGET,       /* recovery_target reached with action=pause */
    RECOVERY_PAUSE_TARGET_SUPERSEDED /* target changed, should resume */
} RecoveryPauseReason;
```

When recovery pauses because a time target was reached with `action = pause`,
the startup process enters `RECOVERY_PAUSE_AT_TARGET`. On config reload, if a
new valid `recovery_target_time` is strictly later than `recoveryStopTime`, the
state transitions to `RECOVERY_PAUSE_TARGET_SUPERSEDED` and WAL replay resumes.

This avoids ambiguity between "DBA called `pg_wal_replay_resume()`" (which
means proceed to promote) and "DBA changed the target time" (which means
continue replay toward new target).

#### 2.2 Restructure Replay Loop (No `goto`)

**File**: `src/backend/access/transam/xlogrecovery.c`

Instead of `goto redo_loop_start`, wrap the existing replay loop in an outer
`while (!reachedFinalTarget)` loop:

```c
bool reachedFinalTarget = false;

while (!reachedFinalTarget)
{
    bool reachedRecoveryTarget = false;

    /* ... existing WAL replay do/while loop ... */

    if (reachedRecoveryTarget)
    {
        switch (recoveryTargetAction)
        {
            case RECOVERY_TARGET_ACTION_SHUTDOWN:
                proc_exit(3);

            case RECOVERY_TARGET_ACTION_PAUSE:
                SetRecoveryPause(true);
                recoveryPausesHere(true);

                /*
                 * Distinguish: did we unpause because target changed,
                 * or because pg_wal_replay_resume() was called?
                 */
                if (GetRecoveryPauseReason() == RECOVERY_PAUSE_TARGET_SUPERSEDED)
                {
                    /* Target moved forward — continue replay */
                    ereport(LOG,
                        (errmsg("recovery target time changed to %s, resuming WAL replay",
                                timestamptz_to_str(recoveryTargetTime))));
                    continue;  /* outer while loop */
                }
                /* else: pg_wal_replay_resume() — fall through to promote */
                pg_fallthrough;

            case RECOVERY_TARGET_ACTION_PROMOTE:
                break;
        }
        reachedFinalTarget = true;
    }
}
```

#### 2.3 Target-Change Detection in Pause Loop

**File**: `src/backend/access/transam/xlogrecovery.c`

Inside `recoveryPausesHere()`, after `ProcessStartupProcInterrupts()`, detect
whether `recoveryTargetTime` has moved beyond `recoveryStopTime`:

```c
static void
recoveryPausesHere(bool endOfRecovery)
{
    /* ... existing checks ... */

    TimestampTz pausedAtTime = recoveryStopTime;

    while (GetRecoveryPauseState() != RECOVERY_NOT_PAUSED)
    {
        ProcessStartupProcInterrupts();
        if (CheckForStandbyTrigger())
            return;

        /*
         * If recovery_target_time was changed via SIGHUP to a value
         * strictly later than where we paused, resume replay.
         */
        if (endOfRecovery &&
            recoveryTarget == RECOVERY_TARGET_TIME &&
            recoveryTargetTime > pausedAtTime)
        {
            SetRecoveryPause(false);
            SetRecoveryPauseReason(RECOVERY_PAUSE_TARGET_SUPERSEDED);
            ereport(LOG,
                    (errmsg("recovery target time advanced, resuming WAL replay")));
            break;
        }

        ConfirmRecoveryPaused();
        ConditionVariableTimedSleep(&XLogRecoveryCtl->recoveryNotPausedCV,
                                    1000, WAIT_EVENT_RECOVERY_PAUSE);
    }
    ConditionVariableCancelSleep();
}
```

#### 2.4 Backward and Equal Target Semantics

No check-hook state inspection (check hooks must not read shared memory or
runtime state like `GetLatestXTime()`). Rules:

| State | New target vs current | Behavior |
|-------|----------------------|----------|
| Active replay, before target reached | Any valid timestamp | Accepted. `recoveryStopsBefore()` evaluates normally. Past value = stop at next commit record. |
| Paused at target | Strictly later | Resume replay toward new target |
| Paused at target | Equal or earlier | No-op (remains paused). No error, no warning. |
| After promotion / shutdown | Any | No runtime effect (config is accepted but inert) |

**Mid-transaction safety**: `recoveryStopsBefore()`/`recoveryStopsAfter()` only
evaluate at commit/abort records (this invariant is already enforced and does
not need changes). A backward target during active replay will not stop
mid-transaction — it stops at the next transaction boundary.

#### 2.5 Logging Strategy

Keep assign hook purely mechanical. Meaningful LOG messages go in recovery
control logic where the runtime consequence is known:

| Event | Where | Message |
|-------|-------|---------|
| Target time advanced, resuming | `recoveryPausesHere()` | `"recovery target time advanced, resuming WAL replay"` |
| Replay stopped at new target | `recoveryStopsBefore()` (existing) | Already logged |
| Reload accepted, no runtime effect | — | No log (avoid noise) |

---

## Additional Analysis (Added in v2)

### `recovery_min_apply_delay` Interaction

The delay is applied in `recoveryApplyDelay()` which runs *before*
`recoveryStopsBefore()` in the replay loop (line 1765). This means:

- If a delayed replica has its target time changed, the delay still applies to
  each record before the stop-check. No conflict.
- A forward target change while paused resumes replay, and subsequent records
  will still be delayed normally.

No code changes needed, but add a test case.

### `pg_control` and Crash-Recovery Safety

When recovery pauses at a target, `pg_control` records the recovery state
(including the last replayed LSN). If the server crashes while paused:

- On restart, recovery re-reads `postgresql.conf` (including the potentially
  updated `recovery_target_time`) and replays from the last checkpoint.
- Since `recovery_target_time` is now `PGC_SIGHUP`, the startup path reads the
  current config file value. If the admin changed it before the crash, the new
  value is used on restart — which is the correct behavior.
- If the admin changed it *after* the crash (before restart), same result.

No special handling needed. The existing crash-recovery path is correct.

### `pg_wal_replay_resume()` Interaction

If an admin calls `pg_wal_replay_resume()` while paused at a target, the
current behavior is to proceed to promotion. This must be preserved. The new
`RecoveryPauseReason` state distinguishes between "resume because target changed"
and "resume because admin called `pg_wal_replay_resume()`", ensuring the two
paths remain separate.

If an admin changes the target *and* calls `pg_wal_replay_resume()` in the same
reload cycle: the resume wins (pause state is cleared), and the target change
takes effect for subsequent stop checks if replay continues.

---

## Files Modified

| File | Change |
|------|--------|
| `src/backend/utils/misc/guc_parameters.dat` | `PGC_POSTMASTER` → `PGC_SIGHUP` |
| `src/backend/access/transam/xlogrecovery.c` | Fix hooks, safe parsing, shared helper, resume-on-change logic, pause reason state |
| `src/include/access/xlogrecovery.h` | `RecoveryPauseReason` enum, helper declarations |
| `doc/src/sgml/config.sgml` | Documentation update (reloadable, timezone note, behavior) |
| `src/test/recovery/t/0XX_recovery_target_reload.pl` | New TAP test |

## Estimated Size

~500-700 lines changed/added across all files (revised upward from v1 estimate
of 300-500).

## Test Plan

### Core scenarios
1. Pause at target, reload with later time, verify resume and re-pause
2. Pause at target, reload with same time, verify no-op
3. Pause at target, reload with earlier time, verify no-op (stays paused)
4. Active replay before target, reload with earlier time, verify stops at next commit
5. Active replay before target, reload with later time, verify continues to new target

### Interaction tests
6. `pg_wal_replay_resume()` while paused at target — verify promotes (not re-enter replay)
7. Target change + `pg_wal_replay_resume()` in same cycle — verify correct precedence
8. `recovery_min_apply_delay` interaction — verify delay still applies after target change
9. Timezone reload — verify reparsing under new timezone
10. Non-time target already set (`recovery_target_xid`) — verify `recovery_target_time` rejected

### Edge cases
11. Reload with no change — verify no spurious log messages
12. Empty string (unset) while paused at target — verify behavior
13. After promotion — verify reload accepted but inert
14. Crash while paused, restart with new target — verify correct recovery

## Risks and Considerations

1. **Race conditions**: Not a concern. The startup process is single-threaded;
   SIGHUP is processed synchronously via `ProcessStartupProcInterrupts()`.

2. **Timezone on reload**: Re-parsed under current timezone. Documented. Users
   should use explicit timezone offsets in timestamps for deterministic behavior.

3. **Only `pause` benefits at runtime**: `shutdown` exits, `promote` ends
   recovery. Runtime resume semantics are explicitly limited to `pause` action.

4. **Backward compatibility**: Strictly additive. Existing behavior unchanged.

5. **Review strategy**: Two-patch series. Patch 1 is independently useful GUC
   hygiene. Patch 2 is the behavioral change that will attract review scrutiny.
