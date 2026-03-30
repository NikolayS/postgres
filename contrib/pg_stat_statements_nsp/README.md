# pg_stat_statements_nsp

A query statistics extension that works **without** requiring `shared_preload_libraries`.

## Overview

This extension demonstrates how to use the DSM (Dynamic Shared Memory) Registry,
introduced in PostgreSQL 17, to create shared data structures that persist across
sessions without needing to be loaded at server startup.

Unlike the standard `pg_stat_statements`, this extension can be loaded dynamically
via the `LOAD` command or `session_preload_libraries`, making it ideal for:

- Cloud environments where modifying `shared_preload_libraries` requires a restart
- Development and testing scenarios
- Situations where you want to enable query tracking without server downtime

## Key Features

- **No server restart required**: Load via `LOAD 'pg_stat_statements_nsp'`
- **Shared statistics**: Statistics are shared across all sessions once initialized
- **Similar API**: Provides a familiar interface similar to `pg_stat_statements`

## Limitations

Compared to the full `pg_stat_statements`:

- Statistics do **not** persist across server restarts (no disk storage)
- Fixed maximum number of tracked statements (1000)
- Simplified statistics (no planning stats, WAL stats, etc.)
- Query text is not stored (only query IDs are tracked)
- No GUC parameters for configuration

## Installation

1. Build and install:
   ```bash
   cd contrib/pg_stat_statements_nsp
   make
   make install
   ```

2. Create the extension in your database:
   ```sql
   CREATE EXTENSION pg_stat_statements_nsp;
   ```

## Usage

1. Enable query ID computation and load the module:
   ```sql
   SET compute_query_id = on;
   LOAD 'pg_stat_statements_nsp';
   ```

2. Run some queries to collect statistics:
   ```sql
   SELECT 1;
   SELECT * FROM pg_class LIMIT 10;
   ```

3. View the collected statistics:
   ```sql
   SELECT * FROM pg_stat_statements_nsp;
   ```

4. Reset statistics:
   ```sql
   SELECT pg_stat_statements_nsp_reset();
   ```

## Output Columns

| Column | Type | Description |
|--------|------|-------------|
| userid | oid | User OID who executed the query |
| dbid | oid | Database OID where query was executed |
| queryid | bigint | Query identifier (hash) |
| calls | bigint | Number of times executed |
| total_time | double precision | Total execution time in milliseconds |
| min_time | double precision | Minimum execution time |
| max_time | double precision | Maximum execution time |
| mean_time | double precision | Mean execution time |
| rows | bigint | Total rows retrieved or affected |

## Technical Details

This extension uses:

- **DSM Registry** (`GetNamedDSMSegment`, `GetNamedDSHash`): For lazy allocation
  of shared memory without requiring `shared_preload_libraries`
- **dshash**: A concurrent hash table that supports dynamic resizing in DSM
- **Executor hooks**: To track query execution (works without preload)

## Requirements

- PostgreSQL 17 or later (for DSM Registry `GetNamedDSHash` support)
- `compute_query_id` must be enabled (either `on` or `auto`)

## See Also

- `pg_stat_statements` - The full-featured query statistics extension
- DSM Registry documentation in PostgreSQL source

## License

PostgreSQL License
