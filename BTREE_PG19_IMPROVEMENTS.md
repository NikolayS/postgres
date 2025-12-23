# PostgreSQL 19 B-Tree Improvements Research

## Summary

PostgreSQL 19 (in development, expected September 2026) has several B-tree improvements **already committed**, focused primarily on **scan performance optimizations**. The most anticipated storage compaction feature (page merge during VACUUM) is still in development.

---

## COMMITTED B-Tree Improvements in PostgreSQL 19

### 1. Avoid Pointer Chasing in _bt_readpage Inner Loop
**Commit:** 83a26ba59b1819cbd61705a3ff6aa572081ccc4b
**Date:** December 8, 2025
**Author:** Peter Geoghegan

Optimized page-reading logic by caching frequently-accessed scan state. **Over 5% throughput improvement** on range scan workloads.

---

### 2. Return TIDs in Descending Order During Backwards Scans
**Commit:** bfb335df58ea4274702039083c7e08fe3dba9e10
**Date:** December 10, 2025
**Author:** Peter Geoghegan

Backwards scans now return tuple IDs in descending order, reducing buffer hits and making scans more efficient. The `killedItems` array is also sorted to maintain consistency with page order assumptions.

---

### 3. Teach nbtree to Avoid Evaluating Row Compare Keys
**Commit:** 7d9cd2df5ffc2939ac84581c9463b8afc4ca4c41
**Date:** September 15, 2025
**Author:** Peter Geoghegan

Extended the `_bt_set_startikey` optimization to handle row comparison keys. Delivers performance improvements comparable to existing scalar inequality optimizations for range scans.

---

### 4. Improve Stability of B-tree Page Split on ERRORs
**Commit:** 85e0ff62b68224b3354e47fb71b78d309063d06c
**Date:** September 25, 2025
**Author:** Konstantin Knizhnik

Redesigned page splitting to use temporary buffers, preventing index corruption when errors occur outside the critical section.

---

## IN DEVELOPMENT (Not Yet Committed)

### B-tree Page Merge During VACUUM (Storage Compaction!)

**Authors:** Andrey Borodin, Kirk Wolak, Nik Everett
**Status:** Work-in-progress, under review by Peter Geoghegan

**What it does:**
- Automatically merges nearly-empty B-tree leaf pages during VACUUM
- Reduces index bloat from sparse pages left after deletions
- New `mergefactor` reloption (default 5%, configurable 0-50%)
- When a page exceeds the threshold (e.g., 95% empty), tuples move to sibling page

**This IS a storage compaction improvement** - directly addresses B-tree bloat.

---

### B-tree Compression Patch (CommitFest #494)

**Title:** "Effective Storage of Duplicates in B-Tree Index"
**Status:** Active in PG19-4 CommitFest, needs review

Enhanced deduplication mechanisms for duplicate key values with posting lists.

---

## Storage Compaction Assessment

**Committed:** No direct storage compaction improvements yet.

**In Development:**
1. **B-tree page merge during VACUUM** - addresses bloat from sparse pages
2. **B-tree compression patch** - enhanced duplicate storage

---

## Key Contributors

- **Peter Geoghegan:** Scan optimizations, row compare keys, backwards scan improvements
- **Konstantin Knizhnik:** Page split stability
- **Andrey Borodin:** B-tree page merge during vacuum (major new feature, in dev)

---

## References

- GitHub postgres/postgres commits: https://github.com/postgres/postgres/commits/master/src/backend/access/nbtree
- PostgreSQL CommitFest PG19-4: https://commitfest.postgresql.org/57/
- B-tree Page Merge Discussion: pgsql-hackers mailing list (Aug 2025)
