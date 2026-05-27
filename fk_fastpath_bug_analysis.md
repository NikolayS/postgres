# FK Fast-Path Bug Analysis — PostgreSQL 19devel

## Confirmed

Built and tested against upstream/master (commit 84b9d6b). The bug reproduces
exactly as described. INSERT of `(999, 'bad')` succeeds silently despite no
matching PK row. The orphan persists and the constraint is still reported as
`convalidated = true`.

## Actual output

```
WARNING:  resource was not closed: relation "pk"
WARNING:  resource was not closed: relation "pk_pkey"
WARNING:  resource was not closed: TupleDesc 0x7f4c27648380 (16392,-1)
WARNING:  resource was not closed: TupleDesc 0x7f4c276493a0 (16386,-1)
INSERT 0 3

  a  | tag
-----+------
 999 | bad
   0 | boom
   1 | ok

  a  | tag
-----+-----
 999 | bad
```

## Root cause

In `ri_triggers.c`, `ri_FastPathSubXactCallback()` (line ~4208) unconditionally
NULLs `ri_fastpath_cache` and `ri_fastpath_callback_registered` on **any**
`SUBXACT_EVENT_ABORT_SUB`:

```c
static void
ri_FastPathSubXactCallback(SubXactEvent event, SubTransactionId mySubid,
                           SubTransactionId parentSubid, void *arg)
{
    if (event == SUBXACT_EVENT_ABORT_SUB)
    {
        ri_fastpath_cache = NULL;
        ri_fastpath_callback_registered = false;
    }
}
```

The comment says "ResourceOwner already released relations" — but that's only
true for resources created **within** the aborting subxact. In the reproduction
case:

1. AFTER ROW triggers fire for row 1 `(999, 'bad')`:
   - RI trigger fires first (alphabetical), calls `ri_FastPathBatchAdd()`
   - This calls `ri_FastPathGetEntry()`, which opens `pk_rel` and `idx_rel`,
     creates slots, and stores them in the cache
   - Resources are owned by the **main transaction's ResourceOwner**
   - The `zz_fk_after_row_boom` trigger fires — no-op for this row

2. AFTER ROW triggers fire for row 2 `(0, 'boom')`:
   - RI trigger fires, adds to batch (cache already exists)
   - `zz_fk_after_row_boom` trigger fires, hits `BEGIN...EXCEPTION...END`
   - PL/pgSQL creates an internal subtransaction (savepoint)
   - `RAISE EXCEPTION` aborts the subxact
   - **`ri_FastPathSubXactCallback` fires → NULLs the entire cache**
   - The exception is caught, subxact abort is handled, execution continues

3. AFTER ROW triggers fire for row 3 `(1, 'ok')`:
   - RI trigger calls `ri_FastPathBatchAdd()` → `ri_FastPathGetEntry()`
   - Cache is NULL, so it tries to create a new one
   - But the old relations were **never closed** (owned by parent
     ResourceOwner, not the aborted subxact) → resource leak warnings

4. At batch end, `ri_FastPathEndBatch()` flushes only the **new** cache
   (containing only row 3). The buffered check for row 1 `(999, 'bad')` was
   lost when the cache was NULLed.

## The comment is wrong

The design comment (lines 230-231) says:

> on abort, ResourceOwner releases the cached relations and the
> XactCallback/SubXactCallback NULL the static cache pointer

This is correct for **full transaction abort** (`XactCallback`), but wrong for
**subtransaction abort** (`SubXactCallback`). The fast-path resources are created
in the main trigger-firing context, not inside the subxact. Only the subxact's
own ResourceOwner is cleaned up on `SUBXACT_EVENT_ABORT_SUB`.

## Consequences

1. **Silent FK violation**: Orphan rows persist with no error
2. **Resource leaks**: Relations and slots owned by parent transaction are
   abandoned (visible as warnings with debug builds)
3. **Constraint still reports valid**: `pg_constraint.convalidated = true` and
   `ALTER TABLE ... VALIDATE CONSTRAINT` is a no-op for already-valid constraints
4. **No audit trail**: Nothing in the logs indicates the constraint was bypassed

## Fix direction

The SubXactCallback needs to be smarter about what it clears. Options:

1. **Track subxact nesting level**: Record which SubTransactionId (or nesting
   depth) the cache was created under. Only NULL the cache if the aborting
   subxact is at or above that level.

2. **Dedicated ResourceOwner**: Create a private ResourceOwner for fast-path
   resources attached to the top transaction, so subxact cleanup can't touch
   them. Then the SubXactCallback can simply ignore subxact aborts entirely.

3. **Re-flush on subxact abort**: Instead of discarding the cache, force a
   flush of all buffered rows before clearing. This is tricky because the
   flush itself can error, and error-during-error-recovery is dangerous.

Option 1 seems most aligned with how other Postgres subsystems handle this
pattern (e.g., Portal/Snapshot subxact tracking).

## Email review

The email is technically accurate and the reproduction case is correct. A few
suggestions:

- Add the actual output (especially the resource-leak warnings) — those are
  strong corroborating evidence and help reviewers trust the report
- The "security issue" framing is debatable — FK constraints are a data
  integrity feature, not an access-control mechanism. The silent bypass is
  serious, but "data integrity bug" might land better with -hackers
- Consider noting the PostgreSQL version/commit hash for reproducibility
- The trigger naming trick (sorting after `RI_ConstraintTrigger*`) deserves
  a brief explanation of why it matters — not all readers will immediately
  see why the name is important
