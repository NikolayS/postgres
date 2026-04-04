-- X-3: Advisory Lock Table Exhaustion -- Complete Database DoS
-- Severity: Medium
-- File: src/backend/storage/lmgr/lock.c, line 3375
--
-- This test verifies that advisory locks share the main lock table
-- and can exhaust it, preventing other operations.
--
-- NOTE: This test is conservative -- it acquires locks in batches
-- and checks for the "out of shared memory" error rather than
-- actually DoS-ing the database.

\echo '=== X-3: Advisory lock table exhaustion test ==='

-- First, check max_locks_per_transaction to understand capacity
SHOW max_locks_per_transaction;
SHOW max_connections;

\echo 'Attempting to acquire many advisory locks...'

-- Try to acquire a large number of advisory locks
-- The shared lock table size = max_locks_per_transaction * (max_connections + max_prepared_transactions + 25)
-- Default: 64 * (100 + 0 + 25) = 8000 entries
-- We try to exhaust it from a single session

DO $$
DECLARE
    i int;
    lock_count int := 0;
    hit_limit boolean := false;
BEGIN
    -- Try acquiring advisory locks in a loop
    FOR i IN 1..100000 LOOP
        BEGIN
            PERFORM pg_advisory_lock(i);
            lock_count := lock_count + 1;
        EXCEPTION WHEN out_of_memory OR SQLSTATE '53200' THEN
            -- 53200 = out_of_shared_memory
            hit_limit := true;
            RAISE NOTICE 'Hit shared memory limit after % advisory locks', lock_count;
            EXIT;
        END;
    END LOOP;

    IF hit_limit THEN
        RAISE NOTICE 'X-3 RESULT: *** VERIFIED *** - Advisory locks exhausted shared lock table after % locks', lock_count;
    ELSE
        RAISE NOTICE 'X-3 RESULT: Acquired % locks without hitting limit (may need more locks or larger test)', lock_count;
    END IF;

    -- Release all acquired locks
    FOR i IN 1..lock_count LOOP
        PERFORM pg_advisory_unlock(i);
    END LOOP;
    RAISE NOTICE 'Released all % advisory locks', lock_count;
END;
$$;

\echo '=== X-3 test complete ==='
