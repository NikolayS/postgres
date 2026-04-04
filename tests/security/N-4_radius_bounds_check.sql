-- N-4: RADIUS Attribute Bounds Check Off-by-Two (Code Analysis Verification)
-- Severity: Low-Medium
-- File: src/backend/libpq/auth.c, line 2832
--
-- This is a CODE ANALYSIS finding that cannot be easily triggered via SQL.
-- The verification is done by examining the source code to confirm the bug.
-- This script documents the analysis.

\echo '=== N-4: RADIUS attribute bounds check off-by-two (code analysis) ==='

\echo 'This finding is verified by source code analysis, not runtime test.'
\echo ''
\echo 'In src/backend/libpq/auth.c, radius_add_attribute():'
\echo '  Line 2832: if (packet->length + len > RADIUS_BUFFER_SIZE)'
\echo '  But each attribute consumes len + 2 bytes (1 type + 1 length + len data).'
\echo '  The check should be: packet->length + len + 2 > RADIUS_BUFFER_SIZE'
\echo ''
\echo 'The bug is mitigated by the radius_packet struct having a pad field'
\echo 'that provides ~4 bytes of slack. But the off-by-two is real.'
\echo ''
\echo 'N-4 RESULT: *** VERIFIED BY CODE ANALYSIS ***'

\echo '=== N-4 test complete ==='
