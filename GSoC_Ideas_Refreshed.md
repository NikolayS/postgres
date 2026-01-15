# PostgreSQL GSoC Ideas - Refreshed from 2008-2021

This document reviews Google Summer of Code project ideas for PostgreSQL core from 2008-2021, analyzing which were implemented and which remain relevant for future GSoC participation.

## Summary

| Status | Count |
|--------|-------|
| Implemented | 14 |
| Still Relevant | 12 |
| Partially Implemented | 4 |

---

## Already Implemented Ideas (Not Suitable for New GSoC)

These ideas from past GSoC years have been implemented in PostgreSQL:

### 1. UPDATE/DELETE ... RETURNING OLD/NEW (GSoC 2013-2015)
- **Status:** Implemented in PostgreSQL 18
- **Original Idea:** Allow RETURNING clause to return both old and new values for UPDATE statements
- **Implementation:** PostgreSQL 18 added `OLD` and `NEW` aliases in RETURNING clauses for INSERT/UPDATE/DELETE/MERGE
- **Example:** `UPDATE products SET price = price * 1.10 RETURNING old.price, new.price`

### 2. WAL Logging for Hash Indexes (GSoC 2015)
- **Status:** Implemented in PostgreSQL 10
- **Original Idea:** Implement WAL logging for hash indexes to make them crash-safe
- **Implementation:** Hash indexes became fully WAL-logged and crash-safe in PostgreSQL 10, thanks to Amit Kapila and team

### 3. GiST Microvacuum (GSoC 2015)
- **Status:** Implemented September 2015
- **Original Idea:** Support microvacuum for GiST indexes
- **Implementation:** Commit 013ebc0a7b by Teodor Sigaev implemented GiST microvacuum

### 4. Page-Level Predicate Locking for Index AMs (GSoC 2016/2017)
- **Status:** Implemented in PostgreSQL 11
- **Original Idea:** Implement page-level predicate locking for GiST, GIN, and Hash indexes
- **Implementation:** Thanks to GSoC student Shubham Barai, PostgreSQL 11 shipped with predicate lock support for hash, GIN, and GiST indexes

### 5. Parallel GIN Index Build (GSoC 2015)
- **Status:** Implemented in PostgreSQL 18
- **Original Idea:** Use background workers to parallelize GIN index construction
- **Implementation:** PostgreSQL 18 allows parallel CREATE INDEX for GIN indexes, achieving ~30% speedup

### 6. btree_gist Sortsupport (Related to GiST Build Performance)
- **Status:** Implemented in PostgreSQL 18
- **Original Idea:** Improve GiST build performance
- **Implementation:** btree_gist now uses sortsupport by default in PostgreSQL 18, enabling much faster sorted builds

### 7. Constraint Exclusion for CHECK Constraints (GSoC 2015)
- **Status:** Already implemented (predates 2015)
- **Original Idea:** Check WHERE clause against CHECK constraints for optimization
- **Implementation:** The `constraint_exclusion` parameter controls this feature

### 8. Buffered GiST Build (GSoC 2011)
- **Status:** Implemented in PostgreSQL 9.2
- **Original Idea:** Fast GiST index build using buffering to reduce random I/O
- **Implementation:** Alexander Korotkov implemented buffered GiST build during GSoC 2011
- **Notes:** Dramatically reduces random I/O for non-ordered data sets

### 9. Materialized Views (GSoC 2010)
- **Status:** Implemented in PostgreSQL 9.3
- **Original Idea:** Support materialized views for pre-computing expensive queries
- **Implementation:** Pavel Baroš worked on this during GSoC 2010; shipped in PG 9.3
- **Notes:** Was #1 requested feature in PostgreSQL user surveys

### 10. SKIP LOCKED (GSoC 2014)
- **Status:** Implemented in PostgreSQL 9.5
- **Original Idea:** Add "nowait" SELECT option to skip locked rows instead of blocking
- **Implementation:** SKIP LOCKED modifier for FOR UPDATE, committed October 2014

### 11. Foreign Data Wrappers (GSoC 2011)
- **Status:** Implemented (SQL/MED standard)
- **Original Idea:** Write FDWs for external data sources (ODBC, MySQL, etc.)
- **Implementation:** FDW infrastructure added in PG 9.1; many wrappers now exist

### 12. Incremental Sort (Long-standing TODO)
- **Status:** Implemented in PostgreSQL 13
- **Original Idea:** Sort data incrementally when rows arrive partially sorted
- **Implementation:** Added in PG 13, enhanced in PG 14 (window functions) and PG 16 (DISTINCT)

### 13. Index Skip Scan / Loose Index Scan (Long-standing TODO)
- **Status:** Implemented in PostgreSQL 18
- **Original Idea:** Allow index scans to skip over leading columns with low cardinality
- **Implementation:** Skip scan added in PostgreSQL 18, works automatically

### 14. Memoize for Parameterized Nested Loops (Planner TODO)
- **Status:** Implemented in PostgreSQL 14
- **Original Idea:** Cache results for parameterized nested loop inner side
- **Implementation:** Memoize plan node added in PG 14, enhanced in PG 16

---

## Still Relevant Ideas (Suitable for New GSoC)

These ideas from 2008-2021 have NOT been fully implemented and remain valid for future GSoC:

### 1. RETURNING for DDL Statements
- **Original Year:** GSoC 2013-2015
- **Description:** Add RETURNING clause support to DDL statements (CREATE, ALTER, DROP) and possibly DCL (GRANT, REVOKE)
- **Current Status:** NOT implemented - RETURNING only works with DML (INSERT, UPDATE, DELETE, MERGE)
- **Relevance:** High - Would enable capturing metadata about created/altered objects in a single statement
- **Skills Required:** C, PostgreSQL internals, parser/executor knowledge
- **Complexity:** Medium-High
- **Use Cases:**
  - `CREATE TABLE foo (...) RETURNING oid, relname`
  - `ALTER TABLE foo ADD COLUMN bar int RETURNING *`
  - Useful for migration tools and DDL auditing

### 2. Simulated Annealing Query Optimizer (GEQO Replacement)
- **Original Year:** GSoC 2010, 2015
- **Description:** Implement Simulated Annealing as an alternative to GEQO for join ordering in complex queries
- **Current Status:** NOT implemented - Jan Urbanski's SAIO prototype (PGCon 2010) exists but was never merged
- **Relevance:** High - GEQO has known limitations; SA showed better results for large queries
- **Skills Required:** C, optimization algorithms, query planning internals
- **Complexity:** High
- **Reference:**
  - https://github.com/wulczer/saio
  - [PGCon 2010 Presentation](https://www.pgcon.org/2010/schedule/attachments/150_saio.pdf)
- **Notes:** PostgreSQL TODO still lists "Consider compressed annealing to search for query plans"

### 3. Join Removal Based on Foreign Key Constraints
- **Original Year:** GSoC 2014-2015
- **Description:** Add ability to remove joins to tables when the join is on a foreign key column and only the child table columns are needed
- **Current Status:** NOT implemented - PostgreSQL lacks automatic FK-based join elimination unlike Oracle/DB2
- **Relevance:** High - Common optimization in enterprise databases that PostgreSQL is missing
- **Skills Required:** C, query optimizer internals
- **Complexity:** Medium-High
- **Example:**
  ```sql
  -- View joining orders to customers
  CREATE VIEW order_summary AS
    SELECT o.* FROM orders o JOIN customers c ON o.customer_id = c.id;

  -- Query only uses order columns - join should be eliminated
  SELECT order_id, amount FROM order_summary;
  ```

### 4. Parallel GiST Index Build
- **Original Year:** GSoC 2017-2018
- **Description:** Enable parallel workers for GiST index construction
- **Current Status:** Work in Progress - Patches exist but not yet merged (PostgreSQL 18 supports B-tree, GIN, BRIN but NOT GiST)
- **Relevance:** High - Would significantly speed up GiST index creation for large spatial datasets
- **Skills Required:** C, PostgreSQL parallel infrastructure, GiST internals
- **Complexity:** High

### 5. GiST Bulk Loading API
- **Original Year:** GSoC 2011, 2015, 2017, 2018
- **Description:** Create a proper bulk loading API for GiST indexes instead of one-by-one insertion
- **Current Status:** Partially addressed - Buffered build exists but no true bulk loading API
- **Relevance:** Medium - Sortsupport in PG18 addresses some use cases, but API improvements still valuable
- **Skills Required:** C, GiST internals, algorithm design
- **Complexity:** High
- **Notes:** Would benefit custom opclass developers; current AM interface lacks bulk insert function

### 6. Per-Datatype TOAST Slicing Strategies
- **Original Year:** GSoC 2015
- **Description:** Allow different datatypes to be sliced differently when TOASTed
- **Current Status:** NOT implemented - TOAST uses fixed ~2KB chunks for all types
- **Relevance:** Medium - Could optimize storage for specific data patterns
- **Skills Required:** C, PostgreSQL storage internals
- **Complexity:** Medium
- **Potential Benefits:**
  - Optimal chunk sizes for JSON vs BYTEA vs TEXT
  - Better compression ratios for structured data

### 7. SP-GiST for Extended Geometrical Objects
- **Original Year:** GSoC 2014-2015
- **Description:** Index prolonged geometrical objects (boxes, circles, polygons) with SP-GiST by mapping to 4D-space
- **Current Status:** Partially implemented in PostGIS, not in core PostgreSQL
- **Relevance:** Medium - PostGIS has spgist_geometry_ops but core geometry types lack this
- **Skills Required:** C, computational geometry, SP-GiST internals
- **Complexity:** Medium-High

### 8. Regression Test Coverage Improvements
- **Original Year:** GSoC 2017, 2020
- **Description:** Significantly improve PostgreSQL regression test coverage (target: 73% -> 80%+)
- **Current Status:** Ongoing need - Coverage still not at target levels
- **Relevance:** High - Critical for project quality
- **Skills Required:** SQL, Perl (TAP tests), C (for understanding code paths)
- **Complexity:** Medium (but tedious)
- **Mentor History:** Stephen Frost (committer)
- **Notes:** Some code paths are at single-digit coverage levels

### 9. amcheck for SP-GiST
- **Original Year:** GSoC 2019
- **Description:** Extend amcheck to verify integrity of SP-GiST indexes
- **Current Status:**
  - GiST: Patch in review for PG19
  - GIN: Patch in review for PG19
  - BRIN: Patch in review for PG19
  - **SP-GiST: NOT yet planned**
- **Relevance:** High - Only index type without amcheck support planned
- **Skills Required:** C, index access method internals
- **Complexity:** Medium-High

### 10. ALTER TABLE SET LOGGED/UNLOGGED Performance
- **Original Year:** GSoC 2015
- **Description:** Improve performance by avoiding full table rewrite when changing table persistence
- **Current Status:** Unknown/Partially addressed - Original feature in PG 9.5 required rewrite
- **Relevance:** Medium - Would benefit bulk data loading workflows
- **Skills Required:** C, PostgreSQL storage internals, WAL
- **Complexity:** High
- **Goal:** When `wal_level = minimal`, avoid rewriting entire heap

### 11. Global Temporary Tables
- **Original Year:** Long-standing TODO
- **Description:** Implement SQL-standard global temporary tables where definition is shared but data is session-private
- **Current Status:** NOT implemented in community PostgreSQL (available in PgPro-EE)
- **Relevance:** Medium-High - Important for Oracle/DB2 migration compatibility
- **Skills Required:** C, catalog management, session handling
- **Complexity:** High
- **Notes:** Different from current temp tables where even metadata is session-local

### 12. Autonomous Transactions
- **Original Year:** Long-standing TODO
- **Description:** Allow transactions that can commit/rollback independently of their parent transaction
- **Current Status:** NOT implemented in community PostgreSQL (available in PgPro-EE)
- **Relevance:** Medium - Important for logging, auditing within transactions
- **Skills Required:** C, transaction management internals
- **Complexity:** Very High
- **Use Cases:**
  - Audit logging that persists even if main transaction rolls back
  - Error logging within exception handlers

---

## Ideas That Evolved or Were Superseded

### High Availability with Logical Replication (GSoC 2018)
- **Original Idea:** Create HA solution using logical replication instead of physical replication
- **Status:** Ecosystem has evolved - Tools like pg_failover_slots, pglogical, and native logical replication improvements address many use cases
- **Relevance:** Low for core GSoC - Better suited for external projects

### Materialized View Incremental Refresh (GSoC 2010+)
- **Original Idea:** Support incremental refresh of materialized views
- **Status:** Active development - Incremental View Maintenance (IVM) patches are being developed
- **Relevance:** Being actively worked on by community members

### pgwatch/WAL-G Improvements (GSoC 2020-2021)
- **Status:** These are external ecosystem projects, not core PostgreSQL
- **Note:** Still valid GSoC projects but outside PostgreSQL core scope

### UPSERT / ON CONFLICT (Pre-2015)
- **Status:** Implemented in PostgreSQL 9.5 (INSERT ... ON CONFLICT)

### SQL MERGE Statement
- **Status:** Implemented in PostgreSQL 15

---

## Planner/Optimizer TODO Items Still Open

From the PostgreSQL Wiki TODO list, these optimizer improvements remain unimplemented:

### 1. Viewing Rejected Planner Paths
- **Description:** Add useful way to see paths rejected by the planner
- **Notes:** OPTIMIZER_DEBUG exists but requires compile-time flag and gets little use

### 2. Row Estimate Logging
- **Description:** Log statements where optimizer row estimates differed dramatically from actual rows
- **Relevance:** Would help identify statistics problems

### 3. Cardinality-Reducing Functions Support
- **Description:** Add planner support for functions that reduce cardinality
- **Notes:** `estimate_num_groups` assumes functions don't meaningfully decrease cardinality

### 4. Window Function Ordering Optimization
- **Description:** Teach planner to evaluate multiple windows in optimal order
- **Notes:** Currently windows are always evaluated in query-specified order

---

## Recommended High-Priority Ideas for New GSoC

Based on impact, feasibility, and community interest:

### Tier 1 (High Priority - Core Impact)
1. **Join Removal Based on Foreign Keys** - Missing from PostgreSQL vs competitors
2. **Simulated Annealing Query Optimizer** - Potential significant improvement over GEQO
3. **Regression Test Coverage** - Always needed, well-defined scope
4. **Global Temporary Tables** - Important for enterprise migration

### Tier 2 (Medium Priority - Completes Features)
5. **RETURNING for DDL** - Useful feature, moderate complexity
6. **Parallel GiST Index Build** - Completes parallel index support
7. **amcheck for SP-GiST** - Only index type without amcheck support planned
8. **Planner Path Debugging** - Would help developers and DBAs

### Tier 3 (Specialized - Niche Value)
9. **Per-Datatype TOAST Strategies** - Niche but interesting
10. **GiST Bulk Loading API** - Benefits opclass developers
11. **SP-GiST 4D Geometry** - Specialized spatial use case
12. **Autonomous Transactions** - Complex, but high enterprise value

---

## Historical GSoC Participation

PostgreSQL has participated in GSoC since 2006. Notable successful projects include:

| Year | Project | Outcome |
|------|---------|---------|
| 2006 | Initial participation | Foundation laid |
| 2010 | Materialized Views | Shipped in PG 9.3 |
| 2010 | SAIO Prototype | Not merged, but proved concept |
| 2011 | Buffered GiST Build | Shipped in PG 9.2 |
| 2011 | Foreign Data Wrappers | Core FDW infrastructure |
| 2014 | SET LOGGED/UNLOGGED | Shipped in PG 9.5 |
| 2017 | Predicate Locking | Shipped in PG 11 |

---

## References

### GSoC Wiki Pages
- [GSoC 2006](https://wiki.postgresql.org/wiki/GSoC_2006)
- [GSoC 2007](https://wiki.postgresql.org/wiki/GSoC_2007)
- [GSoC 2008](https://wiki.postgresql.org/wiki/GSoC_2008)
- [GSoC 2009](https://wiki.postgresql.org/wiki/GSoC_2009)
- [GSoC 2010](https://wiki.postgresql.org/wiki/GSoC_2010)
- [GSoC 2011](https://wiki.postgresql.org/wiki/GSoC_2011)
- [GSoC 2012](https://wiki.postgresql.org/wiki/GSoC_2012)
- [GSoC 2013](https://wiki.postgresql.org/wiki/GSoC_2013)
- [GSoC 2014](https://wiki.postgresql.org/wiki/GSoC_2014)
- [GSoC 2015](https://wiki.postgresql.org/wiki/GSoC_2015)
- [GSoC 2016](https://wiki.postgresql.org/wiki/GSoC_2016)
- [GSoC 2017](https://wiki.postgresql.org/wiki/GSoC_2017)
- [GSoC 2018](https://wiki.postgresql.org/wiki/GSoC_2018)
- [GSoC 2019](https://wiki.postgresql.org/wiki/GSoC_2019)
- [GSoC 2020](https://wiki.postgresql.org/wiki/GSoC_2020)
- [GSoC 2021](https://wiki.postgresql.org/wiki/GSoC_2021)
- [GSoC 2025](https://wiki.postgresql.org/wiki/GSoC_2025)

### Other Resources
- [PostgreSQL TODO](https://wiki.postgresql.org/wiki/Todo)
- [Materialized Views GSoC 2010](https://wiki.postgresql.org/wiki/Materialized_Views_GSoC_2010)
- [Fast GiST Build GSoC 2011](https://wiki.postgresql.org/wiki/Fast_GiST_index_build_GSoC_2011)
- [Predicate Locks GSoC 2017](https://wiki.postgresql.org/wiki/Predicate_locks_in_index_GSoC_2017)
- [SSI (Serializable Snapshot Isolation)](https://wiki.postgresql.org/wiki/SSI)
- [SAIO Prototype (GitHub)](https://github.com/wulczer/saio)
- [PGCon 2010: Replacing GEQO](https://www.pgcon.org/2010/schedule/events/211.en.html)

---

*Document generated: January 2026*
*Based on review of PostgreSQL GSoC ideas 2008-2021 and current PostgreSQL 18 status*
