# PostgreSQL 18 B-Tree Improvements Research

## Summary

PostgreSQL 18 introduced significant B-tree optimizations, primarily focused on **query execution efficiency** rather than storage compaction. The headline feature is **Skip Scan**, which fundamentally changes how multicolumn B-tree indexes can be utilized.

---

## Major B-Tree Improvements in PostgreSQL 18

### 1. Skip Scan for Multicolumn B-Tree Indexes (Headline Feature)

**Author:** Peter Geoghegan

**What it does:**
- Allows multicolumn B-tree indexes to be efficiently used when queries don't reference leading (leftmost) index columns
- Automatically generates dynamic equality constraints that iterate through each possible value in leading columns
- The index "skips" through sections without scanning irrelevant portions

**How it works:**
- Preprocessing adds "skip arrays" for unreferenced leading columns
- A query like `WHERE y = 4` on an index `(x, y)` becomes internally: `WHERE x = ANY('{every possible x value}') AND y = 4`
- The planner estimates if skip scan will be efficient based on column cardinality

**Key source files:**
- `src/backend/access/nbtree/nbtpreprocesskeys.c` - Skip array generation and processing
- `src/backend/access/nbtree/nbtcompare.c` - Skip support functions (`btint2skipsupport`, `btint4skipsupport`, etc.)
- `src/backend/access/nbtree/nbtreadpage.c` - Skip scan execution

**Performance impact:**
- Up to 630x faster in benchmarks for suitable queries
- Most effective when leading columns have low cardinality (few distinct values)
- Eliminates need for multiple single-column indexes in many cases

**Limitations:**
- Only benefits B-tree indexes (not GiST, GIN, etc. in v18)
- Not beneficial when leading columns have high cardinality
- Currently focuses on equality conditions on later columns

**Example:**
```sql
-- Index on (region, category, date)
-- Previously required full scan without region filter
-- Now uses skip scan efficiently:
SELECT * FROM sales WHERE category = 'Electronics' AND date > '2024-01-01';
```

---

### 2. btree_gist Extension Sortsupport

**Authors:** Bernd Helmle, Christoph Heiss (CYBERTEC)

**What it does:**
- Enables faster GiST index builds for btree_gist operator classes
- Pre-sorts data before index creation instead of using slow "buffered" method
- Applies to all btree_gist types: int2, int4, int8, float4, float8, char, text, varchar, bytea, name, etc.

**Performance impact:**
- Significant reduction in CREATE INDEX and REINDEX times
- Better locality in resulting index structures
- Fewer index pages accessed during queries

---

### 3. Range Type GiST/B-tree Sortsupport

**Author:** Bernd Helmle

**What it does:**
- Adds sortsupport routines for range types (int4range, int8range, numrange, tsrange, etc.)
- Accelerates index builds for range-based data

---

### 4. Enhanced EXPLAIN ANALYZE for Index Operations

**Author:** Peter Geoghegan

**What it does:**
- Automatically reports number of index lookups performed during index scans
- Shows "Index Lookups" metrics without manual BUFFERS option
- Enhanced VERBOSE mode includes CPU, WAL, and average read statistics

**Benefit:** Better visibility into B-tree index efficiency for query tuning

---

## Storage Compaction Status

**No major new storage compaction features were added in PostgreSQL 18.**

Existing storage optimization features (introduced in earlier versions) remain:

1. **Deduplication (PostgreSQL 13+):**
   - Merges duplicate key tuples into posting list format
   - Reduces storage for low-cardinality indexes
   - Source: `src/backend/access/nbtree/nbtdedup.c`

2. **Bottom-Up Index Deletion (PostgreSQL 14+):**
   - Incrementally deletes version churn tuples during normal operations
   - Prevents excessive index bloat in UPDATE-heavy workloads

3. **Suffix Truncation (PostgreSQL 12+):**
   - Truncates non-key suffix columns in pivot tuples
   - Reduces internal page size

---

## Key Source Code References

| File | Purpose |
|------|---------|
| `nbtpreprocesskeys.c:110-195` | Skip array generation logic |
| `nbtcompare.c:115-570` | Skip support functions for various types |
| `nbtree.c:356` | `so->skipScan` flag initialization |
| `nbtvalidate.c:109` | BTSKIPSUPPORT_PROC validation |
| `nbtdedup.c` | Deduplication pass implementation |

---

## Conclusion

PostgreSQL 18's B-tree improvements focus primarily on **query efficiency** (skip scan) rather than storage compaction. The skip scan feature is transformative for multicolumn index usage patterns, potentially eliminating the need for multiple single-column indexes. Storage compaction remains at the PostgreSQL 13-14 level with deduplication and bottom-up deletion.

For workloads seeking more compact B-tree storage, the existing deduplication feature (enabled by default since PG13) remains the primary mechanism.

---

## References

- PostgreSQL 18 Release Notes
- Source: `src/backend/access/nbtree/`
- Peter Geoghegan's skip scan implementation
- CYBERTEC btree_gist improvements blog
