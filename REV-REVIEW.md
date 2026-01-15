# REV Framework Patch Review: log_object_drops GUC

**Patch:** PoC: Simplify recovery after dropping a table by LOGGING the restore LSN
**Commitfest:** https://commitfest.postgresql.org/patch/6272/
**Version:** v5 (with fixes applied)
**Author:** Dmitry Lebedev
**Original Concept:** Kirk Wolak
**Review Date:** 2026-01-15
**Review Framework:** REV (pg-review + pg-readiness)

---

## Executive Summary

| Aspect | Status |
|--------|--------|
| **Build & Apply** | PASS (after fixes) |
| **Testing** | PASS |
| **Code Quality** | NEEDS MINOR FIXES |
| **Security** | PASS |
| **Documentation** | PASS |
| **Overall** | NEEDS REVISION |

**Recommendation:** The patch implements useful functionality but requires revision to address the issues identified below before it can be committed.

---

## Readiness Scorecard

```
═══════════════════════════════════════════════════════════════════════════════
PATCH READINESS EVALUATION
═══════════════════════════════════════════════════════════════════════════════

Patch: log_object_drops GUC (v5 + fixes)
Date: 2026-01-15
Evaluator: REV Framework (pg-review + pg-readiness)

───────────────────────────────────────────────────────────────────────────────
CATEGORY                                    STATUS          SCORE
───────────────────────────────────────────────────────────────────────────────
1. Build & Apply
   [x] Applies to master                    PASS (rebased)    15/15
   [x] Compiles clean                       PASS               8/10
   [x] pgindent clean                       FAIL               0/5
                                                        Subtotal: 23/30

2. Testing
   [x] Existing tests pass                  PASS              20/20
   [x] New tests present                    PASS              15/15
   [~] Error paths tested                   PARTIAL            3/5
                                                        Subtotal: 38/40

3. Code Quality
   [x] No debug code                        PASS               5/5
   [x] No unrelated changes                 PASS               5/5
   [~] Style compliance                     PARTIAL            3/5
                                                        Subtotal: 13/15

4. Documentation
   [x] User docs updated                    PASS               5/5
   [ ] Release notes entry                  MISSING            0/5
   [~] Examples provided                    PARTIAL            1/2
                                                        Subtotal: 6/12

5. Commit Quality
   [x] Commit message clear                 PASS               5/5
   [x] History clean                        PASS               3/3
                                                        Subtotal: 8/8

───────────────────────────────────────────────────────────────────────────────
TOTAL SCORE:                                                  88/105
───────────────────────────────────────────────────────────────────────────────

RECOMMENDATION: NEEDS MINOR FIXES
═══════════════════════════════════════════════════════════════════════════════
```

---

## Phase 1: Submission Review

### 1.1 Applies to Current Master
**Status:** PASS (after rebase)

The original v5 patch needed rebasing due to:
- Test file numbering conflict: `050_drop_table_logging.pl` → `052_drop_table_logging.pl`
- `meson.build` context changes

### 1.2 No Debug Code
**Status:** PASS

```bash
$ git diff | grep -E 'printf|elog.*DEBUG|#if 0|fprintf|XXX|TODO|FIXME'
# No matches
```

### 1.3 pgindent Clean
**Status:** FAIL

Space indentation found instead of tabs:
```c
// src/backend/access/transam/xact.c:2250
    XLogRecPtr commit_lsn = InvalidXLogRecPtr;  // Uses spaces

// src/backend/catalog/dependency.c:237, 283
        return;  // Uses spaces
```

**Fix Required:** Run `pgindent` on modified files.

---

## Phase 2: Functional Review

### 2.1 Implements Described Functionality
**Status:** PASS

| Feature | Implemented | Tested |
|---------|-------------|--------|
| DROP TABLE logging | Yes | Yes |
| DROP DATABASE logging | Yes | Yes |
| Commit LSN (not WAL insert ptr) | Yes (DROP TABLE) | Yes |
| ROLLBACK handling | Yes | Yes |
| SAVEPOINT/ROLLBACK TO | Yes | Yes |
| GUC on/off | Yes | Yes |

### 2.2 Edge Cases Handled
**Status:** PARTIAL

| Edge Case | Handled | Notes |
|-----------|---------|-------|
| NULL schema name | Yes | Falls back to "unknown" |
| Empty transaction | Yes | No log if no drops |
| Parallel workers | Yes | Uses PARALLEL_COMMIT event |
| Partitioned tables | Yes | Each partition logged |
| TEMP tables | Yes | Logged (may be noisy) |
| UNLOGGED tables | Yes | Logged |
| CASCADE drops | Yes | Each table logged |

**Missing Edge Case Testing:**
- DROP TABLE IF NOT EXISTS (table doesn't exist)
- Concurrent DROP attempts
- DROP during recovery

### 2.3 Backwards Compatibility
**Status:** PASS with API change

The `XactCallback` signature changed:
```c
// Before
typedef void (*XactCallback) (XactEvent event, void *arg);

// After
typedef void (*XactCallback) (XactEvent event, void *arg, XLogRecPtr lsn);
```

All in-tree callers updated:
- `contrib/postgres_fdw/connection.c`
- `contrib/sepgsql/label.c`
- `src/pl/plpgsql/src/pl_exec.c`

**Note:** Extensions using `XactCallback` will need recompilation with updated signature.

---

## Phase 3: Code Quality Review

### 3.1 Postgres Coding Style
**Status:** PARTIAL - Issues Found

**Issue 1:** Inconsistent bracing style
```c
// dependency.c - Missing braces on multi-line condition
if ((relKind == RELKIND_RELATION ||
    relKind == RELKIND_PARTITIONED_TABLE)
    && log_object_drops)
{
```
Should be:
```c
if ((relKind == RELKIND_RELATION ||
     relKind == RELKIND_PARTITIONED_TABLE) &&
    log_object_drops)
{
```

**Issue 2:** Space vs Tab indentation (see 1.3)

### 3.2 Comments
**Status:** PASS

Comments explain purpose appropriately:
```c
/*
 * DropTableXactCallback
 * Transaction callback to log commit LSN for DROP TABLE operations.
 */
```

### 3.3 Unused Variables
**Status:** FAIL

```c
// dependency.c:249 - Compiler warning
List *new_list = NIL;  // Declared but never used
```

**Fix Required:** Remove unused variable or use it.

---

## Phase 4: Memory and Resource Review

### 4.1 Memory Allocation
**Status:** PASS

- Uses `TopTransactionContext` appropriately for transaction-lifetime data
- `palloc`/`pfree` balanced in cleanup
- `strlcpy` used for safe string copying

```c
oldcontext = MemoryContextSwitchTo(TopTransactionContext);
info = (DropTableInfo *) palloc(sizeof(DropTableInfo));
strlcpy(info->relname, relname, NAMEDATALEN);
// ...
MemoryContextSwitchTo(oldcontext);
```

### 4.2 Memory Leaks
**Status:** PASS

Cleanup occurs on all exit paths:
```c
if (event == XACT_EVENT_COMMIT ||
    event == XACT_EVENT_ABORT ||
    event == XACT_EVENT_PARALLEL_ABORT)
{
    foreach(lc, pending_drop_tables)
    {
        DropTableInfo *info = (DropTableInfo *) lfirst(lc);
        pfree(info);
    }
    list_free(pending_drop_tables);
    pending_drop_tables = NIL;
}
```

### 4.3 Resource Cleanup on Error
**Status:** PASS

The callback registration is one-time:
```c
if (!drop_table_callback_registered)
{
    RegisterXactCallback(DropTableXactCallback, NULL);
    RegisterSubXactCallback(DropTableSubXactCallback, NULL);
    drop_table_callback_registered = true;
}
```

---

## Phase 5: Security Review

### 5.1 SQL Injection
**Status:** PASS - Not Applicable

No SQL construction from user input.

### 5.2 Buffer Overflows
**Status:** PASS

Uses safe functions:
```c
strlcpy(info->relname, relname, NAMEDATALEN);
strlcpy(info->schemaname, schemaname, NAMEDATALEN);
```

### 5.3 Privilege Checks
**Status:** PASS

GUC restricted to superusers:
```c
// guc_parameters.dat
{ name => 'log_object_drops', type => 'bool', context => 'PGC_SUSET', ...
```

### 5.4 Information Leakage
**Status:** PASS

Log messages only show:
- Schema name
- Table name
- OID
- LSN

No sensitive data exposed. Log access already requires appropriate privileges.

---

## Phase 6: Performance Review

### 6.1 Algorithm Complexity
**Status:** PASS

- List traversal is O(n) where n = dropped tables in transaction
- Typical n is very small (1-10 tables)
- CASCADE scenarios could be larger but still bounded

### 6.2 Memory Allocations in Loops
**Status:** PASS

Allocations occur once per dropped table, not in tight loops.

### 6.3 Locking
**Status:** PASS

No additional locks introduced. Uses existing transaction infrastructure.

### 6.4 Catalog Cache Impact
**Status:** PASS

Minimal additional catalog lookups:
- `get_rel_name()` - already cached
- `get_rel_namespace()` - already cached
- `get_namespace_name()` - already cached

---

## Phase 7: Test Coverage Review

### 7.1 New Functionality Tested
**Status:** PASS

Comprehensive TAP test file: `t/052_drop_table_logging.pl` (543 lines)

| Test | Coverage |
|------|----------|
| Basic DROP TABLE | Yes |
| ROLLBACK (no log) | Yes |
| SAVEPOINT/ROLLBACK TO | Yes |
| COMMIT AND CHAIN | Yes |
| DROP DATABASE | Yes |
| CASCADE drops | Yes |
| Multiple tables | Yes |
| Partitioned tables | Yes |
| Schema drops | Yes |
| GUC on/off | Yes |
| PL/pgSQL exception blocks | Yes |

### 7.2 Error Path Testing
**Status:** PARTIAL

Missing tests:
- [ ] DROP TABLE IF NOT EXISTS (non-existent table)
- [ ] Invalid OID handling
- [ ] Out of memory during registration

### 7.3 Concurrent Access
**Status:** NOT TESTED

No isolation tests for concurrent DROP operations.

---

## Phase 8: Documentation Review

### 8.1 User Documentation
**Status:** PASS

Added to `doc/src/sgml/config.sgml`:
- Parameter description
- Example output
- Use cases
- Performance warning for large schemas

### 8.2 Release Notes
**Status:** MISSING

No entry in `doc/src/sgml/release-19.sgml`.

**Fix Required:** Add release notes entry for new GUC.

### 8.3 Examples
**Status:** PARTIAL

Documentation shows example output but doesn't demonstrate PITR recovery workflow.

---

## Critical Issues Found

### CRITICAL-1: Format String Bug (FIXED)
**Severity:** Critical
**Location:** `src/backend/catalog/dependency.c:294-300`
**Status:** Fixed in review

Original code had mismatched format arguments:
```c
// BUG: 4 format args expected, only 2 provided
"drop LSN: %X/%X, commit LSN: %X/%X"
LSN_FORMAT_ARGS(commit_lsn)  // Only 2 values!
```

### CRITICAL-2: GUC Ordering (FIXED)
**Severity:** Critical (build failure)
**Location:** `src/backend/utils/misc/guc_parameters.dat`
**Status:** Fixed in review

Entry must be alphabetically ordered.

---

## Major Issues

### MAJOR-1: Inconsistent LSN Source
**Severity:** Major
**Location:** `src/backend/commands/dbcommands.c:1854`

DROP DATABASE uses `GetXLogInsertRecPtr()` while DROP TABLE uses commit LSN from `XactCallback`. This inconsistency should be addressed.

```c
// DROP DATABASE - uses WAL insert pointer (old approach)
XLogRecPtr current_lsn = GetXLogInsertRecPtr();

// DROP TABLE - uses commit LSN (correct approach)
DropTableXactCallback(..., XLogRecPtr commit_lsn)
```

**Recommendation:** Modify DROP DATABASE to also use commit LSN for consistency, or document the difference clearly.

### MAJOR-2: Missing Release Notes
**Severity:** Major
**Location:** `doc/src/sgml/release-19.sgml`

New user-visible feature requires release notes entry.

---

## Minor Issues

### MINOR-1: Unused Variable
**Severity:** Minor (compiler warning)
**Location:** `src/backend/catalog/dependency.c:249`

```c
List *new_list = NIL;  // Declared but never used
```

### MINOR-2: Space Indentation
**Severity:** Minor (style)
**Locations:**
- `src/backend/access/transam/xact.c:2250`
- `src/backend/catalog/dependency.c:237, 283`

Use tabs, not spaces for indentation.

### MINOR-3: TEMP Table Logging
**Severity:** Minor (behavior)
**Location:** Feature behavior

Temporary tables are logged when dropped. This could be noisy. Consider:
- Adding option to exclude temp tables
- Documenting this behavior explicitly

---

## Questions for Human Review

1. **Architecture:** Is extending `XactCallback` signature the right approach, or should this use a separate mechanism?

2. **Scope:** Should this also cover:
   - TRUNCATE TABLE?
   - DROP SCHEMA (without CASCADE)?
   - DROP INDEX?

3. **TEMP Tables:** Should temporary table drops be logged? They can't be recovered via PITR anyway.

4. **Extension API:** The `XactCallback` signature change breaks extensions. Is this acceptable for a new feature, or should we use a different approach?

5. **LSN Consistency:** Should DROP DATABASE use the same commit LSN approach as DROP TABLE?

---

## Positive Observations

1. **Well-Structured Code:** The callback registration and cleanup pattern is clean and follows existing Postgres patterns.

2. **Comprehensive Tests:** The 543-line TAP test file covers many scenarios thoroughly.

3. **Good Documentation:** The SGML documentation explains the feature well with examples.

4. **Memory Safety:** Proper use of memory contexts and safe string functions.

5. **Subtransaction Handling:** Correctly handles SAVEPOINT and ROLLBACK TO scenarios.

---

## Remediation Checklist

Before resubmission:

- [ ] Run `pgindent` on all modified `.c` and `.h` files
- [ ] Remove unused `new_list` variable in `DropTableSubXactCallback`
- [ ] Add release notes entry in `doc/src/sgml/release-19.sgml`
- [ ] Address DROP DATABASE LSN inconsistency (fix or document)
- [ ] Consider whether TEMP tables should be excluded
- [ ] Add comment explaining `XactCallback` signature change rationale

---

## Files Reviewed

| File | Lines Changed | Issues |
|------|---------------|--------|
| `src/backend/catalog/dependency.c` | +167 | Style, unused var |
| `src/backend/access/transam/xact.c` | +15, -6 | Style (spaces) |
| `src/backend/commands/dbcommands.c` | +10 | LSN inconsistency |
| `src/include/access/xact.h` | +1, -1 | API change |
| `src/include/utils/guc.h` | +1 | OK |
| `src/backend/utils/misc/guc_parameters.dat` | +7 | OK (after fix) |
| `src/backend/utils/misc/guc_tables.c` | +1 | OK |
| `doc/src/sgml/config.sgml` | +45 | OK |
| `contrib/postgres_fdw/connection.c` | +2, -2 | OK |
| `contrib/sepgsql/label.c` | +1, -1 | OK |
| `src/pl/plpgsql/src/pl_exec.c` | +1, -1 | OK |
| `src/pl/plpgsql/src/plpgsql.h` | +1, -1 | OK |
| `src/test/recovery/meson.build` | +1 | OK |
| `src/test/recovery/t/052_drop_table_logging.pl` | +543 | OK |

---

## Conclusion

The `log_object_drops` patch implements a useful feature for simplifying PITR recovery after accidental table drops. The core functionality is sound and well-tested.

**Critical bugs were found and fixed** during this review:
1. Format string mismatch causing garbage output
2. GUC alphabetical ordering causing build failure

**Remaining issues** that should be addressed:
1. Run pgindent (style)
2. Remove unused variable (compiler warning)
3. Add release notes (documentation)
4. Consider DROP DATABASE LSN approach (consistency)

**Final Assessment:** The patch is close to ready but needs one more revision cycle to address the remaining issues before it should be committed.

---

*Review performed using REV Framework (pg-review + pg-readiness agents)*
*Branch: `claude/review-postgres-patch-MWGUs`*
