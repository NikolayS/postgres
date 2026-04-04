-- N-2: Client SCRAM Parser Accepts Trailing Garbage in Server Messages
-- Severity: Medium
-- File: src/interfaces/libpq/fe-auth-scram.c, lines 683-686, 732-733
--
-- This is a CLIENT-SIDE bug in libpq. It cannot be triggered from SQL.
-- Verification requires code analysis of the source.

\echo '=== N-2: SCRAM trailing garbage acceptance (code analysis) ==='

\echo 'This finding is verified by source code analysis, not runtime test.'
\echo ''
\echo 'In src/interfaces/libpq/fe-auth-scram.c:'
\echo '  read_server_first_message() at line 683:'
\echo '    if (*input != chr(0)) -> appends error but does NOT return false'
\echo '  read_server_final_message() at line 732:'
\echo '    if (*input != chr(0)) -> appends error but does NOT return false'
\echo ''
\echo 'Both functions detect garbage but continue authentication.'
\echo 'This is clearly a missing "return false" after each error append.'
\echo ''
\echo 'N-2 RESULT: *** VERIFIED BY CODE ANALYSIS ***'

\echo '=== N-2 test complete ==='
