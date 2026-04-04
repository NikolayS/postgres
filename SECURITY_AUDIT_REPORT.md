# PostgreSQL Source Code Security Audit Report

- **Date:** 2026-04-04
- **Scope:** PostgreSQL server and libpq client source code
- **Methodology:** Manual source code review of security-critical subsystems, multi-pass with independent peer review
- **Auditors:** Multi-team audit covering Authentication/Crypto, Network/Input, Memory Safety/Privilege Escalation, plus independent deep-dive review

---

## Executive Summary

This audit combined a broad initial pass with a focused deep-dive into complex code paths. The PostgreSQL codebase is mature and well-engineered -- wire protocol parsing is robust, memory contexts prevent many common C bugs, and privilege checks are consistently applied.

The initial pass identified mostly **well-known design trade-offs** (timing attacks, MD5 deprecation, lo_import/lo_export). The deep-dive review found **genuinely novel, actionable bugs** including an uninterruptible DoS in COPY BINARY, a client SCRAM parser bug, and a RADIUS bounds check error.

### Novel Findings (Deep-Dive)

| ID | Finding | Severity | Exploitability |
|----|---------|----------|----------------|
| N-1 | COPY BINARY header loop: uninterruptible DoS | Medium | Any authenticated user |
| N-2 | SCRAM client accepts trailing garbage in server messages | Medium | Malicious server / MITM |
| N-3 | RADIUS response source IP not validated | Medium | Network attacker |
| N-4 | RADIUS attribute bounds check off-by-two | Low-Medium | Latent bug |
| N-5 | Missing `check_stack_depth()` in binary recv functions | Low-Medium | Authenticated user |
| N-6 | TOAST decompression memory bomb | Low | Requires disk corruption |
| N-7 | Deferred triggers lack `RestrictSearchPath()` | Low | Authenticated user |

### Known Issues (Initial Pass, Reassessed)

| ID | Finding | Severity | Notes |
|----|---------|----------|-------|
| K-1 | SCRAM iteration count GUC minimum is 1 | Medium | Trivial one-line fix |
| K-2 | XML Billion Laughs via `XML_PARSE_NOENT` | Medium | Most exploitable known issue |
| K-3 | `system()` without shell escaping in archive commands | Medium | Low effort fix |
| K-4 | `numeric_recv()` unbounded allocation | Medium | Authenticated DoS |
| K-5 | Client doesn't enforce SCRAM iteration minimum | Medium | Downgrade attack |
| K-6 | SCRAM `scram_verify_plain_password()` timing | Low-Medium | Network jitter limits exploitability |
| K-7 | SCRAM `verify_client_proof()` timing | Low | Nonce prevents exploitation |
| K-8 | MD5 `strcmp()` timing | Low | MD5 already deprecated |
| K-9 | RADIUS `memcmp()` timing | Low | Requires MITM position |
| K-10 | Trusted extension privilege escalation surface | Medium | Requires OS-level filesystem compromise |
| K-11 | No memory clearing for SCRAM key material | Low | Memory forensics scenario |
| K-12 | PAM password not zeroed | Low | Memory forensics scenario |
| K-13 | LDAP plaintext bind | Low | Configuration-dependent |
| K-14 | MD5 auth still supported | Low | On deprecation path |
| K-15 | Unbounded `sprintf()` systemic pattern | Low | Long-term migration |

---

## Part 1: Novel Findings

### N-1: COPY BINARY Header Extension -- Uninterruptible DoS Loop

- **Severity:** Medium
- **File:** `src/backend/commands/copyfromparse.c`, lines 219-232
- **Privileges required:** Any authenticated user with COPY privilege (default for table owners)

**Description:** When parsing a COPY BINARY header, the extension length is read as an `int32`. The code then reads the extension data one byte at a time in a tight loop with **no `CHECK_FOR_INTERRUPTS()` call**. The entire `copyfromparse.c` header parsing path contains zero interrupt checks -- the only one is in the per-row loop in `copyfrom.c:1119`, which runs *after* header parsing completes.

**Vulnerable code:**
```c
/* Header extension length */
if (!CopyGetInt32(cstate, &tmp) || tmp < 0)
    ereport(ERROR, ...);
/* Skip extension header, if present */
while (tmp-- > 0)
{
    if (CopyReadBinaryData(cstate, readSig, 1) != 1)
        ereport(ERROR, ...);
}
```

**Exploitation scenario:** An attacker executes `COPY table FROM STDIN (FORMAT binary)`, sends a valid header with `extension_length = INT_MAX` (2,147,483,647), then slowly feeds bytes. The backend is pinned in this tight loop and **cannot be cancelled** by `pg_cancel_backend()` or `statement_timeout`. Only `pg_terminate_backend()` (SIGKILL) can stop it. This can be used to exhaust backend connection slots.

**Remediation:** Add `CHECK_FOR_INTERRUPTS()` inside the `while` loop, or read the extension in bulk via a single `CopyReadBinaryData(cstate, buf, tmp)` call.

---

### N-2: Client SCRAM Parser Accepts Trailing Garbage in Server Messages

- **Severity:** Medium (protocol conformance bug)
- **File:** `src/interfaces/libpq/fe-auth-scram.c`, lines 683-686 and 732-733

**Description:** In both `read_server_first_message()` and `read_server_final_message()`, the client detects trailing garbage in the server's SCRAM response, appends an error message, but **does not return `false`**. Authentication proceeds as if the message were valid. This is clearly an intended-to-be-fatal check where someone forgot the `return false`.

**Vulnerable code:**
```c
// In read_server_first_message(), line 683:
if (*input != '\0')
    libpq_append_conn_error(conn,
        "malformed SCRAM message (garbage at end of server-first-message)");
return true;  // BUG: continues authentication despite detecting garbage

// In read_server_final_message(), line 732:
if (*input != '\0')
    libpq_append_conn_error(conn,
        "malformed SCRAM message (garbage at end of server-final-message)");
// falls through to return true
```

**Exploitation scenario:** A malicious server or MITM can inject arbitrary trailing data in SCRAM messages and the client silently accepts it. While it doesn't affect the cryptographic proof (fields are already parsed), it violates strict protocol parsing and could mask injection of future protocol extensions.

**Remediation:** Add `return false;` after each `libpq_append_conn_error` call in both locations.

---

### N-3: RADIUS Response Source IP Address Not Validated

- **Severity:** Medium (defense-in-depth gap)
- **File:** `src/backend/libpq/auth.c`, lines 3173-3190

**Description:** The RADIUS UDP socket is unconnected (`sendto()` at line 3092 instead of `connect()` + `send()`), so `recvfrom()` accepts packets from **any source IP**. The MD5 response authenticator check (line 3232-3244) provides cryptographic verification, but if the shared secret is weak, an attacker on the local network can send spoofed `ACCESS_ACCEPT` packets to bypass authentication.

**Remediation:** Use `connect()` on the UDP socket to restrict incoming packets to the configured RADIUS server address.

---

### N-4: RADIUS Attribute Bounds Check Off-by-Two

- **Severity:** Low-Medium (latent buffer overwrite)
- **File:** `src/backend/libpq/auth.c`, line 2832

**Description:** The bounds check in `radius_add_attribute()` accounts for `len` data bytes but **not the 2-byte attribute header** (type + length fields). Each attribute actually consumes `len + 2` bytes.

**Vulnerable code:**
```c
static void
radius_add_attribute(radius_packet *packet, uint8 type,
                     const unsigned char *data, int len)
{
    if (packet->length + len > RADIUS_BUFFER_SIZE)  // BUG: should be len + 2
    {
        elog(WARNING, ...);
        return;
    }
    attr->attribute = type;
    attr->length = len + 2;   /* type (1) + length (1) + data (len) */
    memcpy(attr->data, data, len);
    packet->length += attr->length;  // adds len + 2, not len
}
```

**Current mitigation:** The `radius_packet` struct has a `pad` field providing ~4 bytes of slack beyond what the check guards. The off-by-2 cannot currently exceed this margin, but this is fragile -- any future struct layout change could make it exploitable as a stack buffer overwrite.

**Remediation:** Change the check to `packet->length + len + 2 > RADIUS_BUFFER_SIZE`.

---

### N-5: Missing `check_stack_depth()` in Binary Receive Functions

- **Severity:** Low-Medium
- **Files:**
  - `src/backend/utils/adt/arrayfuncs.c` -- `array_recv()` (line 1275)
  - `src/backend/utils/adt/multirangetypes.c` -- `multirange_recv()` (line 337)
  - `src/backend/utils/adt/domains.c` -- `domain_recv()` (line 287)

**Description:** These binary receive functions can recurse through composite types (e.g., `array_recv -> record_recv -> array_recv -> ...`) but lack `check_stack_depth()` calls. Peer functions like `record_recv()` and `range_recv()` correctly include them.

`domain_recv()` is particularly concerning: domains can chain arbitrarily deep (domain over domain over domain...) with no system-level limit on nesting depth. A deeply nested domain chain exercised via binary protocol could overflow the stack before any check fires.

**Remediation:** Add `check_stack_depth()` at the top of `array_recv()`, `multirange_recv()`, and `domain_recv()`.

---

### N-6: TOAST Decompression Memory Bomb

- **Severity:** Low (requires on-disk corruption or superuser)
- **File:** `src/backend/access/common/toast_compression.c`, lines 82 and 182

**Description:** The claimed decompressed size is read from the datum's header (30-bit field, max ~1GB). A tiny compressed datum with a corrupted header claiming 1GB decompressed size causes a 1GB `palloc` before decompression begins. The decompressors themselves (`LZ4_decompress_safe`, `pglz_decompress`) are safe, so this is memory exhaustion only, not a buffer overflow.

**Remediation:** Validate that the claimed decompressed size is reasonable relative to the compressed size before allocating.

---

### N-7: Deferred Triggers Lack `RestrictSearchPath()`

- **Severity:** Low (defense-in-depth gap)
- **File:** `src/backend/commands/trigger.c`, lines 4551-4572

**Description:** Deferred constraint triggers fire at commit time using the triggering role's identity (`SetUserIdAndSecContext`), but there is **no `RestrictSearchPath()` call**. This is inconsistent with index builds (`catalog/index.c:3055`), materialized view refresh (`commands/matview.c:194`), and VACUUM/ANALYZE, which all call `RestrictSearchPath()`.

If a deferred trigger function uses unqualified names and `search_path` is modified between the triggering statement and commit, the trigger could resolve names differently than intended.

**Remediation:** Add `RestrictSearchPath()` call before deferred trigger execution, consistent with other protected contexts.

---

## Part 2: Known Issues (Reassessed Severity)

### K-1: SCRAM Iteration Count GUC Minimum is 1

- **Severity:** Medium
- **File:** `src/backend/utils/misc/guc_parameters.dat`

**Description:** The `scram_iterations` GUC allows values as low as 1. RFC 7677 mandates minimum 4096. Additionally, `parse_scram_secret()` in `auth-scram.c` (line 640-643) accepts iterations=0 or negative values from stored secrets. With `iterations=0`, `scram_SaltedPassword()` reduces PBKDF2 to a single HMAC pass.

**Remediation:** Set GUC minimum to 4096. Add validation in `parse_scram_secret()` to reject `iterations < 1`.

---

### K-2: XML Billion Laughs via `XML_PARSE_NOENT` (Enhanced Analysis)

- **Severity:** Medium
- **File:** `src/backend/utils/adt/xml.c`, lines 1851-1888

**Description:** Beyond the basic `XML_PARSE_NOENT` issue, there is a **DOCTYPE promotion mechanism**: when `xmloption = CONTENT` (the default), PostgreSQL's `xml_parse()` silently promotes any input containing a DOCTYPE declaration to DOCUMENT-mode parsing, which enables `XML_PARSE_NOENT`. This means DBAs who believe CONTENT-mode is safer get no protection -- any authenticated user can force entity expansion by including `<!DOCTYPE ...>` in their XML.

**Exploitation scenario:** `SELECT '<xml/>'::xml` is safe, but `SELECT '<!DOCTYPE d [<!ENTITY x "...">]><d>&x;</d>'::xml` triggers DOCUMENT-mode with entity expansion even when `xmloption = CONTENT`.

**Remediation:** Set `xmlCtxtSetMaxAmplification()` or equivalent libxml2 limits.

---

### K-3: `system()` Without Shell Escaping in Archive Commands

- **Severity:** Medium (configuration-dependent)
- **File:** `src/backend/archive/shell_archive.c`, line 81; `src/backend/access/transam/xlogarchive.c`, line 178

**Description:** Archive/restore commands interpolate `%p` (path) without shell escaping. A data directory path containing shell metacharacters could cause command injection. Requires superuser to configure, but the escaping gap is a bad pattern.

**Remediation:** Apply shell escaping to substitution values.

---

### K-4: `numeric_recv()` Unbounded Allocation

- **Severity:** Medium
- **File:** `src/backend/utils/adt/numeric.c`, lines 1076-1078

**Description:** Binary receive reads `uint16` digit count and allocates proportionally. Via COPY BINARY, a client can send many 65535-digit values to exhaust backend memory.

**Remediation:** Add reasonableness check on `ndigits`.

---

### K-5: Client Doesn't Enforce SCRAM Iteration Minimum

- **Severity:** Medium
- **File:** `src/interfaces/libpq/fe-auth-scram.c`, lines 676-681

**Description:** libpq accepts `i=1` from server, enabling password recovery by a rogue server. No maximum is enforced either, enabling CPU DoS.

**Remediation:** Enforce minimum 4096, maximum ~100M.

---

### K-6 through K-9: Timing Attacks in Authentication (Consolidated)

- **Severity:** Low-Medium (K-6), Low (K-7, K-8, K-9)
- **Files:** `src/backend/libpq/auth-scram.c` (lines 582, 1189), `src/backend/libpq/crypt.c` (lines 296, 375), `src/backend/libpq/auth.c` (line 3244)

**Description:** Non-constant-time `memcmp()`/`strcmp()` in password and SCRAM verification. Real but low practical exploitability over network connections due to jitter, buffering, and TLS overhead. The MD5 timing attack (K-8) is on a deprecated mechanism. The RADIUS timing attack (K-9) requires MITM between PG and RADIUS server.

**Remediation:** Replace with constant-time comparisons. Low effort, good defense-in-depth.

---

### K-10: Trusted Extension Privilege Escalation

- **Severity:** Medium
- **File:** `src/backend/commands/extension.c`, lines 1266-1304

**Description:** Non-superuser with CREATE privilege can trigger superuser execution if `extension_control_path` includes a writable directory. `extension_control_path` is properly `PGC_SUSET` + `GUC_SUPERUSER_ONLY`, so exploitation requires OS-level filesystem compromise of a directory a superuser added to the path.

---

### K-11 through K-15: Lower-Priority Known Issues

- **K-11 (Low):** SCRAM key material not zeroed before free -- `src/interfaces/libpq/fe-auth-scram.c:181-203`
- **K-12 (Low):** PAM password in static global not zeroed -- `src/backend/libpq/auth.c:114`
- **K-13 (Low):** LDAP plaintext bind when LDAPS/StartTLS not configured -- `src/backend/libpq/auth.c:2643`
- **K-14 (Low):** MD5 authentication still supported, on deprecation path -- `src/backend/libpq/auth.c:859`
- **K-15 (Low):** Systemic unbounded `sprintf()` usage -- `src/port/snprintf.c:213-227`

---

## Part 3: Areas Audited and Found Clean

The following areas were thoroughly reviewed and found well-implemented:

- **Wire protocol message parsing** (`src/backend/tcop/postgres.c`): Robust length validation, proper bounds checking in all `pq_getmsg*` functions
- **StringInfo API** (`src/common/stringinfo.c`): Overflow guards in `enlargeStringInfo()`, proper negative-value handling
- **Extension system quoting** (`src/backend/commands/extension.c`): `quoting_relevant_chars` validation is sound for `@extschema@` and `@extowner@`
- **SECURITY DEFINER cleanup** (`src/backend/utils/fmgr/fmgr.c`): Error-path cleanup correctly relies on transaction abort
- **RLS enforcement**: Correctly applied to COPY, logical replication, CREATE MATERIALIZED VIEW AS
- **LEAKPROOF checks**: Properly enforced for both CREATE and ALTER FUNCTION
- **SSL buffered data MITM detection** (`src/backend/tcop/backend_startup.c:626-630`): Correctly rejects pre-handshake data
- **Extended query error handling** (`src/backend/tcop/postgres.c:4789`): `ignore_till_sync` correctly prevents desync
- **No `alloca()` or VLA usage** found in backend code; PostgreSQL consistently uses `palloc()`

---

## Part 4: Priority Recommendations

### Fix Now (low effort, real impact)

1. **COPY BINARY header loop** (N-1): Add `CHECK_FOR_INTERRUPTS()`. One-line fix, prevents authenticated DoS.
2. **SCRAM client garbage acceptance** (N-2): Add `return false` in two locations. Obvious bug.
3. **RADIUS bounds check** (N-4): Change `len` to `len + 2`. One-line fix.
4. **SCRAM iteration minimum** (K-1): Set GUC min to 4096. One-line fix.

### Fix Soon (moderate effort, defense-in-depth)

5. **RADIUS source IP validation** (N-3): Switch to `connect()` on UDP socket.
6. **XML entity expansion limits** (K-2): Set `xmlCtxtSetMaxAmplification()` or equivalent.
7. **Missing `check_stack_depth()`** (N-5): Add calls to `array_recv`, `multirange_recv`, `domain_recv`.
8. **Server-side SCRAM iteration validation** (K-1 extension): Validate `iterations > 0` in `parse_scram_secret()`.
9. **Client SCRAM iteration bounds** (K-5): Enforce min/max on client side.

### Backlog (known trade-offs, long-term)

10. Shell escaping in archive commands (K-3)
11. Memory zeroing for key material (K-11, K-12)
12. Constant-time comparisons in auth (K-6 through K-9)
13. MD5 deprecation completion (K-14)
14. `numeric_recv()` bounds check (K-4)
15. `sprintf` -> `snprintf` migration (K-15)

### Not Worth Fixing

- **lo_import/lo_export directory restrictions**: Working as designed, role-gated behind near-superuser privileges
- **Fastpath RLS bypass**: Fastpath is essentially deprecated
- **Superuser cache staleness**: Documented, expected behavior
- **TOCTOU in pg_signal_backend**: Theoretical on modern systems, acknowledged in code

---

*End of report*
