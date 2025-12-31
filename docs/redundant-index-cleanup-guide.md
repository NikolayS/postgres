# Redundant index cleanup: a comprehensive HOWTO guide

**Author:** PostgreSQL DBA/DBRE guide
**Last updated:** December 2024
**Versions:** Generic PostgreSQL | AWS RDS/Aurora | Google Cloud SQL | Supabase

---

## Table of contents

1. [Introduction](#introduction)
2. [Understanding redundant indexes](#understanding-redundant-indexes)
3. [Part I: Generic PostgreSQL](#part-i-generic-postgresql)
4. [Part II: AWS RDS/Aurora PostgreSQL](#part-ii-aws-rdsaurora-postgresql)
5. [Part III: Google Cloud SQL PostgreSQL](#part-iii-google-cloud-sql-postgresql)
6. [Part IV: Supabase](#part-iv-supabase)
7. [Appendix: SQL queries reference](#appendix-sql-queries-reference)

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
- Every `insert`, `update`, `delete` must maintain all indexes
- Autovacuum must process all indexes, increasing maintenance time
- More indexes = more lock contention possibilities
- Can contribute to XID wraparound emergencies on busy systems

> "It is not unusual for database indexes to use as much storage space as the data themselves."
> — [PostgreSQL Wiki: Index Maintenance](https://wiki.postgresql.org/wiki/Index_Maintenance)

This guide provides a systematic approach to identifying, analyzing, and safely removing redundant indexes with proper root cause analysis (RCA).

---

## Understanding redundant indexes

### Types of redundancy

#### 1. Exact duplicates

Two or more indexes with identical column definitions:

```sql
create index idx_users_email on users(email);
create index idx_users_email_v2 on users(email);  -- Duplicate!
```

#### 2. Overlapping/superset indexes

A composite index makes a single-column index redundant:

```sql
create index idx_orders_customer on orders(customer_id);
create index idx_orders_customer_date on orders(customer_id, created_at);
-- The first index is redundant; the second can serve queries on customer_id alone
```

**Critical distinction:** `(a)` is redundant to `(a, b)`, but NOT to `(b, a)`. Column order matters.

#### 3. Functional overlaps

```sql
create index idx_lower_email on users(lower(email));
create index idx_email on users(email);
-- Both may exist legitimately if queries use both patterns
```

### When indexes are NOT redundant (false positives)

Before dropping, verify the index isn't:

| Scenario | Why it matters |
|----------|----------------|
| **Primary key / unique constraint** | Enforces data integrity, not just query optimization |
| **Foreign key target** | Required for FK constraint checks on parent table |
| **Different index types** | B-tree vs GIN vs GiST serve different purposes |
| **Partial indexes** | `where active = true` serves different queries |
| **Different operator classes** | `text_pattern_ops` vs default for `like` queries |
| **Covering indexes** | `include` clause provides index-only scans |
| **Required for replication** | Logical replication may need specific indexes |

---

## Part I: Generic PostgreSQL

### Phase 1: Discovery

#### 1.1 Check statistics validity

Before trusting usage stats, verify they're meaningful:

```sql
-- When were stats last reset?
select
    datname,
    stats_reset,
    now() - stats_reset as stats_age
from pg_stat_database
where datname = current_database();
```

**Decision point:** If `stats_age` is less than one full business cycle (typically 1-4 weeks), the data may be incomplete. Wait or proceed with caution.

#### 1.2 Find unused indexes

```sql
-- PostgreSQL 16+: use last_idx_scan for precise timing
select
    schemaname,
    relname as table_name,
    indexrelname as index_name,
    idx_scan,
    last_idx_scan,  -- PG 16+ only
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
from pg_stat_user_indexes
where
    idx_scan = 0
    and indexrelname not like 'pg_%'
order by pg_relation_size(indexrelid) desc;

-- Pre-PostgreSQL 16: must rely on idx_scan count
select
    schemaname,
    relname as table_name,
    indexrelname as index_name,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
from pg_stat_user_indexes
where idx_scan = 0
order by pg_relation_size(indexrelid) desc;
```

#### 1.3 Find duplicate indexes

```sql
-- Find exact duplicate indexes
select
    pg_size_pretty(sum(pg_relation_size(idx))::bigint) as total_size,
    array_agg(idx) as indexes,
    (array_agg(idx))[1] as index_to_keep
from (
    select
        indexrelid::regclass as idx,
        indrelid::regclass as tbl,
        indkey::text || ' ' ||
        coalesce(indexprs::text, '') || ' ' ||
        coalesce(indpred::text, '') as key
    from pg_index
) sub
group by tbl, key
having count(*) > 1
order by sum(pg_relation_size(idx)) desc;
```

#### 1.4 Find overlapping indexes

```sql
-- Find indexes where one is a prefix of another
with index_info as (
    select
        indexrelid::regclass as index_name,
        indrelid::regclass as table_name,
        indkey::int[] as columns,
        array_length(indkey, 1) as num_columns,
        pg_relation_size(indexrelid) as index_size,
        idx_scan
    from pg_index
    join pg_stat_user_indexes using (indexrelid)
    where indisvalid  -- Only valid indexes
)
select
    i1.table_name,
    i1.index_name as redundant_index,
    i2.index_name as covering_index,
    pg_size_pretty(i1.index_size) as redundant_size,
    i1.idx_scan as redundant_scans,
    i2.idx_scan as covering_scans
from index_info as i1
join index_info as i2
    on i1.table_name = i2.table_name
    and i1.index_name != i2.index_name
    and i1.columns[1] = i2.columns[1]  -- Same first column
    and i1.num_columns < i2.num_columns
    and i1.columns = i2.columns[1:i1.num_columns]  -- Prefix match
order by i1.index_size desc;
```

### Phase 2: Root cause analysis (RCA)

#### 2.1 When logs ARE available

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
select
    query,
    calls,
    mean_exec_time,
    rows
from pg_stat_statements
where
    query ilike '%your_table_name%'
    and query ilike '%your_column_name%'
order by calls desc
limit 20;
```

**Step 3: Use pg_qualstats if available**

[pg_qualstats](https://github.com/powa-team/pg_qualstats) tracks predicate usage:

```sql
-- See which predicates are actually being filtered
select
    relname,
    attname,
    opno::regoperator,
    eval_type,
    count
from pg_qualstats_all
join pg_class on pg_class.oid = relid
join pg_attribute
    on pg_attribute.attrelid = relid
    and pg_attribute.attnum = attnum
where relname = 'your_table'
order by count desc;
```

#### 2.2 When logs are NOT available

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
-- Must be enabled: create extension pg_stat_statements;
select
    query,
    calls,
    mean_exec_time,
    (shared_blks_hit + shared_blks_read) as total_blocks
from pg_stat_statements
where dbid = (
    select oid
    from pg_database
    where datname = current_database()
)
order by mean_exec_time * calls desc
limit 50;
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
## Index RCA questionnaire for developers

1. Does any application code query `table_name` filtering by `column_name`?
2. Are there scheduled jobs/reports that run weekly/monthly using this pattern?
3. Is this index part of any data migration or ETL process?
4. Was this index created for a feature that was later removed?
```

### Phase 3: Decision framework

```
┌─────────────────────────────────────────────────────────────────┐
│                    REDUNDANT INDEX DETECTED                      │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ Is it a PK, unique constraint, or FK enforcement index?         │
│                                                                  │
│   YES ──► KEEP (document why it appeared redundant)              │
│   NO  ──► Continue                                               │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ Is idx_scan = 0 and stats_age > 4 weeks?                        │
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

### Phase 4: Safe removal process

#### 4.1 The "soft drop" technique

Before actually dropping, test the impact using HypoPG:

```sql
-- Install HypoPG (if not present)
create extension if not exists hypopg;

-- "Hide" the index from the planner
select hypopg_hide_index('idx_suspected_redundant'::regclass::oid);

-- Test critical queries - they should not regress
explain (analyze, buffers)
select *
from your_table
where your_column = 'value';

-- If satisfied, drop for real. If not:
select hypopg_reset();  -- Unhide all
```

**Alternative without HypoPG (non-production only):**

```sql
begin;
drop index idx_suspected_redundant;
explain analyze select ...;  -- Test your queries
rollback;  -- Don't actually drop
```

#### 4.2 Production drop procedure

```sql
-- ALWAYS use concurrently to avoid blocking writes
drop index concurrently if exists schema_name.idx_suspected_redundant;

-- Verify it's gone
select indexname
from pg_indexes
where indexname = 'idx_suspected_redundant';
```

**Monitoring after drop:**
- Watch `pg_stat_statements` for query time regressions
- Check application error rates
- Monitor `pg_stat_user_tables` for sequential scan increases

#### 4.3 Documentation template

```markdown
## Index removal record

**Index:** `idx_orders_customer_v2`
**Table:** `orders`
**Removed:** 2024-12-30
**Size recovered:** 2.4 GB

### RCA summary
- Created by migration #1234 on 2023-01-15
- Developer intended for report queries
- Report was deprecated in Q2 2023
- idx_scan = 0 for 11 months
- Confirmed with reporting team: no active usage

### Verification
- HypoPG soft-drop test: passed
- 48-hour canary with hidden index: no regressions
- Dropped with concurrently

### Rollback (if needed)
```sql
create index concurrently idx_orders_customer_v2
    on orders(customer_id, order_date);
```
```

### Phase 5: Rollback plan

Always have a rollback ready:

```sql
-- Save index definitions before dropping
select pg_get_indexdef(indexrelid) as create_statement
from pg_stat_user_indexes
where indexrelname = 'idx_to_be_dropped';

-- Keep this in your runbook/documentation
-- Example output:
-- create index idx_to_be_dropped on public.orders using btree (customer_id, created_at)
```

---

## Part II: AWS RDS/Aurora PostgreSQL

### Platform-specific considerations

#### Key differences from self-managed PostgreSQL

| Aspect | Impact on index cleanup |
|--------|------------------------|
| **No superuser access** | Cannot install all extensions; some monitoring limited |
| **Parameter groups** | Changes require parameter group modification + sometimes reboot |
| **Performance Insights** | Built-in query analysis (note: [EOL June 2026](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.UsingDashboard.AnalyzeDBLoad.AdditionalMetrics.html)) |
| **Enhanced Monitoring** | OS-level metrics available |
| **Blue/Green deployments** | Safe testing environment for index changes |
| **Aurora storage** | Storage is shared; index bloat has different characteristics |

### Phase 1: Discovery (RDS/Aurora-specific)

#### 1.1 Enable required extensions

```sql
-- These are available in RDS/Aurora
create extension if not exists pg_stat_statements;

-- HypoPG is available in RDS (check current version)
create extension if not exists hypopg;

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

#### 1.3 Unused index detection

Same queries as generic PostgreSQL work in RDS:

```sql
-- Find unused indexes with size
select
    schemaname,
    relname as table_name,
    indexrelname as index_name,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
    pg_size_pretty(pg_relation_size(relid)) as table_size
from pg_stat_user_indexes as ui
join pg_index as i on ui.indexrelid = i.indexrelid
where
    idx_scan = 0
    and not i.indisunique  -- Exclude unique constraints
    and not i.indisprimary -- Exclude PKs
order by pg_relation_size(indexrelid) desc;
```

### Phase 2: RCA in RDS/Aurora

#### 2.1 When CloudWatch logs are available

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

#### 2.2 When logs are not available

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
select
    left(query, 100) as query_preview,
    calls,
    round(mean_exec_time::numeric, 2) as avg_ms,
    round(
        (100 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0))::numeric,
        2
    ) as hit_ratio
from pg_stat_statements
where dbid = (
    select oid
    from pg_database
    where datname = current_database()
)
order by mean_exec_time * calls desc
limit 30;
```

### Phase 3: Safe removal in RDS/Aurora

#### 3.1 Using Blue/Green deployments (recommended for critical indexes)

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

#### 3.2 Direct drop (lower risk indexes)

```sql
-- In RDS, concurrently still works and is recommended
drop index concurrently if exists idx_redundant_index;
```

**Aurora-specific consideration:**

```sql
-- Aurora's shared storage means index operations may be faster
-- but always use concurrently on production
```

### Phase 4: Monitoring after removal

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

### RDS/Aurora-specific gotchas

1. **Autovacuum and large indexes:**
   > "Before the table is cleaned up, all of its indexes are first vacuumed. When removing multiple large indexes, this phase consumes a significant amount of time."
   > — [AWS Autovacuum Guide](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Appendix.PostgreSQL.CommonDBATasks.Autovacuum.LargeIndexes.html)

2. **XID wraparound risk:** Dropping unused indexes can help autovacuum complete faster, reducing wraparound risk.

3. **Storage reclamation:** In Aurora, storage is managed differently. Freed space may not immediately reduce costs.

---

## Part III: Google Cloud SQL PostgreSQL

### Platform-specific considerations

| Aspect | Impact on index cleanup |
|--------|------------------------|
| **Cloud SQL Index Advisor** | Recommends NEW indexes only, not redundant detection |
| **No superuser** | Limited extension availability |
| **Enterprise Plus edition** | Required for Index Advisor features |
| **Cloud Logging** | Query logs available via Cloud Logging |
| **Query Insights** | Built-in slow query analysis |

### Phase 1: Discovery (Cloud SQL-specific)

#### 1.1 Enable required extensions

```sql
-- Standard PostgreSQL extensions work
create extension if not exists pg_stat_statements;

-- Check HypoPG availability (may vary by version)
create extension if not exists hypopg;
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

#### 1.3 Index Advisor (for context)

> "The index advisor provides CREATE INDEX recommendations only. This means it does not currently identify redundant or unused indexes that could be removed."
> — [Google Cloud Documentation](https://cloud.google.com/sql/docs/postgres/use-index-advisor)

Use Index Advisor output to INFORM your redundancy analysis:

```sql
-- Enterprise Plus only
select * from google_db_advisor_recommend_indexes();

-- If advisor recommends an index similar to an existing one,
-- investigate if the existing index is misconfigured
```

### Phase 2: RCA in Cloud SQL

#### 2.1 When Cloud Logging is enabled

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

#### 2.2 When logs are not available

Same approach as generic PostgreSQL - rely on:
- `pg_stat_statements`
- `pg_stat_user_indexes`
- Application code review
- Developer consultation

```sql
-- Comprehensive unused index report
with index_stats as (
    select
        schemaname,
        relname as table_name,
        indexrelname as index_name,
        idx_scan,
        idx_tup_read,
        pg_relation_size(indexrelid) as index_size,
        pg_relation_size(relid) as table_size
    from pg_stat_user_indexes
)
select
    schemaname,
    table_name,
    index_name,
    idx_scan,
    pg_size_pretty(index_size) as index_size,
    round(100.0 * index_size / nullif(table_size, 0), 1) as pct_of_table
from index_stats
where idx_scan = 0
order by index_size desc;
```

### Phase 3: Safe removal in Cloud SQL

#### 3.1 Clone for testing (recommended)

```bash
# Create a clone for testing index removal
gcloud sql instances clone your-instance test-clone

# Test on clone
gcloud sql connect test-clone --user=postgres

# If satisfied, apply to production
# Delete clone when done
gcloud sql instances delete test-clone
```

#### 3.2 Production drop

```sql
-- Same as generic PostgreSQL
drop index concurrently if exists idx_redundant;
```

### Phase 4: Monitoring after removal

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

### Cloud SQL-specific gotchas

1. **Maintenance windows:** Large index operations may need to be scheduled around maintenance windows.

2. **High availability instances:** Index drops replicate to standby; factor in replication lag.

3. **Storage autoresizing:** Freed space may not immediately reduce auto-sized storage.

---

## Part IV: Supabase

### Platform-specific considerations

| Aspect | Impact on index cleanup |
|--------|------------------------|
| **index_advisor extension** | Available for finding MISSING indexes |
| **hypopg extension** | Available for testing |
| **Direct database access** | Full PostgreSQL access via connection pooler |
| **Dashboard advisors** | Built-in security and performance advisors |
| **Edge Functions** | May have query patterns not visible in standard monitoring |

> "Indexes can significantly speed up reads, sometimes boosting performance by 100 times. However, they come with a trade-off: they need to track all column changes, which can slow down data-modifying queries."
> — [Supabase Documentation](https://supabase.com/docs/guides/database/postgres/indexes)

### Phase 1: Discovery (Supabase-specific)

#### 1.1 Enable extensions

```sql
-- index_advisor for finding missing indexes (informational)
create extension if not exists index_advisor;

-- hypopg for testing index removal
create extension if not exists hypopg;

-- pg_stat_statements (usually pre-enabled)
create extension if not exists pg_stat_statements;
```

#### 1.2 Using Supabase Dashboard advisors

The [Supabase Database Advisors](https://supabase.com/docs/guides/database/database-advisors) include:
- Security advisor (RLS policies, exposed schemas)
- Performance advisor (table stats, index suggestions)

Access via: Dashboard → Database → Advisors

#### 1.3 Index usage analysis

```sql
-- Supabase-specific: include auth and storage schemas
select
    schemaname,
    relname as table_name,
    indexrelname as index_name,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
from pg_stat_user_indexes
where
    idx_scan = 0
    and schemaname not in ('pg_catalog', 'information_schema')
    -- Include your app schema + Supabase internal
    -- and schemaname in ('public', 'auth', 'storage')
order by pg_relation_size(indexrelid) desc;
```

### Phase 2: RCA in Supabase

#### 2.1 Using Supabase logs

**Dashboard access:** Dashboard → Logs → Postgres Logs

**Filter for slow queries:**

```sql
-- In Supabase Log Explorer
select *
from postgres_logs
where parsed.duration_ms > 1000
order by timestamp desc
limit 100;
```

#### 2.2 pg_stat_statements analysis

```sql
-- Top queries by total time
select
    substring(query, 1, 80) as query_preview,
    calls,
    round(total_exec_time::numeric, 2) as total_ms,
    round(mean_exec_time::numeric, 2) as avg_ms,
    rows
from pg_stat_statements
order by total_exec_time desc
limit 20;
```

#### 2.3 Edge Function and Realtime considerations

Supabase has additional query sources beyond direct app queries:
- **Edge Functions:** May generate database queries
- **Realtime subscriptions:** Generate listening patterns
- **Storage triggers:** May use indexes for file metadata
- **Auth system:** Queries against auth schema

```sql
-- Check if index is used by auth/storage/realtime
select
    indexrelname,
    schemaname,
    relname
from pg_stat_user_indexes
where
    schemaname in ('auth', 'storage', 'realtime')
    and idx_scan > 0;
```

### Phase 3: Decision framework for Supabase

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
│ Is idx_scan = 0 and logs show no recent usage?                  │
│                                                                  │
│   YES ──► Candidate for soft-drop testing                        │
│   NO  ──► Investigate Edge Functions and Realtime usage          │
└─────────────────────────────────────────────────────────────────┘
```

### Phase 4: Safe removal in Supabase

#### 4.1 Soft drop testing with HypoPG

```sql
-- Test hiding the index
select hypopg_hide_index('your_index'::regclass::oid);

-- Run your application tests
-- Check Edge Function logs for errors
-- Monitor Realtime connection health

-- If safe, proceed with actual drop
select hypopg_reset();
```

#### 4.2 Production drop

```sql
-- Use concurrently to avoid blocking
drop index concurrently if exists public.idx_redundant;
```

> "It can take a long time to build indexes on large datasets and the default behaviour of create index is to lock the table from writes. Luckily Postgres provides us with create index concurrently which prevents blocking writes."
> — [Supabase Documentation](https://supabase.com/docs/guides/database/postgres/indexes)

The same logic applies to dropping indexes.

### Phase 5: Monitoring after removal

**Supabase Dashboard:**
- Monitor Database → Health for latency changes
- Check Logs → Postgres for error spikes
- Review API → Logs for increased latency

**SQL monitoring:**

```sql
-- Watch for sequential scan increases
select
    schemaname,
    relname,
    seq_scan,
    idx_scan,
    round(100.0 * idx_scan / nullif(seq_scan + idx_scan, 0), 1) as idx_ratio
from pg_stat_user_tables
where (seq_scan + idx_scan) > 100
order by seq_scan desc;
```

### Supabase-specific gotchas

1. **Foreign keys in public schema:** Many apps use FK relationships that benefit from indexes

   ```sql
   -- Find FKs that might need their indexes
   select
       tc.table_name,
       kcu.column_name,
       ccu.table_name as foreign_table_name
   from information_schema.table_constraints as tc
   join information_schema.key_column_usage as kcu
       on tc.constraint_name = kcu.constraint_name
   join information_schema.constraint_column_usage as ccu
       on ccu.constraint_name = tc.constraint_name
   where tc.constraint_type = 'FOREIGN KEY';
   ```

2. **RLS policies:** Row Level Security policies may require specific indexes for performance

   ```sql
   -- Check RLS policies on tables with unused indexes
   select tablename, policyname, qual, with_check
   from pg_policies
   where tablename = 'your_table';
   ```

3. **PostgREST query patterns:** API queries may use different patterns than direct SQL

---

## Appendix: SQL queries reference

### A.1 Comprehensive unused index query

```sql
with index_data as (
    select
        s.schemaname,
        s.relname as table_name,
        s.indexrelname as index_name,
        s.idx_scan,
        s.idx_tup_read,
        s.idx_tup_fetch,
        pg_relation_size(s.indexrelid) as index_bytes,
        pg_relation_size(s.relid) as table_bytes,
        i.indisunique,
        i.indisprimary,
        pg_get_indexdef(s.indexrelid) as index_def
    from pg_stat_user_indexes as s
    join pg_index as i on s.indexrelid = i.indexrelid
)
select
    schemaname,
    table_name,
    index_name,
    idx_scan as times_used,
    pg_size_pretty(index_bytes) as index_size,
    pg_size_pretty(table_bytes) as table_size,
    round(100.0 * index_bytes / nullif(table_bytes, 0), 1) as idx_pct_of_table,
    case
        when indisprimary then 'PRIMARY KEY'
        when indisunique then 'UNIQUE'
        else 'REGULAR'
    end as index_type,
    index_def
from index_data
where
    idx_scan = 0
    and not indisprimary
    and not indisunique
order by index_bytes desc;
```

### A.2 Find overlapping indexes (detailed)

```sql
with index_cols as (
    select
        i.indexrelid,
        i.indrelid,
        i.indrelid::regclass as table_name,
        i.indexrelid::regclass as index_name,
        array_agg(a.attname order by array_position(i.indkey, a.attnum)) as columns,
        pg_get_indexdef(i.indexrelid) as index_def,
        pg_relation_size(i.indexrelid) as index_size,
        s.idx_scan
    from pg_index as i
    join pg_attribute as a
        on a.attrelid = i.indrelid
        and a.attnum = any(i.indkey)
    join pg_stat_user_indexes as s on s.indexrelid = i.indexrelid
    where i.indisvalid
    group by i.indexrelid, i.indrelid, s.idx_scan
)
select
    i1.table_name,
    i1.index_name as potentially_redundant,
    i2.index_name as covered_by,
    i1.columns as redundant_columns,
    i2.columns as covering_columns,
    pg_size_pretty(i1.index_size) as redundant_size,
    i1.idx_scan as redundant_usage,
    i2.idx_scan as covering_usage
from index_cols as i1
join index_cols as i2
    on i1.indrelid = i2.indrelid
    and i1.indexrelid != i2.indexrelid
    and i1.columns[1] = i2.columns[1]
    and array_length(i1.columns, 1) < array_length(i2.columns, 1)
where i1.columns = (i2.columns)[1:array_length(i1.columns, 1)]
order by i1.index_size desc;
```

### A.3 Index size summary by table

```sql
select
    schemaname,
    relname as table_name,
    pg_size_pretty(pg_relation_size(relid)) as table_size,
    pg_size_pretty(pg_indexes_size(relid)) as total_index_size,
    round(
        100.0 * pg_indexes_size(relid) / nullif(pg_relation_size(relid), 0),
        1
    ) as indexes_pct,
    (
        select count(*)
        from pg_index
        where indrelid = relid
    ) as num_indexes,
    (
        select count(*)
        from pg_stat_user_indexes as ui
        where
            ui.relid = t.relid
            and idx_scan = 0
    ) as unused_indexes
from pg_stat_user_tables as t
where schemaname not in ('pg_catalog', 'information_schema')
order by pg_indexes_size(relid) desc
limit 30;
```

### A.4 Generate drop statements with rollback

```sql
select
    format(
        '-- Drop redundant index (%s scans, %s)',
        idx_scan,
        pg_size_pretty(pg_relation_size(indexrelid))
    ) as comment,
    format(
        'drop index concurrently if exists %I.%I;',
        schemaname,
        indexrelname
    ) as drop_cmd,
    format('-- Rollback: %s', pg_get_indexdef(indexrelid)) as rollback_cmd
from pg_stat_user_indexes
where
    idx_scan = 0
    and indexrelname not like 'pg_%'
order by pg_relation_size(indexrelid) desc;
```

### A.5 Check foreign key index coverage

```sql
with fk_columns as (
    select
        tc.table_schema,
        tc.table_name,
        kcu.column_name,
        ccu.table_name as referenced_table
    from information_schema.table_constraints as tc
    join information_schema.key_column_usage as kcu
        on tc.constraint_name = kcu.constraint_name
        and tc.table_schema = kcu.table_schema
    join information_schema.constraint_column_usage as ccu
        on ccu.constraint_name = tc.constraint_name
    where tc.constraint_type = 'FOREIGN KEY'
),
indexed_columns as (
    select
        schemaname,
        tablename,
        (string_to_array(indkey::text, ' '))[1]::int as first_col_num
    from pg_indexes
    join pg_index on indexrelid = (schemaname || '.' || indexname)::regclass
)
select
    fk.table_schema,
    fk.table_name,
    fk.column_name,
    fk.referenced_table,
    case
        when exists (
            select 1
            from pg_index as i
            join pg_attribute as a
                on a.attrelid = i.indrelid
                and a.attnum = i.indkey[0]
            where
                i.indrelid = (fk.table_schema || '.' || fk.table_name)::regclass
                and a.attname = fk.column_name
        ) then 'INDEXED'
        else 'NO INDEX - Consider adding'
    end as index_status
from fk_columns as fk
order by table_schema, table_name;
```

---

## Quick reference: decision cheat sheet

| Situation | Action |
|-----------|--------|
| idx_scan = 0, stats > 30 days, RCA confirms no usage | **DROP** |
| idx_scan = 0, stats < 7 days | **WAIT** for more data |
| idx_scan = 0, but enforces unique/PK | **KEEP** (document) |
| idx_scan low, but it's only index on FK column | **KEEP** (needed for FK checks) |
| Overlapping: `(a)` exists with `(a,b)` | **DROP** `(a)` if queries on `a` alone are rare |
| Overlapping: both indexes heavily used | **INVESTIGATE** query patterns first |
| No logs, no pg_stat_statements | **ENABLE** monitoring, wait 2-4 weeks |
| Can't reach developers, uncertain usage | **SOFT DROP** test with HypoPG |
| Index is huge (>10 GB), want to be safe | **Blue/Green** deploy or clone-test first |

---

## References

1. PostgreSQL Documentation: [Indexes](https://www.postgresql.org/docs/current/indexes.html)
2. PostgreSQL Wiki: [Index Maintenance](https://wiki.postgresql.org/wiki/Index_Maintenance)
3. CYBERTEC: [Get rid of your unused indexes](https://www.cybertec-postgresql.com/en/get-rid-of-your-unused-indexes/) (2023)
4. PostgresAI: [How to find redundant indexes](https://postgres.ai/docs/postgres-howtos/performance-optimization/indexing/how-to-find-redundent-indexes)
5. Percona: [Useful PostgreSQL index maintenance queries](https://www.percona.com/blog/useful-queries-for-postgresql-index-maintenance/) (2023)
6. AWS: [PostgreSQL maintenance for RDS/Aurora](https://docs.aws.amazon.com/prescriptive-guidance/latest/postgresql-maintenance-rds-aurora/introduction.html)
7. AWS: [Blue/Green deployments](https://aws.amazon.com/blogs/database/perform-maintenance-tasks-and-schema-modifications-in-amazon-rds-for-postgresql-with-minimal-downtime/)
8. Google Cloud: [Cloud SQL Index Advisor](https://cloud.google.com/sql/docs/postgres/use-index-advisor)
9. Supabase: [Managing indexes in PostgreSQL](https://supabase.com/docs/guides/database/postgres/indexes)
10. HypoPG: [Documentation](https://hypopg.readthedocs.io/en/rel1_stable/)
11. pg_qualstats: [GitHub repository](https://github.com/powa-team/pg_qualstats)
12. Crunchy Data: [Query optimization with pg_stat_statements](https://www.crunchydata.com/blog/tentative-smarter-query-optimization-in-postgres-starts-with-pg_stat_statements) (2024)
13. AWS: [Performance Insights for PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.UsingDashboard.AnalyzeDBLoad.AdditionalMetrics.PostgreSQL.html)

---

*This guide is a living document. Index management practices evolve with PostgreSQL versions and cloud platform features. Always test in non-production environments first.*
