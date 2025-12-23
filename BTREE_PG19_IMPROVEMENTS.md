# PostgreSQL 19 B-Tree Improvements Research

## Summary

PostgreSQL 19 (in development, expected September 2026) has several B-tree improvements in progress, with the most significant being **B-tree page merging during VACUUM** to reduce index bloat - a potential storage compaction improvement.

---

## Major B-Tree Improvements in PostgreSQL 19 Development

### 1. B-tree Page Merge During VACUUM (In Development)

**Authors:** Andrey Borodin, Kirk Wolak, Nik Everett
**Status:** Work-in-progress, under review by Peter Geoghegan

**What it does:**
- Automatically merges nearly-empty B-tree leaf pages during VACUUM
- Reduces index bloat from sparse pages left after deletions
- Addresses a long-standing operational pain point

**Problem addressed:**
PostgreSQL's traditional page deletion only removes completely empty pages. Deleted tuples leave behind sparsely populated pages (e.g., 95% empty) that cause significant index bloat.

**Implementation details:**
- New `mergefactor` reloption (default 5%, configurable 0-50%)
- When a page exceeds the threshold (e.g., 95% empty), tuples are moved to the right sibling page
- Source page is then deleted using existing page deletion mechanisms
- Works during regular VACUUM operations

**This IS a storage compaction improvement** - directly addresses B-tree bloat.

---

### 2. Skip Scan Refinements (Hardening PG18 Feature)

**Author:** Peter Geoghegan

Skip Scan (introduced in PG18) is being refined in PG19:

- **Row comparison design refinements** (commit b8f1c628, Nov 2025)
- **Robustness improvements for redundant nbtree keys** (commit f09816a0, Jul 2025)
- **Better handling during nbtree array scans** (commit bd3f59fd, Jul 2025)

---

### 3. Posting List TID Ordering Optimization (December 2025)

**What it does:**
- TIDs returned in descending order during backwards scans from posting list tuples
- Reduces buffer hits for backwards scans

---

### 4. B-tree Compression Patch (CommitFest #494)

**Title:** "Effective Storage of Duplicates in B-Tree Index"
**Status:** Active in PG19-4 CommitFest, needs review

**What it does:**
- Enhanced deduplication mechanisms for duplicate key values
- Posting lists to store multiple heap TIDs efficiently
- WAL optimization for duplicate handling

This is being revisited from earlier efforts (2015-2016) with updated implementations.

---

## CommitFest Patches for PG19

| Patch | Title | Status |
|-------|-------|--------|
| #494 | B-tree compression | Active, needs review |
| #4455 | nbtree ScalarArrayOp optimization | Committed in PG18, maintained |
| #2202 | B-tree deduplication | Under consideration |

---

## Recent Commits (Late 2025)

| Date | Commit | Description |
|------|--------|-------------|
| Dec 2025 | - | Posting list TID ordering for backwards scans |
| Nov 2025 | b8f1c628 | Row comparison design refinements |
| Oct 2025 | - | nbtree row comparison documentation |
| Jul 2025 | f09816a0 | Robustness for redundant nbtree keys |
| Jul 2025 | bd3f59fd | Better handling during array scans |

---

## Storage Compaction Assessment

**YES - PG19 has potential storage compaction improvements:**

1. **B-tree page merge during VACUUM** (in development)
   - Directly addresses index bloat from sparse pages
   - Automatic during VACUUM
   - Configurable via `mergefactor` reloption

2. **B-tree compression patch** (in review)
   - Enhanced duplicate storage efficiency
   - Building on existing deduplication

---

## Key Contributors

- **Peter Geoghegan:** Skip scan refinements, posting list optimizations, patch review
- **Andrey Borodin:** B-tree page merge during vacuum (major new feature)
- **Álvaro Herrera:** Index check snapshot fixes
- **Heikki Linnakangas:** Testing infrastructure for incomplete splits

---

## Conclusion

PostgreSQL 19's most significant B-tree improvement is the **page merge during VACUUM** feature, which IS a storage compaction improvement. This addresses index bloat from partially-empty pages - a real operational problem for large databases with heavy update/delete workloads.

The feature is still under development and review, so it may or may not make it into the final PG19 release.

---

## References

- PostgreSQL CommitFest PG19-4: https://commitfest.postgresql.org/57/
- B-tree Page Merge Discussion: pgsql-hackers mailing list (Aug 2025)
- PostgreSQL Development Roadmap
