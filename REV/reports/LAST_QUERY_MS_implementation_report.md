# Implementation Report: LAST_QUERY_MS Feature

**Feature:** Always measure psql query timing, store in `LAST_QUERY_MS` variable
**Author:** Kirk (idea), AI-assisted implementation
**Branch:** `claude/test-timing-idea-n0hWB`
**Date:** 2026-01-07

---

## Summary

Kirk's idea: psql `\timing on/off` should only control output display. The execution time should ALWAYS be measured and stored in a variable, since measuring is a lightning-fast operation while displaying slows things down.

**Implementation:** Added `LAST_QUERY_MS` variable that always contains the last query's execution time in milliseconds, regardless of `\timing` setting.

---

## Subagents Used

| Agent | Purpose | Model | Result |
|-------|---------|-------|--------|
| `general-purpose` | Initial code review and bug detection | sonnet | Found 3 critical bugs |
| `general-purpose` | Re-review after fixes | haiku | Verified all bugs fixed |

**Note:** Used generic agents with custom review prompts. Specialized `pg-review` agent from REV/.claude/agents/ available but not directly invoked.

---

## Review Coverage

### Code Paths Analyzed

| Function | File | Purpose |
|----------|------|---------|
| `ExecQueryAndProcessResults()` | common.c | Main query execution |
| `SendQuery()` | common.c | Interactive query handler |
| `PSQLexecWatch()` | common.c | `\watch` command handler |
| `DescribeQuery()` | common.c | `\gdesc` command handler |

### Bugs Detected and Fixed

| Bug | Severity | Location | Issue | Status |
|-----|----------|----------|-------|--------|
| #1 | CRITICAL | `ExecQueryAndProcessResults` ~L1727 | Early failure path returned without setting `elapsed_msec` | FIXED |
| #2 | CRITICAL | `DescribeQuery` (4 paths) | PQprepare failure, PQescapeLiteral failure, no-columns case, AcceptResult failure - all missing timing | FIXED |
| #3 | DOCUMENTATION | `DescribeQuery` comment | Said "If pset.timing is on" but timing is now always measured | FIXED |

### Style Review

- Buffer sizes: 64 bytes (appropriate)
- Format string: `"%.3f"` (matches `PrintTiming()`)
- Indentation: Follows PostgreSQL conventions
- Variable naming: `LAST_QUERY_MS` consistent with `LAST_ERROR_*` pattern

### Test Coverage

**Initial test script covered:**
- Basic queries with timing on/off
- `pg_sleep` delays
- Conditional usage with `\if`

**Expanded after review to include:**
- Error queries (table not found)
- Syntax errors
- DDL commands (CREATE/DROP)
- `\gdesc` command
- Multiple statements
- Empty results

---

## Files Modified

| File | Changes |
|------|---------|
| `src/bin/psql/startup.c` | Initialize `LAST_QUERY_MS` to "0" |
| `src/bin/psql/common.c` | Remove conditional timing, always measure, set variable |
| `test_last_query_ms.sql` | Comprehensive test script (11 tests) |
| `TIMING_PATCH_README.md` | Build instructions and usage examples |

---

## Commits

```
735349f psql: Always measure query timing, store in LAST_QUERY_MS variable
f9c405f Add test script and README for LAST_QUERY_MS patch
aa8374a Fix critical bugs in LAST_QUERY_MS implementation
```

---

## What Wasn't Covered (Yet)

| Agent | Purpose | Status |
|-------|---------|--------|
| `pg-build` | Verify compilation | PENDING |
| `pg-test` | Run `make check` regression tests | PENDING |
| `pg-benchmark` | Measure overhead of always-on timing | PENDING |
| `pg-hackers-letter` | Draft submission email | PENDING |

---

## Usage Example

```sql
-- With \timing off (default), no output but variable is set:
postgres=# SELECT pg_sleep(0.1);
 pg_sleep
----------

(1 row)

postgres=# \echo :LAST_QUERY_MS
103.547

-- Use in scripts:
postgres=# SELECT expensive_query();
postgres=# \if :LAST_QUERY_MS > 1000
postgres=#   \echo 'WARNING: Query took more than 1 second'
postgres=# \endif
```

---

## Open Questions

1. **Variable name:** Kirk suggested `ELAPSED_MS`, we used `LAST_QUERY_MS`. Which is preferred?
2. **Precision:** Currently 3 decimal places (microsecond precision). Sufficient?
3. **Backward compatibility:** None required - new variable, existing behavior unchanged.

---

## Next Steps

1. Run `pg-build` to verify compilation
2. Run `pg-test` to run regression tests
3. Run `pg-benchmark` to measure overhead
4. Run `pg-hackers-letter` to draft submission email
