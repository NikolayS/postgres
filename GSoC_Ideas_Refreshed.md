# PostgreSQL GSoC Ideas - Refreshed from 2015-2021

This document reviews Google Summer of Code project ideas for PostgreSQL core from 2015-2021, analyzing which were implemented and which remain relevant for future GSoC participation.

## Summary

| Status | Count |
|--------|-------|
| Implemented | 7 |
| Still Relevant | 10 |
| Partially Implemented | 3 |

---

## Already Implemented Ideas (Not Suitable for New GSoC)

These ideas from past GSoC years have been implemented in PostgreSQL:

### 1. UPDATE/DELETE ... RETURNING OLD/NEW (GSoC 2015)
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
- **Implementation:** The `constraint_exclusion` parameter controls this feature, comparing query conditions with CHECK constraints to skip table scans

---

## Still Relevant Ideas (Suitable for New GSoC)

These ideas from 2015-2021 have NOT been fully implemented and remain valid for future GSoC:

### 1. RETURNING for DDL Statements
- **Original Year:** GSoC 2015
- **Description:** Add RETURNING clause support to DDL statements (CREATE, ALTER, DROP) and possibly DCL (GRANT, REVOKE)
- **Current Status:** NOT implemented - RETURNING only works with DML (INSERT, UPDATE, DELETE, MERGE)
- **Relevance:** High - Would enable capturing metadata about created/altered objects in a single statement
- **Skills Required:** C, PostgreSQL internals, parser/executor knowledge
- **Complexity:** Medium-High

### 2. Simulated Annealing Query Optimizer (GEQO Replacement)
- **Original Year:** GSoC 2015
- **Description:** Implement Simulated Annealing as an alternative to GEQO for join ordering in complex queries
- **Current Status:** NOT implemented - Jan Urbanski's SAIO prototype exists but was never merged
- **Relevance:** High - GEQO has known limitations; SA showed better results for large queries
- **Skills Required:** C, optimization algorithms, query planning internals
- **Complexity:** High
- **Reference:** https://github.com/wulczer/saio

### 3. Join Removal Based on Foreign Key Constraints
- **Original Year:** GSoC 2015
- **Description:** Add ability to remove joins to tables when the join is on a foreign key column and only the child table columns are needed
- **Current Status:** NOT implemented - PostgreSQL lacks automatic FK-based join elimination unlike Oracle/DB2
- **Relevance:** High - Common optimization in enterprise databases that PostgreSQL is missing
- **Skills Required:** C, query optimizer internals
- **Complexity:** Medium-High

### 4. Parallel GiST Index Build
- **Original Year:** GSoC 2017-2018
- **Description:** Enable parallel workers for GiST index construction
- **Current Status:** Work in Progress - Patches exist but not yet merged (PostgreSQL 18 supports B-tree, GIN, BRIN but NOT GiST)
- **Relevance:** High - Would significantly speed up GiST index creation for large spatial datasets
- **Skills Required:** C, PostgreSQL parallel infrastructure, GiST internals
- **Complexity:** High

### 5. GiST Bulk Loading API
- **Original Year:** GSoC 2015, 2017, 2018
- **Description:** Create a proper bulk loading API for GiST indexes instead of one-by-one insertion
- **Current Status:** Partially addressed - Buffered build exists but no true bulk loading API
- **Relevance:** Medium - Sortsupport in PG18 addresses some use cases, but API improvements still valuable
- **Skills Required:** C, GiST internals, algorithm design
- **Complexity:** High
- **Notes:** Would benefit custom opclass developers

### 6. Per-Datatype TOAST Slicing Strategies
- **Original Year:** GSoC 2015
- **Description:** Allow different datatypes to be sliced differently when TOASTed
- **Current Status:** NOT implemented - TOAST uses fixed ~2KB chunks for all types
- **Relevance:** Medium - Could optimize storage for specific data patterns
- **Skills Required:** C, PostgreSQL storage internals
- **Complexity:** Medium

### 7. SP-GiST for Extended Geometrical Objects
- **Original Year:** GSoC 2015
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

### 9. amcheck for Additional Index Types
- **Original Year:** GSoC 2019
- **Description:** Extend amcheck to verify integrity of GIN, GiST, SP-GiST, and BRIN indexes
- **Current Status:** In Development for PostgreSQL 19
  - GiST: Patch in review
  - GIN: Patch in review
  - BRIN: Patch in review
  - SP-GiST: NOT yet planned
- **Relevance:** High for SP-GiST - The others are being addressed
- **Skills Required:** C, index access method internals
- **Complexity:** Medium-High

### 10. ALTER TABLE SET LOGGED/UNLOGGED Performance
- **Original Year:** GSoC 2015
- **Description:** Improve performance by avoiding full table rewrite when changing table persistence
- **Current Status:** Unknown/Partially addressed - Original feature in PG 9.5 required rewrite
- **Relevance:** Medium - Would benefit bulk data loading workflows
- **Skills Required:** C, PostgreSQL storage internals, WAL
- **Complexity:** High

---

## Ideas That Evolved or Were Superseded

### High Availability with Logical Replication (GSoC 2018)
- **Original Idea:** Create HA solution using logical replication instead of physical replication
- **Status:** Ecosystem has evolved - Tools like pg_failover_slots, pglogical, and native logical replication improvements address many use cases
- **Relevance:** Low for core GSoC - Better suited for external projects

### pgwatch/WAL-G Improvements (GSoC 2020-2021)
- **Status:** These are external ecosystem projects, not core PostgreSQL
- **Note:** Still valid GSoC projects but outside PostgreSQL core scope

---

## Recommended High-Priority Ideas for New GSoC

Based on impact, feasibility, and community interest:

### Tier 1 (High Priority)
1. **Join Removal Based on Foreign Keys** - Missing from PostgreSQL vs competitors
2. **Simulated Annealing Query Optimizer** - Potential significant improvement over GEQO
3. **Regression Test Coverage** - Always needed, well-defined scope

### Tier 2 (Medium Priority)
4. **RETURNING for DDL** - Useful feature, moderate complexity
5. **Parallel GiST Index Build** - Completes parallel index support
6. **amcheck for SP-GiST** - Only index type without amcheck support planned

### Tier 3 (Specialized)
7. **Per-Datatype TOAST Strategies** - Niche but interesting
8. **GiST Bulk Loading API** - Benefits opclass developers
9. **SP-GiST 4D Geometry** - Specialized spatial use case

---

## References

- [GSoC 2015](https://wiki.postgresql.org/wiki/GSoC_2015)
- [GSoC 2016](https://wiki.postgresql.org/wiki/GSoC_2016)
- [GSoC 2017](https://wiki.postgresql.org/wiki/GSoC_2017)
- [GSoC 2018](https://wiki.postgresql.org/wiki/GSoC_2018)
- [GSoC 2019](https://wiki.postgresql.org/wiki/GSoC_2019)
- [GSoC 2020](https://wiki.postgresql.org/wiki/GSoC_2020)
- [GSoC 2021](https://wiki.postgresql.org/wiki/GSoC_2021)
- [GSoC 2025](https://wiki.postgresql.org/wiki/GSoC_2025)
- [PostgreSQL TODO](https://wiki.postgresql.org/wiki/Todo)

---

*Document generated: January 2026*
*Based on review of PostgreSQL GSoC ideas 2015-2021 and current PostgreSQL 18 status*
