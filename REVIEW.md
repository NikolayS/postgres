# Patch Review: log_object_drops GUC (Commitfest #6272)

**Patch:** PoC: Simplify recovery after dropping a table by LOGGING the restore LSN
**Commitfest:** https://commitfest.postgresql.org/patch/6272/
**Version Reviewed:** v5
**Author:** Dmitry Lebedev
**Original Concept:** Kirk Wolak
**Review Date:** 2026-01-15
**Reviewer Branch:** `claude/review-postgres-patch-MWGUs`

---

## Summary

This patch introduces a new GUC `log_object_drops` (default: off) that logs DROP TABLE and DROP DATABASE operations with their commit LSN. This simplifies Point-in-Time Recovery (PITR) when users accidentally drop tables, as they can use the logged LSN to restore to a point just before the drop.

**Key improvement over earlier PoC:** The v5 patch logs the actual commit LSN (via extended `XactCallback`) rather than the WAL insert pointer at lock time, which could be arbitrarily less than the commit LSN under high load.

---

## Bugs Found and Fixed

### 1. Format String Bug (Critical)

**File:** `src/backend/catalog/dependency.c:294-300`

**Problem:** The log message format string expected 4 format arguments (`%X/%X, %X/%X`) but only 2 were provided via `LSN_FORMAT_ARGS(commit_lsn)`. This caused the second LSN pair to read garbage from the stack.

**Original code:**
```c
ereport(LOG,
    (errmsg("DROP TABLE: relation \"%s.%s\" (OID %u), "
            "drop LSN: %X/%X, commit LSN: %X/%X",
            info->schemaname,
            info->relname,
            info->reloid,
            LSN_FORMAT_ARGS(commit_lsn))));  // Only 2 values!
```

**Fixed code:**
```c
ereport(LOG,
    (errmsg("DROP TABLE: relation \"%s.%s\" (OID %u), "
            "commit LSN: %X/%X",
            info->schemaname,
            info->relname,
            info->reloid,
            LSN_FORMAT_ARGS(commit_lsn))));
```

**Impact:** Without this fix, log messages would show garbage values for the second LSN, making the feature unreliable.

### 2. GUC Alphabetical Ordering

**File:** `src/backend/utils/misc/guc_parameters.dat`

**Problem:** The `log_object_drops` entry was placed at the end of the file, but PostgreSQL requires GUC entries to be in alphabetical order. The build failed with:
```
entries are not in alphabetical order: "zero_damaged_pages", "log_object_drops"
```

**Fix:** Moved `log_object_drops` between `log_min_messages` and `log_parameter_max_length`.

---

## Rebase Required

The patch needed rebasing due to new test files added since the patch was created:

- Original patch created `t/050_drop_table_logging.pl`
- Current HEAD already has `t/050_redo_segment_missing.pl` and `t/051_effective_wal_level.pl`
- **Fix:** Renamed to `t/052_drop_table_logging.pl` and updated `meson.build`

---

## Test Results

| Test Case | Result | Notes |
|-----------|--------|-------|
| GUC enabled (`log_object_drops = on`) | PASS | Logs DROP TABLE with commit LSN |
| GUC disabled (`log_object_drops = off`) | PASS | No logging occurs |
| ROLLBACK (aborted drop) | PASS | No log message for rolled-back drops |
| SAVEPOINT + ROLLBACK TO | PASS | Only committed drops are logged |
| COMMIT AND CHAIN | PASS | Each chained transaction logs separately |
| DROP DATABASE | PASS | LSN logged correctly |
| TEMPORARY tables | PASS | Drops are logged (see note below) |
| UNLOGGED tables | PASS | Drops are logged |

### Example Log Output

```
LOG:  DROP TABLE: relation "public.test1" (OID 16391), commit LSN: 0/176DC20
LOG:  DROP DATABASE: database "test_drop_db" (OID 16403), LSN: 0/1B94EB8
```

---

## Observations and Recommendations

### 1. TEMPORARY Tables Are Logged

When a temporary table is explicitly dropped or auto-dropped at session end, it gets logged. This could be noisy in environments with heavy temp table usage.

**Recommendation:** Consider adding an option to exclude temporary tables, or document this behavior clearly.

### 2. Inconsistent LSN Source for DROP DATABASE vs DROP TABLE

| Operation | LSN Source | Timing |
|-----------|------------|--------|
| DROP TABLE | Commit LSN via `XactCallback` | At transaction commit |
| DROP DATABASE | `GetXLogInsertRecPtr()` | During operation |

DROP DATABASE uses the older approach (`GetXLogInsertRecPtr()`) that was criticized for DROP TABLE. While DROP DATABASE runs as its own transaction (minimizing the difference), this inconsistency should be addressed for correctness.

**Recommendation:** Extend the `XactCallback` approach to DROP DATABASE for consistency.

### 3. Minor Code Issues

- **Unused variable:** `src/backend/catalog/dependency.c:249` has unused variable `new_list` in `DropTableSubXactCallback` (compiler warning)
- **Indentation:** Some lines use spaces instead of tabs (flagged during `git apply`)

---

## Files Modified

| File | Changes |
|------|---------|
| `src/include/utils/guc.h` | Declare `log_object_drops` extern |
| `src/backend/utils/misc/guc_parameters.dat` | Add GUC definition |
| `src/backend/utils/misc/guc_tables.c` | Include GUC in tables |
| `src/backend/access/transam/xact.c` | Extend `XactCallback` to pass commit LSN |
| `src/include/access/xact.h` | Update `XactCallback` signature |
| `src/backend/catalog/dependency.c` | Implement DROP TABLE logging |
| `src/backend/commands/dbcommands.c` | Implement DROP DATABASE logging |
| `contrib/postgres_fdw/connection.c` | Update callback signature |
| `contrib/sepgsql/label.c` | Update callback signature |
| `src/pl/plpgsql/src/pl_exec.c` | Update callback signature |
| `src/pl/plpgsql/src/plpgsql.h` | Update callback signature |
| `doc/src/sgml/config.sgml` | Document new GUC |
| `src/test/recovery/t/052_drop_table_logging.pl` | TAP tests |
| `src/test/recovery/meson.build` | Register new test |

---

## Commits in Review Branch

| Commit | Description |
|--------|-------------|
| `c505196` | Add log_object_drops GUC for DROP TABLE/DATABASE logging |
| `272ad42` | Fix log_object_drops patch issues found during review |

---

## Conclusion

The patch implements a useful feature for simplifying PITR recovery. After fixing the two bugs identified (format string and GUC ordering), the core functionality works correctly. The patch should be updated to:

1. Include the bug fixes from this review
2. Consider the consistency issue between DROP TABLE and DROP DATABASE LSN sources
3. Address the unused variable warning
4. Clarify behavior with temporary tables in documentation

**Recommendation:** Needs revision to incorporate bug fixes before commit.
