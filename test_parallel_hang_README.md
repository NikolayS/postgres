# Test Suite for IPC:ParallelFinish Hang Reproduction

## Theory Being Tested

**Theory 1: Shared Memory Queue Saturation**

Workers block indefinitely when attempting to write to full 16KB error queues, creating a deadlock where:
1. Workers need leader to drain queue to proceed
2. Leader only drains queue when `ParallelMessagePending` flag is set
3. Flag is only set when workers successfully send messages
4. Workers cannot send messages because queue is full
5. Result: Leader waits forever in `WaitForParallelWorkersToFinish()` with `IPC:ParallelFinish` wait event

## Files

- `test_parallel_queue_saturation.sql` - Main test script
- `monitor_parallel_hang.sql` - Monitoring script (run in separate session)
- `test_parallel_hang_alternative.sql` - Alternative approaches if main test doesn't reproduce

## Setup Requirements

- PostgreSQL 16.3
- Sufficient shared_buffers (at least 1GB recommended)
- No aggressive statement_timeout or idle timeouts

## Running the Test

### Terminal 1: Start PostgreSQL

```bash
cd /home/user/postgres
./configure --prefix=/tmp/pgtest --enable-debug --enable-cassert CFLAGS="-O0 -g"
make -j$(nproc)
make install

# Initialize test cluster
/tmp/pgtest/bin/initdb -D /tmp/pgtest_data

# Configure for parallel execution
cat >> /tmp/pgtest_data/postgresql.conf <<EOF
max_parallel_workers_per_gather = 4
max_parallel_workers = 8
max_worker_processes = 8
shared_buffers = 1GB
work_mem = 256MB
log_min_messages = info
log_min_duration_statement = 1000
log_line_prefix = '%m [%p] %q%u@%d '
EOF

# Start server
/tmp/pgtest/bin/pg_ctl -D /tmp/pgtest_data -l /tmp/pgtest.log start

# Create test database
/tmp/pgtest/bin/createdb test
```

### Terminal 2: Run Monitor

```bash
/tmp/pgtest/bin/psql test -f monitor_parallel_hang.sql
```

### Terminal 3: Run Test

```bash
/tmp/pgtest/bin/psql test -f test_parallel_queue_saturation.sql
```

## Expected Outcomes

### If Theory 1 is Correct

In Terminal 2 (monitor), you should see:
- Leader backend with `wait_event = 'IPC:ParallelFinish'`
- Parallel workers with `wait_event = 'IPC:MessageQueueSend'` or similar
- Query duration increasing indefinitely

In Terminal 3 (test), the query will hang and not complete.

To confirm, in Terminal 4:
```bash
/tmp/pgtest/bin/psql test -c "
SELECT pid, wait_event, state, backend_type, query_start
FROM pg_stat_activity
WHERE query LIKE '%test_employees%' OR backend_type = 'parallel worker';
"
```

Try to terminate:
```bash
# Get PID from above query, then:
/tmp/pgtest/bin/psql test -c "SELECT pg_terminate_backend(<pid>);"
# Should return true but query continues running
```

### If Theory is Not Reproduced

The query completes successfully, possibly with many NOTICE messages output.
This would suggest:
- Queue draining mechanism works better than theorized
- Additional conditions are needed to trigger the deadlock
- Theory 1 may not be the primary cause

## Alternative Test Approaches

If the main test doesn't reproduce the issue, try `test_parallel_hang_alternative.sql` which includes:

1. **Slower leader processing**: Add sleep in transaction to slow leader's message processing
2. **More workers**: Increase to 4-8 parallel workers to create more contention
3. **Larger messages**: Generate even bigger NOTICE messages to fill queue faster
4. **Combined with autovacuum**: Run VACUUM in parallel to add buffer contention
5. **Multiple queries**: Run several parallel queries simultaneously

## Cleanup

```bash
/tmp/pgtest/bin/pg_ctl -D /tmp/pgtest_data stop
rm -rf /tmp/pgtest_data /tmp/pgtest.log
```

## Code References (PostgreSQL 16.3)

- Queue size constant: [`parallel.c:55`](https://github.com/postgres/postgres/blob/REL_16_3/src/backend/access/transam/parallel.c#L55)
- Worker blocking on send: [`pqmq.c:171-174`](https://github.com/postgres/postgres/blob/REL_16_3/src/backend/libpq/pqmq.c#L171-L174)
- Leader wait for workers: [`parallel.c:886`](https://github.com/postgres/postgres/blob/REL_16_3/src/backend/access/transam/parallel.c#L886)
- Message processing gate: [`postgres.c:3103-3106`](https://github.com/postgres/postgres/blob/REL_16_3/src/backend/tcop/postgres.c#L3103-L3106)

## Notes

- This test is synthetic and may not perfectly reproduce production conditions
- Production issue involves autovacuum, which adds additional contention
- 252K dead tuples in production is significant - we simulate ~250K here
- Real issue may require combination of factors (dead tuples + autovacuum + specific timing)
