# Draft Email for pgsql-hackers

**Agent:** pg-hackers-letter (general-purpose with email prompt)
**Date:** 2026-01-07

---

## Email

**Subject:** [PATCH] psql: Always measure query timing, store in LAST_QUERY_MS variable

Hi hackers,

I'd like to propose a small enhancement to psql's \timing feature that improves scriptability without affecting interactive use.

**Problem**

Currently, psql's \timing command controls both measurement and display of query execution time. This creates a dilemma for users writing psql scripts: they either clutter their output with timing information, or forgo timing measurements entirely. There's no way to access timing data programmatically for conditional logic like "if query took > 1 second, log a warning."

**Proposed Solution**

Decouple measurement from display: always measure query execution time (regardless of \timing setting) and store it in a new psql variable LAST_QUERY_MS. The \timing command continues to control only whether timing is displayed.

The performance argument for this change is straightforward: measuring time via clock_gettime(2) is negligible (nanoseconds), while formatting and displaying adds measurable overhead. There's no reason not to measure when the cost is effectively zero.

**Implementation**

The patch modifies src/bin/psql/common.c to:
- Remove conditional timing checks (previously: "if (pset.timing)")
- Always measure elapsed time in ExecQueryAndProcessResults() and DescribeQuery()
- Set LAST_QUERY_MS variable after every query (format: %.3f milliseconds)
- Ensure elapsed time is captured even on error paths (PQprepare failure, syntax errors, etc.)

The variable is initialized to "0" in startup.c, following the pattern of existing LAST_ERROR_* variables.

**Use Cases**

```sql
-- Conditional logic based on query performance
\timing off
SELECT expensive_operation();
\if :LAST_QUERY_MS > 1000
  \echo 'WARNING: Query exceeded 1 second'
\endif

-- Logging timing to a table
SELECT run_benchmark();
INSERT INTO timing_log VALUES (now(), :LAST_QUERY_MS);
```

**Testing**

I've included a comprehensive test script (test_last_query_ms.sql) covering:
- Basic queries with \timing on/off
- pg_sleep() delay verification
- Error handling (missing tables, syntax errors)
- DDL commands (no result columns)
- \gdesc command (uses DescribeQuery path)
- Multiple statements and empty results

All test cases confirm LAST_QUERY_MS is set correctly regardless of query outcome.

**Open Question: Variable Name**

I've named the variable LAST_QUERY_MS to match the LAST_ERROR_* pattern, but ELAPSED_MS might be more concise. Which do folks prefer? Other suggestions welcome.

**Backward Compatibility**

No compatibility concerns - this adds a new variable without changing any existing behavior. Scripts that don't reference LAST_QUERY_MS are unaffected.

Patch attached. I welcome feedback on the approach, variable naming, or any concerns about the implementation.

Best regards,
[Your Name]

---

**Files modified:**
- src/bin/psql/startup.c (variable initialization)
- src/bin/psql/common.c (always-on timing measurement)
- test_last_query_ms.sql (test coverage)
