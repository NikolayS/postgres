# Redundant Index Cleanup: A Comprehensive HOWTO Guide

**Author:** PostgreSQL DBA/DBRE Guide
**Last Updated:** December 2024
**Versions:** Generic PostgreSQL | AWS RDS/Aurora | Google Cloud SQL | Supabase

---

## Table of Contents

1. [Introduction](#introduction)
2. [Understanding Redundant Indexes](#understanding-redundant-indexes)
3. [Part I: Generic PostgreSQL](#part-i-generic-postgresql)
4. [Part II: AWS RDS/Aurora PostgreSQL](#part-ii-aws-rdsaurora-postgresql)
5. [Part III: Google Cloud SQL PostgreSQL](#part-iii-google-cloud-sql-postgresql)
6. [Part IV: Supabase](#part-iv-supabase)
7. [Appendix: SQL Queries Reference](#appendix-sql-queries-reference)

---

## Introduction

Redundant indexes are one of the most common performance anti-patterns in PostgreSQL databases. Over time, they accumulate through:

- Developer cargo-culting ("add an index, make it fast")
- ORM-generated migrations that don't check existing indexes
- Schema evolution without cleanup
- Copy-paste from StackOverflow without understanding
- Failed migration rollbacks leaving orphaned indexes

**The cost is real:**
- Each index consumes disk space (often indexes total more than table data)
- Every `INSERT`, `UPDATE`, `DELETE` must maintain all indexes
- Autovacuum must process all indexes, increasing maintenance time
- More indexes = more lock contention possibilities
- Can contribute to XID wraparound emergencies on busy systems

> "It is not unusual for database indexes to use as much storage space as the data themselves."
> — [PostgreSQL Wiki: Index Maintenance](https://wiki.postgresql.org/wiki/Index_Maintenance)

This guide provides a systematic approach to identifying, analyzing, and safely removing redundant indexes with proper Root Cause Analysis (RCA).

---

## Understanding Redundant Indexes

### Types of Redundancy

#### 1. Exact Duplicates
Two or more indexes with identical column definitions:
```sql
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_email_v2 ON users(email);  -- Duplicate!
```

#### 2. Overlapping/Superset Indexes
A composite index makes a single-column index redundant:
```sql
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_orders_customer_date ON orders(customer_id, created_at);
-- The first index is redundant; the second can serve queries on customer_id alone
```

**Critical distinction:** `(a)` is redundant to `(a, b)`, but NOT to `(b, a)`. Column order matters.

#### 3. Functional Overlaps
```sql
CREATE INDEX idx_lower_email ON users(lower(email));
CREATE INDEX idx_email ON users(email);
-- Both may exist legitimately if queries use both patterns
```

### When Indexes Are NOT Redundant (False Positives)

Before dropping, verify the index isn't:

| Scenario | Why It Matters |
|----------|----------------|
| **Primary Key / Unique constraint** | Enforces data integrity, not just query optimization |
| **Foreign Key target** | Required for FK constraint checks on parent table |
| **Different index types** | B-tree vs GIN vs GiST serve different purposes |
| **Partial indexes** | `WHERE active = true` serves different queries |
| **Different operator classes** | `text_pattern_ops` vs default for LIKE queries |
| **Covering indexes** | `INCLUDE` clause provides index-only scans |
| **Required for replication** | Logical replication may need specific indexes |

---

## Part I: Generic PostgreSQL

### Phase 1: Discovery

#### 1.1 Check Statistics Validity

Before trusting usage stats, verify they're meaningful:

```sql
-- When were stats last reset?
SELECT
    datname,
    stats_reset,
    now() - stats_reset AS stats_age
FROM pg_stat_database
WHERE datname = current_database();
```

**Decision point:** If `stats_age` is less than one full business cycle (typically 1-4 weeks), the data may be incomplete. Wait or proceed with caution.

#### 1.2 Find Unused Indexes

```sql
-- PostgreSQL 16+: Use last_idx_scan for precise timing
SELECT
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan,
    last_idx_scan,  -- PG 16+ only
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
    AND indexrelname NOT LIKE 'pg_%'
ORDER BY pg_relation_size(indexrelid) DESC;

-- Pre-PostgreSQL 16: Must rely on idx_scan count
SELECT
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC;
```

#### 1.3 Find Duplicate Indexes

```sql
-- Find exact duplicate indexes
SELECT
    pg_size_pretty(sum(pg_relation_size(idx))::bigint) AS total_size,
    array_agg(idx) AS indexes,
    (array_agg(idx))[1] AS index_to_keep
FROM (
    SELECT
        indexrelid::regclass AS idx,
        indrelid::regclass AS tbl,
        indkey::text || ' ' ||
        coalesce(indexprs::text, '') || ' ' ||
        coalesce(indpred::text, '') AS key
    FROM pg_index
) sub
GROUP BY tbl, key
HAVING count(*) > 1
ORDER BY sum(pg_relation_size(idx)) DESC;
```

#### 1.4 Find Overlapping Indexes

```sql
-- Find indexes where one is a prefix of another
WITH index_info AS (
    SELECT
        indexrelid::regclass AS index_name,
        indrelid::regclass AS table_name,
        indkey::int[] AS columns,
        array_length(indkey, 1) AS num_columns,
        pg_relation_size(indexrelid) AS index_size,
        idx_scan
    FROM pg_index
    JOIN pg_stat_user_indexes USING (indexrelid)
    WHERE indisvalid  -- Only valid indexes
)
SELECT
    i1.table_name,
    i1.index_name AS redundant_index,
    i2.index_name AS covering_index,
    pg_size_pretty(i1.index_size) AS redundant_size,
    i1.idx_scan AS redundant_scans,
    i2.idx_scan AS covering_scans
FROM index_info i1
JOIN index_info i2
    ON i1.table_name = i2.table_name
    AND i1.index_name != i2.index_name
    AND i1.columns[1] = i2.columns[1]  -- Same first column
    AND i1.num_columns < i2.num_columns
    AND i1.columns = i2.columns[1:i1.num_columns]  -- Prefix match
ORDER BY i1.index_size DESC;
```

### Phase 2: Root Cause Analysis (RCA)

#### 2.1 When Logs ARE Available

If you have `log_min_duration_statement` or `auto_explain` enabled:

**Step 1: Search for index usage in query logs**
```bash
# Using pgBadger (recommended)
pgbadger /var/log/postgresql/*.log -o report.html

# Quick grep for specific index
grep -r "Index.*idx_your_index_name" /var/log/postgresql/
zgrep -r "Index.*idx_your_index_name" /var/log/postgresql/*.gz
```

**Step 2: Check pg_stat_statements for query patterns**
```sql
-- Find queries that might use the index (by table/column reference)
SELECT
    query,
    calls,
    mean_exec_time,
    rows
FROM pg_stat_statements
WHERE query ILIKE '%your_table_name%'
    AND query ILIKE '%your_column_name%'
ORDER BY calls DESC
LIMIT 20;
```

**Step 3: Use pg_qualstats if available**

[pg_qualstats](https://github.com/powa-team/pg_qualstats) tracks predicate usage:
```sql
-- See which predicates are actually being filtered
SELECT
    relname,
    attname,
    opno::regoperator,
    eval_type,
    count
FROM pg_qualstats_all
JOIN pg_class ON pg_class.oid = relid
JOIN pg_attribute ON pg_attribute.attrelid = relid
    AND pg_attribute.attnum = attnum
WHERE relname = 'your_table'
ORDER BY count DESC;
```

#### 2.2 When Logs Are NOT Available

This is the more common (and harder) scenario.

**Step 1: Enable monitoring going forward**
```sql
-- Add to postgresql.conf
-- log_min_duration_statement = 1000  -- Log queries > 1 second

-- Or for detailed analysis (higher overhead):
-- shared_preload_libraries = 'auto_explain,pg_stat_statements'
-- auto_explain.log_min_duration = '1s'
```

**Step 2: Use pg_stat_statements current data**
```sql
-- Must be enabled: CREATE EXTENSION pg_stat_statements;
SELECT
    query,
    calls,
    mean_exec_time,
    (shared_blks_hit + shared_blks_read) AS total_blocks
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY mean_exec_time * calls DESC
LIMIT 50;
```

**Step 3: Check application code directly**

Without logs, you must review:
- ORM query patterns (ActiveRecord, SQLAlchemy, Hibernate)
- Raw SQL in application code
- Stored procedures and functions
- Reporting queries (often run during off-hours)
- Background job queries

**Step 4: Consult with development team**
```markdown
## Index RCA Questionnaire for Developers

1. Does any application code query `table_name` filtering by `column_name`?
2. Are there scheduled jobs/reports that run weekly/monthly using this pattern?
3. Is this index part of any data migration or ETL process?
4. Was this index created for a feature that was later removed?
```

### Phase 3: Decision Framework

```
┌─────────────────────────────────────────────────────────────────┐
│                    REDUNDANT INDEX DETECTED                      │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ Is it a PK, UNIQUE constraint, or FK enforcement index?         │
│                                                                  │
│   YES ──► KEEP (document why it appeared redundant)              │
│   NO  ──► Continue                                               │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ Is idx_scan = 0 AND stats_age > 4 weeks?                        │
│                                                                  │
│   YES ──► High confidence: candidate for removal                 │
│   NO  ──► Medium confidence: investigate further                 │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ RCA: Can you confirm no application/job uses this index?        │
│                                                                  │
│   YES (confirmed) ──► PROCEED TO SAFE DROP                       │
│   NO (uncertain)  ──► DOCUMENT AND DEFER                         │
│   PARTIALLY       ──► TEST WITH SOFT DROP                        │
└─────────────────────────────────────────────────────────────────┘
```

### Phase 4: Safe Removal Process

#### 4.1 The "Soft Drop" Technique

Before actually dropping, test the impact using HypoPG:

```sql
-- Install HypoPG (if not present)
CREATE EXTENSION IF NOT EXISTS hypopg;

-- "Hide" the index from the planner
SELECT hypopg_hide_index('idx_suspected_redundant'::regclass::oid);

-- Test critical queries - they should not regress
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM your_table WHERE your_column = 'value';

-- If satisfied, drop for real. If not:
SELECT hypopg_reset();  -- Unhide all
```

**Alternative without HypoPG (non-production only):**
```sql
BEGIN;
DROP INDEX idx_suspected_redundant;
EXPLAIN ANALYZE SELECT ...;  -- Test your queries
ROLLBACK;  -- Don't actually drop
```

#### 4.2 Production Drop Procedure

```sql
-- ALWAYS use CONCURRENTLY to avoid blocking writes
DROP INDEX CONCURRENTLY IF EXISTS schema_name.idx_suspected_redundant;

-- Verify it's gone
SELECT indexname FROM pg_indexes
WHERE indexname = 'idx_suspected_redundant';
```

**Monitoring after drop:**
- Watch `pg_stat_statements` for query time regressions
- Check application error rates
- Monitor `pg_stat_user_tables` for sequential scan increases

#### 4.3 Documentation Template

```markdown
## Index Removal Record

**Index:** `idx_orders_customer_v2`
**Table:** `orders`
**Removed:** 2024-12-30
**Size recovered:** 2.4 GB

### RCA Summary
- Created by migration #1234 on 2023-01-15
- Developer intended for report queries
- Report was deprecated in Q2 2023
- idx_scan = 0 for 11 months
- Confirmed with reporting team: no active usage

### Verification
- HypoPG soft-drop test: passed
- 48-hour canary with hidden index: no regressions
- Dropped with CONCURRENTLY

### Rollback (if needed)
```sql
CREATE INDEX CONCURRENTLY idx_orders_customer_v2
    ON orders(customer_id, order_date);
```
```

### Phase 5: Rollback Plan

Always have a rollback ready:

```sql
-- Save index definitions before dropping
SELECT pg_get_indexdef(indexrelid) AS create_statement
FROM pg_stat_user_indexes
WHERE indexrelname = 'idx_to_be_dropped';

-- Keep this in your runbook/documentation
-- Example output:
-- CREATE INDEX idx_to_be_dropped ON public.orders USING btree (customer_id, created_at)
```

---

## Part II: AWS RDS/Aurora PostgreSQL

### Platform-Specific Considerations

#### Key Differences from Self-Managed PostgreSQL

| Aspect | Impact on Index Cleanup |
|--------|------------------------|
| **No superuser access** | Cannot install all extensions; some monitoring limited |
| **Parameter groups** | Changes require parameter group modification + sometimes reboot |
| **Performance Insights** | Built-in query analysis (note: [EOL June 2026](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.UsingDashboard.AnalyzeDBLoad.AdditionalMetrics.html)) |
| **Enhanced Monitoring** | OS-level metrics available |
| **Blue/Green Deployments** | Safe testing environment for index changes |
| **Aurora storage** | Storage is shared; index bloat has different characteristics |

### Phase 1: Discovery (RDS/Aurora-Specific)

#### 1.1 Enable Required Extensions

```sql
-- These are available in RDS/Aurora
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- HypoPG is available in RDS (check current version)
CREATE EXTENSION IF NOT EXISTS hypopg;

-- pg_qualstats may not be available - check your version
-- Alternative: use Performance Insights
```

#### 1.2 Using Performance Insights

Performance Insights provides query-level analysis without manual setup:

1. **Enable Performance Insights** in RDS Console → Database → Modify
2. **Access Top SQL**: Console → Performance Insights → Top SQL tab
3. **Analyze by wait events**: Filter for "CPU" and "IO" wait types

> "RDS for PostgreSQL collects SQL statistics only at the digest-level. No statistics are shown at the statement-level."
> — [AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.UsingDashboard.AnalyzeDBLoad.AdditionalMetrics.PostgreSQL.html)

**Parameter group settings for better monitoring:**
```
pg_stat_statements.track = all
track_activity_query_size = 102400
track_io_timing = on
```

#### 1.3 Unused Index Detection

Same queries as generic PostgreSQL work in RDS:

```sql
-- Find unused indexes with size
SELECT
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    pg_size_pretty(pg_relation_size(relid)) AS table_size
FROM pg_stat_user_indexes ui
JOIN pg_index i ON ui.indexrelid = i.indexrelid
WHERE idx_scan = 0
    AND NOT i.indisunique  -- Exclude unique constraints
    AND NOT i.indisprimary -- Exclude PKs
ORDER BY pg_relation_size(indexrelid) DESC;
```

### Phase 2: RCA in RDS/Aurora

#### 2.1 When CloudWatch Logs Are Available

**Enable enhanced logging in parameter group:**
```
log_min_duration_statement = 1000  # Log queries > 1s
log_statement = 'ddl'              # Log all DDL
auto_explain.log_min_duration = 5000  # Log plans for queries > 5s
```

**Analyze with CloudWatch Logs Insights:**
```
# Find queries mentioning specific table/index
fields @timestamp, @message
| filter @message like /your_table_name/
| filter @message like /Index Scan/
| sort @timestamp desc
| limit 100
```

**Export to S3 for pgBadger analysis:**
```bash
aws rds download-db-log-file-portion \
    --db-instance-identifier your-instance \
    --log-file-name error/postgresql.log.2024-12-30-00 \
    --output text > pg.log

pgbadger pg.log -o report.html
```

#### 2.2 When Logs Are Not Available

**Use Performance Insights API:**
```bash
aws pi get-resource-metrics \
    --service-type RDS \
    --identifier db-XXXXX \
    --start-time 2024-12-23T00:00:00Z \
    --end-time 2024-12-30T00:00:00Z \
    --metric-queries '[{"Metric": "db.sql_tokenized.stats.calls_per_sec.avg"}]'
```

**Query pg_stat_statements directly:**
```sql
SELECT
    left(query, 100) AS query_preview,
    calls,
    round(mean_exec_time::numeric, 2) AS avg_ms,
    round((100 * shared_blks_hit /
           nullif(shared_blks_hit + shared_blks_read, 0))::numeric, 2) AS hit_ratio
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY mean_exec_time * calls DESC
LIMIT 30;
```

### Phase 3: Safe Removal in RDS/Aurora

#### 3.1 Using Blue/Green Deployments (Recommended for Critical Indexes)

[AWS Blue/Green Deployments](https://aws.amazon.com/blogs/database/perform-maintenance-tasks-and-schema-modifications-in-amazon-rds-for-postgresql-with-minimal-downtime/) provide safe testing:

1. Create Blue/Green deployment
2. Drop index in Green environment
3. Run application tests against Green
4. Monitor for 24-48 hours
5. If successful, switchover

```bash
# Create Blue/Green deployment
aws rds create-blue-green-deployment \
    --blue-green-deployment-name index-cleanup-test \
    --source arn:aws:rds:region:account:db:production-db
```

#### 3.2 Direct Drop (Lower Risk Indexes)

```sql
-- In RDS, CONCURRENTLY still works and is recommended
DROP INDEX CONCURRENTLY IF EXISTS idx_redundant_index;
```

**Aurora-specific consideration:**
```sql
-- Aurora's shared storage means index operations may be faster
-- but always use CONCURRENTLY on production
```

### Phase 4: Monitoring After Removal

**CloudWatch metrics to watch:**
- `ReadLatency` / `WriteLatency`
- `CPUUtilization`
- `DatabaseConnections`
- `DiskQueueDepth`

**Set up alarms:**
```bash
aws cloudwatch put-metric-alarm \
    --alarm-name "PostIndexDropLatencySpike" \
    --metric-name ReadLatency \
    --namespace AWS/RDS \
    --statistic Average \
    --period 300 \
    --threshold 0.1 \
    --comparison-operator GreaterThanThreshold \
    --evaluation-periods 2
```

### RDS/Aurora-Specific Gotchas

1. **Autovacuum and large indexes:**
   > "Before the table is cleaned up, all of its indexes are first vacuumed. When removing multiple large indexes, this phase consumes a significant amount of time."
   > — [AWS Autovacuum Guide](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Appendix.PostgreSQL.CommonDBATasks.Autovacuum.LargeIndexes.html)

2. **XID wraparound risk:** Dropping unused indexes can help autovacuum complete faster, reducing wraparound risk.

3. **Storage reclamation:** In Aurora, storage is managed differently. Freed space may not immediately reduce costs.

---

## Part III: Google Cloud SQL PostgreSQL

### Platform-Specific Considerations

| Aspect | Impact on Index Cleanup |
|--------|------------------------|
| **Cloud SQL Index Advisor** | Recommends NEW indexes only, not redundant detection |
| **No superuser** | Limited extension availability |
| **Enterprise Plus edition** | Required for Index Advisor features |
| **Cloud Logging** | Query logs available via Cloud Logging |
| **Query Insights** | Built-in slow query analysis |

### Phase 1: Discovery (Cloud SQL-Specific)

#### 1.1 Enable Required Extensions

```sql
-- Standard PostgreSQL extensions work
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Check HypoPG availability (may vary by version)
CREATE EXTENSION IF NOT EXISTS hypopg;
```

#### 1.2 Using Query Insights

1. **Enable Query Insights** in Cloud Console → SQL → Instance → Edit → Query Insights
2. **View slow queries** in the Query Insights dashboard
3. **Analyze by tag**: Add application-specific tags for filtering

**Configuration via gcloud:**
```bash
gcloud sql instances patch your-instance \
    --insights-config-query-insights-enabled \
    --insights-config-query-string-length=4500 \
    --insights-config-record-application-tags
```

#### 1.3 Index Advisor (for Context)

> "The index advisor provides CREATE INDEX recommendations only. This means it does not currently identify redundant or unused indexes that could be removed."
> — [Google Cloud Documentation](https://cloud.google.com/sql/docs/postgres/use-index-advisor)

Use Index Advisor output to INFORM your redundancy analysis:
```sql
-- Enterprise Plus only
SELECT * FROM google_db_advisor_recommend_indexes();

-- If advisor recommends an index similar to an existing one,
-- investigate if the existing index is misconfigured
```

### Phase 2: RCA in Cloud SQL

#### 2.1 When Cloud Logging Is Enabled

**Enable logging flags:**
```bash
gcloud sql instances patch your-instance \
    --database-flags=log_min_duration_statement=1000,log_statement=ddl
```

**Query Cloud Logging:**
```
resource.type="cloudsql_database"
resource.labels.database_id="project:region:instance"
textPayload=~"duration:"
```

**Export for analysis:**
```bash
gcloud logging read 'resource.type="cloudsql_database"' \
    --format=json \
    --freshness=7d > query_logs.json
```

#### 2.2 When Logs Are Not Available

Same approach as generic PostgreSQL - rely on:
- `pg_stat_statements`
- `pg_stat_user_indexes`
- Application code review
- Developer consultation

```sql
-- Comprehensive unused index report
WITH index_stats AS (
    SELECT
        schemaname,
        relname AS table_name,
        indexrelname AS index_name,
        idx_scan,
        idx_tup_read,
        pg_relation_size(indexrelid) AS index_size,
        pg_relation_size(relid) AS table_size
    FROM pg_stat_user_indexes
)
SELECT
    schemaname,
    table_name,
    index_name,
    idx_scan,
    pg_size_pretty(index_size) AS index_size,
    round(100.0 * index_size / nullif(table_size, 0), 1) AS pct_of_table
FROM index_stats
WHERE idx_scan = 0
ORDER BY index_size DESC;
```

### Phase 3: Safe Removal in Cloud SQL

#### 3.1 Clone for Testing (Recommended)

```bash
# Create a clone for testing index removal
gcloud sql instances clone your-instance test-clone

# Test on clone
gcloud sql connect test-clone --user=postgres

# If satisfied, apply to production
# Delete clone when done
gcloud sql instances delete test-clone
```

#### 3.2 Production Drop

```sql
-- Same as generic PostgreSQL
DROP INDEX CONCURRENTLY IF EXISTS idx_redundant;
```

### Phase 4: Monitoring After Removal

**Cloud Monitoring metrics:**
- `cloudsql.googleapis.com/database/disk/read_ops_count`
- `cloudsql.googleapis.com/database/disk/write_ops_count`
- `cloudsql.googleapis.com/database/cpu/utilization`

**Set up alerts:**
```bash
gcloud alpha monitoring policies create \
    --notification-channels=your-channel \
    --display-name="Post-Index-Drop CPU Spike" \
    --condition-display-name="CPU > 80%" \
    --condition-filter='resource.type="cloudsql_database" AND metric.type="cloudsql.googleapis.com/database/cpu/utilization"' \
    --condition-threshold-value=0.8
```

### Cloud SQL-Specific Gotchas

1. **Maintenance windows:** Large index operations may need to be scheduled around maintenance windows.

2. **High availability instances:** Index drops replicate to standby; factor in replication lag.

3. **Storage autoresizing:** Freed space may not immediately reduce auto-sized storage.

---

## Part IV: Supabase

### Platform-Specific Considerations

| Aspect | Impact on Index Cleanup |
|--------|------------------------|
| **index_advisor extension** | Available for finding MISSING indexes |
| **hypopg extension** | Available for testing |
| **Direct database access** | Full PostgreSQL access via connection pooler |
| **Dashboard advisors** | Built-in security and performance advisors |
| **Edge Functions** | May have query patterns not visible in standard monitoring |

> "Indexes can significantly speed up reads, sometimes boosting performance by 100 times. However, they come with a trade-off: they need to track all column changes, which can slow down data-modifying queries."
> — [Supabase Documentation](https://supabase.com/docs/guides/database/postgres/indexes)

### Phase 1: Discovery (Supabase-Specific)

#### 1.1 Enable Extensions

```sql
-- index_advisor for finding missing indexes (informational)
CREATE EXTENSION IF NOT EXISTS index_advisor;

-- hypopg for testing index removal
CREATE EXTENSION IF NOT EXISTS hypopg;

-- pg_stat_statements (usually pre-enabled)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

#### 1.2 Using Supabase Dashboard Advisors

The [Supabase Database Advisors](https://supabase.com/docs/guides/database/database-advisors) include:
- Security advisor (RLS policies, exposed schemas)
- Performance advisor (table stats, index suggestions)

Access via: Dashboard → Database → Advisors

#### 1.3 Index Usage Analysis

```sql
-- Supabase-specific: Include auth and storage schemas
SELECT
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
    AND schemaname NOT IN ('pg_catalog', 'information_schema')
    -- Include your app schema + Supabase internal
    -- AND schemaname IN ('public', 'auth', 'storage')
ORDER BY pg_relation_size(indexrelid) DESC;
```

### Phase 2: RCA in Supabase

#### 2.1 Using Supabase Logs

**Dashboard access:** Dashboard → Logs → Postgres Logs

**Filter for slow queries:**
```sql
-- In Supabase Log Explorer
SELECT * FROM postgres_logs
WHERE parsed.duration_ms > 1000
ORDER BY timestamp DESC
LIMIT 100;
```

#### 2.2 pg_stat_statements Analysis

```sql
-- Top queries by total time
SELECT
    substring(query, 1, 80) AS query_preview,
    calls,
    round(total_exec_time::numeric, 2) AS total_ms,
    round(mean_exec_time::numeric, 2) AS avg_ms,
    rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

#### 2.3 Edge Function and Realtime Considerations

Supabase has additional query sources beyond direct app queries:
- **Edge Functions:** May generate database queries
- **Realtime subscriptions:** Generate listening patterns
- **Storage triggers:** May use indexes for file metadata
- **Auth system:** Queries against auth schema

```sql
-- Check if index is used by auth/storage/realtime
SELECT
    indexrelname,
    schemaname,
    relname
FROM pg_stat_user_indexes
WHERE schemaname IN ('auth', 'storage', 'realtime')
    AND idx_scan > 0;
```

### Phase 3: Decision Framework for Supabase

```
┌─────────────────────────────────────────────────────────────────┐
│ Is the index in auth/storage/realtime schema?                   │
│                                                                  │
│   YES ──► CAUTION: These are Supabase internals                 │
│           Do not modify without Supabase support guidance        │
│   NO  ──► Continue to standard analysis                          │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ Is idx_scan = 0 AND logs show no recent usage?                  │
│                                                                  │
│   YES ──► Candidate for soft-drop testing                        │
│   NO  ──► Investigate Edge Functions and Realtime usage          │
└─────────────────────────────────────────────────────────────────┘
```

### Phase 4: Safe Removal in Supabase

#### 4.1 Soft Drop Testing with HypoPG

```sql
-- Test hiding the index
SELECT hypopg_hide_index('your_index'::regclass::oid);

-- Run your application tests
-- Check Edge Function logs for errors
-- Monitor Realtime connection health

-- If safe, proceed with actual drop
SELECT hypopg_reset();
```

#### 4.2 Production Drop

```sql
-- Use CONCURRENTLY to avoid blocking
DROP INDEX CONCURRENTLY IF EXISTS public.idx_redundant;
```

> "It can take a long time to build indexes on large datasets and the default behaviour of create index is to lock the table from writes. Luckily Postgres provides us with create index concurrently which prevents blocking writes."
> — [Supabase Documentation](https://supabase.com/docs/guides/database/postgres/indexes)

The same logic applies to dropping indexes.

### Phase 5: Monitoring After Removal

**Supabase Dashboard:**
- Monitor Database → Health for latency changes
- Check Logs → Postgres for error spikes
- Review API → Logs for increased latency

**SQL monitoring:**
```sql
-- Watch for sequential scan increases
SELECT
    schemaname,
    relname,
    seq_scan,
    idx_scan,
    round(100.0 * idx_scan / nullif(seq_scan + idx_scan, 0), 1) AS idx_ratio
FROM pg_stat_user_tables
WHERE (seq_scan + idx_scan) > 100
ORDER BY seq_scan DESC;
```

### Supabase-Specific Gotchas

1. **Foreign keys in public schema:** Many apps use FK relationships that benefit from indexes
   ```sql
   -- Find FKs that might need their indexes
   SELECT
       tc.table_name,
       kcu.column_name,
       ccu.table_name AS foreign_table_name
   FROM information_schema.table_constraints tc
   JOIN information_schema.key_column_usage kcu
       ON tc.constraint_name = kcu.constraint_name
   JOIN information_schema.constraint_column_usage ccu
       ON ccu.constraint_name = tc.constraint_name
   WHERE tc.constraint_type = 'FOREIGN KEY';
   ```

2. **RLS policies:** Row Level Security policies may require specific indexes for performance
   ```sql
   -- Check RLS policies on tables with unused indexes
   SELECT tablename, policyname, qual, with_check
   FROM pg_policies
   WHERE tablename = 'your_table';
   ```

3. **PostgREST query patterns:** API queries may use different patterns than direct SQL

---

## Appendix: SQL Queries Reference

### A.1 Comprehensive Unused Index Query

```sql
WITH index_data AS (
    SELECT
        s.schemaname,
        s.relname AS table_name,
        s.indexrelname AS index_name,
        s.idx_scan,
        s.idx_tup_read,
        s.idx_tup_fetch,
        pg_relation_size(s.indexrelid) AS index_bytes,
        pg_relation_size(s.relid) AS table_bytes,
        i.indisunique,
        i.indisprimary,
        pg_get_indexdef(s.indexrelid) AS index_def
    FROM pg_stat_user_indexes s
    JOIN pg_index i ON s.indexrelid = i.indexrelid
)
SELECT
    schemaname,
    table_name,
    index_name,
    idx_scan AS times_used,
    pg_size_pretty(index_bytes) AS index_size,
    pg_size_pretty(table_bytes) AS table_size,
    round(100.0 * index_bytes / nullif(table_bytes, 0), 1) AS idx_pct_of_table,
    CASE
        WHEN indisprimary THEN 'PRIMARY KEY'
        WHEN indisunique THEN 'UNIQUE'
        ELSE 'REGULAR'
    END AS index_type,
    index_def
FROM index_data
WHERE idx_scan = 0
    AND NOT indisprimary
    AND NOT indisunique
ORDER BY index_bytes DESC;
```

### A.2 Find Overlapping Indexes (Detailed)

```sql
WITH index_cols AS (
    SELECT
        i.indexrelid,
        i.indrelid,
        i.indrelid::regclass AS table_name,
        i.indexrelid::regclass AS index_name,
        array_agg(a.attname ORDER BY array_position(i.indkey, a.attnum)) AS columns,
        pg_get_indexdef(i.indexrelid) AS index_def,
        pg_relation_size(i.indexrelid) AS index_size,
        s.idx_scan
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
    JOIN pg_stat_user_indexes s ON s.indexrelid = i.indexrelid
    WHERE i.indisvalid
    GROUP BY i.indexrelid, i.indrelid, s.idx_scan
)
SELECT
    i1.table_name,
    i1.index_name AS potentially_redundant,
    i2.index_name AS covered_by,
    i1.columns AS redundant_columns,
    i2.columns AS covering_columns,
    pg_size_pretty(i1.index_size) AS redundant_size,
    i1.idx_scan AS redundant_usage,
    i2.idx_scan AS covering_usage
FROM index_cols i1
JOIN index_cols i2 ON i1.indrelid = i2.indrelid
    AND i1.indexrelid != i2.indexrelid
    AND i1.columns[1] = i2.columns[1]
    AND array_length(i1.columns, 1) < array_length(i2.columns, 1)
WHERE i1.columns = (i2.columns)[1:array_length(i1.columns, 1)]
ORDER BY i1.index_size DESC;
```

### A.3 Index Size Summary by Table

```sql
SELECT
    schemaname,
    relname AS table_name,
    pg_size_pretty(pg_relation_size(relid)) AS table_size,
    pg_size_pretty(pg_indexes_size(relid)) AS total_index_size,
    round(100.0 * pg_indexes_size(relid) /
          nullif(pg_relation_size(relid), 0), 1) AS indexes_pct,
    (SELECT count(*) FROM pg_index WHERE indrelid = relid) AS num_indexes,
    (SELECT count(*) FROM pg_stat_user_indexes ui
     WHERE ui.relid = t.relid AND idx_scan = 0) AS unused_indexes
FROM pg_stat_user_tables t
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_indexes_size(relid) DESC
LIMIT 30;
```

### A.4 Generate Drop Statements with Rollback

```sql
SELECT
    format('-- Drop redundant index (%s scans, %s)',
           idx_scan, pg_size_pretty(pg_relation_size(indexrelid))) AS comment,
    format('DROP INDEX CONCURRENTLY IF EXISTS %I.%I;',
           schemaname, indexrelname) AS drop_cmd,
    format('-- Rollback: %s', pg_get_indexdef(indexrelid)) AS rollback_cmd
FROM pg_stat_user_indexes
WHERE idx_scan = 0
    AND indexrelname NOT LIKE 'pg_%'
ORDER BY pg_relation_size(indexrelid) DESC;
```

### A.5 Check Foreign Key Index Coverage

```sql
WITH fk_columns AS (
    SELECT
        tc.table_schema,
        tc.table_name,
        kcu.column_name,
        ccu.table_name AS referenced_table
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
        ON tc.constraint_name = kcu.constraint_name
        AND tc.table_schema = kcu.table_schema
    JOIN information_schema.constraint_column_usage ccu
        ON ccu.constraint_name = tc.constraint_name
    WHERE tc.constraint_type = 'FOREIGN KEY'
),
indexed_columns AS (
    SELECT
        schemaname,
        tablename,
        (string_to_array(indkey::text, ' '))[1]::int AS first_col_num
    FROM pg_indexes
    JOIN pg_index ON indexrelid = (schemaname || '.' || indexname)::regclass
)
SELECT
    fk.table_schema,
    fk.table_name,
    fk.column_name,
    fk.referenced_table,
    CASE
        WHEN EXISTS (
            SELECT 1 FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid
                AND a.attnum = i.indkey[0]
            WHERE i.indrelid = (fk.table_schema || '.' || fk.table_name)::regclass
                AND a.attname = fk.column_name
        ) THEN 'INDEXED'
        ELSE 'NO INDEX - Consider adding'
    END AS index_status
FROM fk_columns fk
ORDER BY table_schema, table_name;
```

---

## Quick Reference: Decision Cheat Sheet

| Situation | Action |
|-----------|--------|
| idx_scan = 0, stats > 30 days, RCA confirms no usage | **DROP** |
| idx_scan = 0, stats < 7 days | **WAIT** for more data |
| idx_scan = 0, but enforces UNIQUE/PK | **KEEP** (document) |
| idx_scan low, but it's only index on FK column | **KEEP** (needed for FK checks) |
| Overlapping: `(a)` exists with `(a,b)` | **DROP** `(a)` if queries on `a` alone are rare |
| Overlapping: both indexes heavily used | **INVESTIGATE** query patterns first |
| No logs, no pg_stat_statements | **ENABLE** monitoring, wait 2-4 weeks |
| Can't reach developers, uncertain usage | **SOFT DROP** test with HypoPG |
| Index is huge (>10GB), want to be safe | **Blue/Green** deploy or clone-test first |

---

## References

1. PostgreSQL Documentation: [Indexes](https://www.postgresql.org/docs/current/indexes.html)
2. PostgreSQL Wiki: [Index Maintenance](https://wiki.postgresql.org/wiki/Index_Maintenance)
3. CYBERTEC: [Get Rid of Your Unused Indexes](https://www.cybertec-postgresql.com/en/get-rid-of-your-unused-indexes/) (2023)
4. PostgresAI: [How to Find Redundant Indexes](https://postgres.ai/docs/postgres-howtos/performance-optimization/indexing/how-to-find-redundent-indexes)
5. Percona: [Useful PostgreSQL Index Maintenance Queries](https://www.percona.com/blog/useful-queries-for-postgresql-index-maintenance/) (2023)
6. AWS: [PostgreSQL Maintenance for RDS/Aurora](https://docs.aws.amazon.com/prescriptive-guidance/latest/postgresql-maintenance-rds-aurora/introduction.html)
7. AWS: [Blue/Green Deployments](https://aws.amazon.com/blogs/database/perform-maintenance-tasks-and-schema-modifications-in-amazon-rds-for-postgresql-with-minimal-downtime/)
8. Google Cloud: [Cloud SQL Index Advisor](https://cloud.google.com/sql/docs/postgres/use-index-advisor)
9. Supabase: [Managing Indexes in PostgreSQL](https://supabase.com/docs/guides/database/postgres/indexes)
10. HypoPG: [Documentation](https://hypopg.readthedocs.io/en/rel1_stable/)
11. pg_qualstats: [GitHub Repository](https://github.com/powa-team/pg_qualstats)
12. Crunchy Data: [Query Optimization with pg_stat_statements](https://www.crunchydata.com/blog/tentative-smarter-query-optimization-in-postgres-starts-with-pg_stat_statements) (2024)
13. AWS: [Performance Insights for PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.UsingDashboard.AnalyzeDBLoad.AdditionalMetrics.PostgreSQL.html)

---

*This guide is a living document. Index management practices evolve with PostgreSQL versions and cloud platform features. Always test in non-production environments first.*
