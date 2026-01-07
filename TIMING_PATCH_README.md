# psql LAST_QUERY_MS Patch

Always measure query timing and store in `LAST_QUERY_MS` variable.

## The Idea (from Kirk)

> psql `\timing on/off` only controls output. ALWAYS MEASURE the time taken,
> and store it in "LAST_QUERY_MS". This is a tiny change overall. AND it
> should be done. There is NO reason to NOT measure the execution time.
> It's a lightning fast operation. It's DISPLAYING the time that slows
> things down.

## Changes

- `src/bin/psql/startup.c`: Initialize `LAST_QUERY_MS` to "0"
- `src/bin/psql/common.c`: Always measure timing, store in variable

## Build & Test

```bash
# Build from source
./configure --prefix=$HOME/pg_test
make -j$(nproc)

# Test (no install needed)
./src/bin/psql/psql -h /var/run/postgresql -U postgres -f test_last_query_ms.sql
```

## Expected Behavior

```
-- Current psql (unpatched):
postgres=# \timing off
postgres=# SELECT 1;
 ?column?
----------
        1
postgres=# \echo :LAST_QUERY_MS
:LAST_QUERY_MS            <-- variable doesn't exist

-- Patched psql:
postgres=# \timing off
postgres=# SELECT 1;
 ?column?
----------
        1
postgres=# \echo :LAST_QUERY_MS
0.547                     <-- always available!
```

## Use Cases

1. **Scripted timing analysis** without cluttering output:
   ```sql
   \timing off
   SELECT expensive_query();
   \if :LAST_QUERY_MS > 1000
     \echo 'WARNING: Query took more than 1 second'
   \endif
   ```

2. **Conditional logic based on query time**:
   ```sql
   SELECT my_function();
   \set slowquery (:LAST_QUERY_MS > 500)
   ```

3. **Logging timing to table**:
   ```sql
   \timing off
   SELECT run_benchmark();
   INSERT INTO timing_log VALUES (now(), :LAST_QUERY_MS);
   ```
