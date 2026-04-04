# Security Audit Verification Tests

PoC tests verifying findings from `SECURITY_AUDIT_REPORT.md`.

## Prerequisites

- PostgreSQL built from source with contrib modules (`refint`, `tablefunc`, `xml2`)
- Server running on port 15432 with socket at /tmp
- User `pgtest` with superuser access

## Running

```bash
PSQL="sudo -u pgtest /tmp/pg-test/bin/psql -p 15432 -h /tmp -d pgtest"

# SQL tests
$PSQL -f tests/security/S-1_refint_identifier_injection.sql
$PSQL -f tests/security/S-2_refint_cascade_injection.sql
$PSQL -f tests/security/S-3_tablefunc_connectby_injection.sql
$PSQL -f tests/security/S-4_xml2_xpath_table_injection.sql
$PSQL -f tests/security/X-3_advisory_lock_exhaustion.sql

# Shell tests
sudo -u pgtest bash tests/security/N-1_copy_binary_dos.sh

# Code analysis tests (no runtime test, verified by source review)
$PSQL -f tests/security/N-2_scram_trailing_garbage.sql
$PSQL -f tests/security/N-4_radius_bounds_check.sql
```

## Verification Results

| ID | Finding | Test Result | Method |
|----|---------|-------------|--------|
| S-1 | refint.c: unquoted identifiers | **VERIFIED** | Subquery injection bypasses FK check - fk_col=99999 accepted |
| S-2 | refint.c: unescaped cascade values | **VERIFIED** | WHERE injection affects ALL rows; version() exfiltrated into child table |
| S-3 | tablefunc connectby(): unquoted relname | **VERIFIED** | Subquery as relname reads secret data from arbitrary table |
| S-4 | xml2 xpath_table(): unquoted params | **VERIFIED** | Condition bypass with OR true; relname subquery exfiltrates secret data |
| X-3 | Advisory lock table exhaustion | **VERIFIED** | 14,912 advisory locks exhaust shared lock table, causing "out of shared memory" |
| N-1 | COPY BINARY uninterruptible DoS | **VERIFIED** | Backend survives pg_cancel_backend() during header extension parsing |
| N-2 | SCRAM trailing garbage acceptance | **VERIFIED** | Source code analysis: missing `return false` after error detection |
| N-4 | RADIUS attribute bounds off-by-two | **VERIFIED** | Source code analysis: check uses `len` but should use `len + 2` |

### Not Runtime-Testable (Require Special Infrastructure)

| ID | Finding | Notes |
|----|---------|-------|
| S-5 | postgres_fdw IMPORT FOREIGN SCHEMA | Requires malicious foreign server |
| X-1 | Logical replication heap over-read | Requires malicious publisher |
| P-1 | ECPG strncpy buffer overflow | Requires rogue server + ECPG client |
| P-2 | DecodeMultiInsert Assert-only bounds | Requires crafted WAL stream |
| N-3 | RADIUS source IP not validated | Requires network MITM setup |
