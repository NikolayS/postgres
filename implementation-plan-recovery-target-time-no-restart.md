# Implementation Plan: Make `recovery_target_time` Reloadable Without Restart

## Problem Statement

Currently, all `recovery_target_*` GUC parameters use `PGC_POSTMASTER` context,
meaning any change requires a full server restart. This is painful for operators
managing standby/replica servers who want to adjust the recovery stop point
(e.g., during point-in-time recovery) without cycling the server.

This plan focuses on `recovery_target_time` specifically, as it is the most
commonly adjusted recovery target parameter.

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

1. **Startup**: `StartupXLOG()` -> `InitWalRecovery()` -> `validateRecoveryParameters()` parses `recovery_target_time_string` into `recoveryTargetTime` (line 1105-1111)
2. **WAL Replay Loop** (line ~1614-1802): For each WAL record:
   - `ProcessStartupProcInterrupts()` handles signals including SIGHUP for config reload
   - `recoveryStopsBefore()` checks if this record's timestamp exceeds `recoveryTargetTime` (line 2651-2662)
   - `recoveryStopsAfter()` does the same for post-apply checks
   - If target reached: `reachedRecoveryTarget = true`, breaks out of loop
3. **Post-target** (line 1808-1840): Based on `recoveryTargetAction`: shutdown, pause, or promote

### Why It Currently Requires Restart

1. **`PGC_POSTMASTER` context** - GUC framework rejects SIGHUP changes
2. **Assign hook throws ERROR** (`error_multiple_recovery_targets()` at line 4784) - violates GUC contract; only safe because PGC_POSTMASTER limits this to startup (acknowledged as "broken by design" in comment at line 4776)
3. **One-time parsing** - `recoveryTargetTime` is parsed once during `validateRecoveryParameters()` and never refreshed
4. **No mechanism to resume paused recovery** when target changes

## Implementation Plan

### Step 1: Change GUC Context to `PGC_SIGHUP`

**File**: `src/backend/utils/misc/guc_parameters.dat`

Change `recovery_target_time` from `PGC_POSTMASTER` to `PGC_SIGHUP`:

```perl
{ name => 'recovery_target_time', type => 'string', context => 'PGC_SIGHUP',
  ...
},
```

This single change allows the parameter to be changed via `pg_reload_conf()` or
`SIGHUP` without a restart.

**Note**: Only `recovery_target_time` is changed. All other `recovery_target_*`
parameters remain `PGC_POSTMASTER`. This means you cannot switch _target types_
(e.g., from time-based to XID-based) without a restart, but you can adjust the
time value.

### Step 2: Fix the Assign Hook (Move Validation to Check Hook)

**File**: `src/backend/access/transam/xlogrecovery.c`

**Problem**: `assign_recovery_target_time()` (line 4965) calls
`error_multiple_recovery_targets()` which throws `ERROR`. With `PGC_SIGHUP`,
this would corrupt GUC state.

**Solution**: Move the mutual-exclusion check into `check_recovery_target_time()`
(the check hook), which can safely return `false` to reject a value:

```c
bool
check_recovery_target_time(char **newval, void **extra, GucSource source)
{
    if (strcmp(*newval, "") != 0)
    {
        /* Reject if a different recovery target type is already set */
        if (recoveryTarget != RECOVERY_TARGET_UNSET &&
            recoveryTarget != RECOVERY_TARGET_TIME)
        {
            GUC_check_errdetail("Another recovery target type is already set.");
            return false;
        }

        /* ... existing timestamp parsing validation ... */
    }
    return true;
}
```

Simplify the assign hook to remove the error-throwing:

```c
void
assign_recovery_target_time(const char *newval, void *extra)
{
    if (newval && strcmp(newval, "") != 0)
        recoveryTarget = RECOVERY_TARGET_TIME;
    else
        recoveryTarget = RECOVERY_TARGET_UNSET;
}
```

### Step 3: Re-parse `recoveryTargetTime` on Assign

**File**: `src/backend/access/transam/xlogrecovery.c`

Currently `recoveryTargetTime` is only set in `validateRecoveryParameters()`.
After a SIGHUP, the string changes but the parsed `TimestampTz` does not.

**Solution**: Parse the timestamp in the assign hook (or better, in the check
hook's `extra` data, then apply in the assign hook — following the GUC
check/assign pattern used by `recovery_target_lsn`):

```c
bool
check_recovery_target_time(char **newval, void **extra, GucSource source)
{
    if (strcmp(*newval, "") != 0)
    {
        TimestampTz *parsed_ts;
        TimestampTz  ts;

        /* mutual exclusion check ... */

        /* Parse the timestamp */
        ts = DatumGetTimestampTz(DirectFunctionCall3(timestamptz_in,
                                    CStringGetDatum(*newval),
                                    ObjectIdGetDatum(InvalidOid),
                                    Int32GetDatum(-1)));

        parsed_ts = (TimestampTz *) guc_malloc(LOG, sizeof(TimestampTz));
        if (!parsed_ts)
            return false;
        *parsed_ts = ts;
        *extra = parsed_ts;
    }
    return true;
}

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

**Consideration**: The existing check hook uses a manual parse
(`ParseDateTime`/`DecodeDateTime`) rather than `DirectFunctionCall3` to avoid
error-throwing in the check phase. We should keep the manual parse for
validation but store the parsed result in `extra` for use by the assign hook.
Alternatively, we do full parse in the check hook using the safe error context
pattern (similar to `check_recovery_target_lsn` which uses `pg_lsn_in_safe`).

The `validateRecoveryParameters()` code at line 1105-1111 that does the "final
parsing" can be kept for the initial startup path but becomes redundant once
the assign hook handles it. We should remove it to avoid confusion, or guard it
with a comment.

### Step 4: Handle "Recovery Already Paused at Old Target"

**File**: `src/backend/access/transam/xlogrecovery.c`

This is the most architecturally significant change.

**Scenario**: Recovery reached the old `recovery_target_time` and paused
(because `recovery_target_action = 'pause'`). The operator changes
`recovery_target_time` to a later value and issues `pg_reload_conf()`.

**Current behavior at pause** (line 2898-2938): `recoveryPausesHere()` loops on
`ConditionVariableTimedSleep()` with 1-second timeout, calling
`ProcessStartupProcInterrupts()` each iteration (which processes SIGHUP and
reloads config).

**Solution**: After `ProcessStartupProcInterrupts()` in the pause loop, check
whether the recovery target has been updated to a point beyond the current
replay position. If so, automatically unpause:

```c
static void
recoveryPausesHere(bool endOfRecovery)
{
    /* ... existing checks ... */

    while (GetRecoveryPauseState() != RECOVERY_NOT_PAUSED)
    {
        ProcessStartupProcInterrupts();
        if (CheckForStandbyTrigger())
            return;

        /*
         * If recovery_target_time was changed via SIGHUP to a later value,
         * automatically resume recovery to reach the new target.
         */
        if (!endOfRecovery && recoveryTargetTimeChanged())
        {
            SetRecoveryPause(false);
            ereport(LOG,
                    (errmsg("recovery target time changed, resuming recovery")));
            return;
        }

        ConfirmRecoveryPaused();
        ConditionVariableTimedSleep(...);
    }
    ConditionVariableCancelSleep();
}
```

The `recoveryTargetTimeChanged()` helper would compare the current (post-reload)
`recoveryTargetTime` against `recoveryStopTime` (the timestamp at which we
stopped). If the new target is later than where we stopped, recovery should
resume.

**Key detail**: After resuming, the main WAL replay loop (`PerformWalRecovery`,
line 1614) has already exited with `reachedRecoveryTarget = true`. We need to
either:

**(Option A)**: Modify `recoveryPausesHere()` so that it resets
`reachedRecoveryTarget` and returns a value indicating "go back to the replay
loop". This requires restructuring the control flow in `PerformWalRecovery()`.

**(Option B - preferred)**: Don't exit the main replay loop when the target is
reached with `pause` action. Instead, pause inline within the loop (which is
already partially done at line 1748-1750) and only set `reachedRecoveryTarget`
when truly done. When recovery is paused at the target, the existing pause
check at line 1748 handles it. On SIGHUP with a new target, the pause is
cleared, and the loop naturally continues to the next record where
`recoveryStopsBefore/After` will re-evaluate against the new `recoveryTargetTime`.

**Option B implementation sketch**:

```c
/* In the reachedRecoveryTarget handling (line 1808-1840): */
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
             * If we get here, either the user called pg_wal_replay_resume()
             * or recovery_target_time was changed. Reset and continue the
             * replay loop.
             */
            reachedRecoveryTarget = false;
            goto redo_loop_start;  /* or restructure as outer while(true) */

        case RECOVERY_TARGET_ACTION_PROMOTE:
            break;
    }
}
```

### Step 5: Handle Backward Target Changes

**File**: `src/backend/access/transam/xlogrecovery.c`

If the user moves `recovery_target_time` backward (earlier than
already-replayed WAL), we cannot un-apply transactions.

**Solution**: In `check_recovery_target_time()`, when processing a SIGHUP
(source != PGC_S_DEFAULT and we're in recovery), compare the new target against
the last replayed record time. If earlier, issue a WARNING and reject:

```c
/* In check_recovery_target_time, when source indicates runtime change */
if (RecoveryInProgress() && new_target_ts < GetLatestXTime())
{
    GUC_check_errmsg("recovery_target_time cannot be set earlier than "
                     "already-replayed WAL time %s",
                     timestamptz_to_str(GetLatestXTime()));
    return false;
}
```

**Alternative**: Accept it but log a WARNING that it has no effect until the
server is restarted from a backup prior to that time. This is more permissive
and arguably more consistent with PostgreSQL's general GUC philosophy. The
replay loop would simply never trigger `stopsHere` since all future records
would have timestamps beyond the target (wait, that's wrong - a backward target
would actually cause the very next record to trigger `stopsHere`). So we need
to think carefully:

- If recovery is actively replaying and we set the target to the past,
  `recoveryStopsBefore` would fire on the next commit record, immediately pausing
  (or shutting down, or promoting). This might actually be the desired behavior
  in some cases ("stop now!").
- If recovery is already paused at target, a backward move is meaningless.

**Decision**: Allow backward moves during active replay (it means "stop ASAP").
Reject backward moves when already paused at target (it's impossible to go back).

### Step 6: Update `validateRecoveryParameters()`

**File**: `src/backend/access/transam/xlogrecovery.c`

Since the assign hook now handles parsing into `recoveryTargetTime`, the code
at line 1105-1111 in `validateRecoveryParameters()` is redundant. Remove it or
keep it as a fallback for the initial startup path with a comment:

```c
/*
 * recoveryTargetTime is now set by the assign hook for
 * recovery_target_time. This assertion verifies that.
 */
if (recoveryTarget == RECOVERY_TARGET_TIME)
    Assert(recoveryTargetTime != 0);
```

### Step 7: Logging

When a SIGHUP changes the recovery target time during active recovery, emit
a LOG message:

```
LOG:  recovery target time changed from '2024-01-15 10:00:00+00' to '2024-01-15 12:00:00+00'
```

This can be done in the assign hook by comparing old and new values.

### Step 8: Documentation

**File**: `doc/src/sgml/config.sgml`

Update the documentation for `recovery_target_time` to note that it can be
changed via reload. Add a paragraph explaining the behavior:

- Changing to a later time while paused at recovery target resumes replay.
- Changing to an earlier time during active replay stops replay at the next
  transaction commit.
- Changing target type (e.g., from time to XID) still requires a restart.

### Step 9: Tests

**File**: `src/test/recovery/` (new test file)

Create a TAP test that:

1. Sets up a standby with `recovery_target_time` and `recovery_target_action = 'pause'`
2. Verifies recovery pauses at the target
3. Changes `recovery_target_time` to a later value via `ALTER SYSTEM` + `pg_reload_conf()`
4. Verifies recovery resumes and pauses at the new target
5. Tests edge cases: same value (no-op), backward value while paused (rejected)

## Files Modified

| File | Change |
|------|--------|
| `src/backend/utils/misc/guc_parameters.dat` | `PGC_POSTMASTER` -> `PGC_SIGHUP` |
| `src/backend/access/transam/xlogrecovery.c` | Fix hooks, re-parse on assign, resume-on-change logic |
| `src/include/access/xlogrecovery.h` | Possibly add helper function declarations |
| `doc/src/sgml/config.sgml` | Documentation update |
| `src/test/recovery/t/0XX_recovery_target_reload.pl` | New TAP test |

## Estimated Size

~300-500 lines changed/added across all files.

## Risks and Considerations

1. **Race conditions**: Not a concern for `recoveryTargetTime` since the startup
   process is single-threaded. SIGHUP is processed synchronously via
   `ProcessStartupProcInterrupts()` in the replay loop.

2. **Timezone dependency**: The check hook comment (line 4904-4908) notes that
   timestamp interpretation depends on timezone settings. Since SIGHUP reloads
   all GUCs including `timezone`, and the assign hook fires after all GUCs are
   processed, this should work correctly.

3. **Interaction with `recovery_target_action`**: If the action is `shutdown`,
   changing the time has no effect (server already exited). If `promote`, the
   server has already promoted. Only `pause` benefits from this feature, which
   is the primary use case.

4. **Interaction with other `recovery_target_*` params**: Since those remain
   `PGC_POSTMASTER`, the mutual-exclusion check should still be enforced. The
   check hook must verify that no non-time recovery target is active.

5. **Backward compatibility**: This is a strictly additive change. Existing
   behavior (set at startup) continues to work identically. The only new
   capability is that SIGHUP can now update the value.
