# PostgreSQL Source Code Security Audit Report

- **Date:** 2026-04-04
- **Scope:** PostgreSQL server and libpq client source code
- **Methodology:** Manual source code review of security-critical subsystems
- **Auditors:** 3-person team covering Authentication/Crypto, Network/Input, and Memory Safety/Privilege Escalation

---

## Executive Summary

This audit identified **31 security findings** across the PostgreSQL codebase, ranging from informational observations to high-severity design issues. The codebase demonstrates mature security engineering overall -- message parsing is well-bounded, memory contexts prevent many common C vulnerabilities, and privilege checks are consistently applied. However, several classes of issues persist:

- **Timing side-channels** in authentication code (4 findings)
- **Sensitive data not cleared from memory** (3 findings)
- **Weak/legacy cryptographic primitives** still supported (3 findings)
- **Insufficient input validation** in binary protocol receivers (2 findings)
- **Privilege escalation surfaces** through extensions and large objects (3 findings)

### Severity Distribution

| Severity | Count |
|----------|-------|
| High | 1 |
| Medium | 16 |
| Low | 8 |
| Informational | 6 |

---

## Table of Contents

1. [Authentication & Cryptography](#1-authentication--cryptography)
2. [Network Protocol & Input Validation](#2-network-protocol--input-validation)
3. [Memory Safety & Privilege Escalation](#3-memory-safety--privilege-escalation)

---

## 1. Authentication & Cryptography

### 1.1 Timing Attack in MD5 Password Verification

- **Severity:** Medium
- **File:** `src/backend/libpq/crypt.c`, lines 296 and 375

**Description:** Both `md5_crypt_verify()` and `plain_crypt_verify()` use `strcmp()` for comparing password hashes. `strcmp()` is not constant-time -- it returns as soon as it finds a mismatching byte. An attacker with precise network timing measurements could progressively determine bytes of the correct password hash.

**Vulnerable code:**
```c
// Line 296 (md5_crypt_verify)
if (strcmp(client_pass, crypt_pwd) == 0)

// Line 375 (plain_crypt_verify)
if (strcmp(crypt_client_pass, shadow_pass) == 0)
```

**Exploitation scenario:** Repeated password guesses with timing measurements to leak hash bytes.

**Remediation:** Replace `strcmp()` with a constant-time comparison function (e.g., `CRYPTO_memcmp` from OpenSSL).

---

### 1.2 Timing Attack in SCRAM `scram_verify_plain_password()`

- **Severity:** Medium
- **File:** `src/backend/libpq/auth-scram.c`, line 582

**Description:** Uses `memcmp()` to compare the computed ServerKey against the stored ServerKey. Called during plaintext password authentication when a user has a SCRAM-SHA-256 stored secret.

**Vulnerable code:**
```c
return memcmp(computed_key, server_key, key_length) == 0;
```

**Remediation:** Replace with constant-time comparison.

---

### 1.3 Timing Attack in SCRAM `verify_client_proof()`

- **Severity:** Low
- **File:** `src/backend/libpq/auth-scram.c`, line 1189

**Description:** The SCRAM client proof verification uses non-constant-time `memcmp()`. Lower practical impact because the proof changes every attempt due to the nonce, but deviates from cryptographic best practice.

**Vulnerable code:**
```c
if (memcmp(client_StoredKey, state->StoredKey, state->key_length) != 0)
    return false;
```

**Remediation:** Replace with constant-time comparison.

---

### 1.4 Timing Attack in RADIUS Response Authenticator Verification

- **Severity:** Medium
- **File:** `src/backend/libpq/auth.c`, line 3244

**Description:** RADIUS response authenticator verified using `memcmp()`. A man-in-the-middle between PostgreSQL and the RADIUS server could forge response packets and use timing information to discover the shared secret.

**Vulnerable code:**
```c
if (memcmp(receivepacket->vector, encryptedpassword, RADIUS_VECTOR_LENGTH) != 0)
```

**Remediation:** Use a constant-time comparison function.

---

### 1.5 SCRAM Iteration Count Minimum is 1 (Server-Side)

- **Severity:** Medium
- **File:** `src/backend/utils/misc/guc_parameters.dat`

**Description:** The `scram_iterations` GUC allows setting the PBKDF2 iteration count as low as 1. RFC 7677 specifies a minimum of 4096. An administrator could misconfigure this, making SCRAM secrets trivially brute-forceable. Additionally, `parse_scram_secret()` in `auth-scram.c` performs no minimum iteration count validation when parsing stored secrets.

**Exploitation scenario:** DBA sets `scram_iterations = 1` to reduce CPU load; attacker who obtains `pg_authid` cracks passwords with negligible effort.

**Remediation:** Set the GUC minimum to 4096 per RFC 7677. Add validation in `parse_scram_secret()`.

---

### 1.6 Client Does Not Enforce Minimum SCRAM Iteration Count

- **Severity:** Medium
- **File:** `src/interfaces/libpq/fe-auth-scram.c`, lines 676-681

**Description:** The client (libpq) accepts any iteration count >= 1 from the server. A malicious server or MITM attacker can set `i=1`, causing the client to compute a SCRAM proof with minimal key stretching, enabling password recovery. No maximum is enforced either, enabling CPU DoS on the client.

**Vulnerable code:**
```c
state->iterations = strtol(iterations_str, &endptr, 10);
if (*endptr != '\0' || state->iterations < 1)
```

**Remediation:** Enforce minimum (e.g., 4096) and maximum (e.g., 100,000,000) iteration counts on the client.

---

### 1.7 MD5 Authentication Still Fully Supported

- **Severity:** Medium (Design-level)
- **File:** `src/backend/libpq/auth.c`, lines 859-860; `src/backend/libpq/crypt.c`, lines 199-204

**Description:** MD5 password hashing (`MD5(password + username)`) has no random salt and no key stretching. The `password` auth method sends passwords in cleartext without TLS. Deprecation warnings now exist but the mechanism remains functional.

**Remediation:** Continue deprecation process; establish a firm removal timeline.

---

### 1.8 PAM Password Stored in Static Global, Not Zeroed

- **Severity:** Low
- **File:** `src/backend/libpq/auth.c`, lines 114, 2048

**Description:** The PAM auth path stores the plaintext password in a static global `pam_passwd`. After authentication, the pointer is set to NULL but the actual memory contents are not zeroed -- the password remains in the palloc'd buffer until reused.

**Remediation:** Use `explicit_bzero()` on password buffers before freeing.

---

### 1.9 LDAP Sends Password Over Potentially Unencrypted Connection

- **Severity:** Medium (Configuration-dependent)
- **File:** `src/backend/libpq/auth.c`, line 2643

**Description:** LDAP authentication uses `ldap_simple_bind_s()` which performs a plaintext LDAP bind. If neither LDAPS nor StartTLS is configured, the password traverses two unencrypted hops: client-to-PostgreSQL and PostgreSQL-to-LDAP.

**Remediation:** Issue warnings at HBA parse time when `ldapscheme` and `ldaptls` are both unset.

---

### 1.10 No Memory Clearing for SCRAM Key Material

- **Severity:** Low
- **File:** `src/interfaces/libpq/fe-auth-scram.c`, lines 181-203

**Description:** `scram_free()` frees the SCRAM state including `password` and `SaltedPassword` without zeroing first. Server-side code similarly does not zero `ClientKey`, `StoredKey`, `ServerKey` fields.

**Remediation:** Call `explicit_bzero()` on sensitive fields before freeing.

---

### 1.11 RADIUS Password Length Limit

- **Severity:** Low (Informational)
- **File:** `src/backend/libpq/auth.c`, lines 2787-2892

**Description:** RADIUS rejects passwords > 128 bytes (RFC 2865 protocol limit). Error is only logged server-side; the client receives a generic auth failure.

**Remediation:** Document the limitation in pg_hba.conf documentation.

---

### 1.12 RADIUS Uses MD5 for Password Encryption

- **Severity:** Medium (Protocol Limitation)
- **File:** `src/backend/libpq/auth.c`, lines 3016-3057

**Description:** RADIUS protocol uses MD5 to encrypt user passwords in transit (per RFC 2865). Vulnerable if the shared secret is weak. RADSEC (RADIUS over TLS) is not supported.

**Remediation:** Document that RADIUS should only be used over trusted networks.

---

## 2. Network Protocol & Input Validation

### 2.1 XML Entity Expansion (Billion Laughs / Internal XXE)

- **Severity:** Medium
- **File:** `src/backend/utils/adt/xml.c`, lines 1882-1888

**Description:** `xml_parse()` uses `XML_PARSE_NOENT` when parsing XML as DOCUMENT, enabling internal entity expansion attacks. While the external entity loader blocks external entities, internal entity definitions are still processed, enabling exponential expansion.

**Vulnerable code:**
```c
options = XML_PARSE_NOENT | XML_PARSE_DTDATTR
    | (preserve_whitespace ? 0 : XML_PARSE_NOBLANKS);
```

**Exploitation scenario:** Authenticated user submits XML with nested entity definitions expanding exponentially (Billion Laughs), consuming CPU and memory.

**Remediation:** Set explicit libxml2 entity expansion limits. Consider making entity substitution optional via a GUC.

---

### 2.2 Integer Overflow in `be_loread()` Allocation

- **Severity:** Low
- **File:** `src/backend/libpq/be-fsstubs.c`, lines 364-372

**Description:** `len` is `int32` (max ~2B). `palloc(VARHDRSZ + len)` computes `4 + len` in signed 32-bit arithmetic. Near `INT32_MAX`, this overflows -- technically undefined behavior.

**Vulnerable code:**
```c
int32       len = PG_GETARG_INT32(1);
retval = (bytea *) palloc(VARHDRSZ + len);
```

**Remediation:** Cast to `Size` before addition: `palloc((Size) VARHDRSZ + (Size) len)`.

---

### 2.3 Large Object Import/Export -- Arbitrary Server File Read/Write

- **Severity:** High (Design-level)
- **File:** `src/backend/libpq/be-fsstubs.c`, lines 424-551

**Description:** `lo_import()` and `lo_export()` read from and write to arbitrary server filesystem paths. Gated by `pg_read_server_files` / `pg_write_server_files` roles, but no path sanitization, chroot, or directory restrictions exist. `lo_export` creates files with permissions 0644 (world-readable).

**Exploitation scenario:** A user with `pg_read_server_files` (or via SQL injection into a superuser context) reads `/etc/shadow`, PG config files, or writes to crontabs/web directories.

**Remediation:** Consider adding a GUC to restrict allowed directories for lo_import/lo_export.

---

### 2.4 `lo_compat_privileges` Bypasses ACL Checks on Large Objects

- **Severity:** Medium (Configuration-dependent)
- **File:** `src/backend/storage/large_object/inv_api.c`, lines 252-264

**Description:** When `lo_compat_privileges = on`, all ACL checks on large objects are skipped. Any authenticated user can read/write any large object.

**Remediation:** Consider deprecating this GUC or adding a startup warning when enabled.

---

### 2.5 Denial of Service via Unbounded `numeric_recv()` Allocation

- **Severity:** Medium
- **File:** `src/backend/utils/adt/numeric.c`, lines 1076-1078

**Description:** The binary receive function reads a `uint16` digit count (0-65535) and immediately allocates memory proportional to it. Via COPY BINARY or binary-format parameterized queries, an attacker can send many such values to exhaust backend memory.

**Remediation:** Add a reasonableness check on `ndigits` (e.g., limit to a few thousand digits).

---

### 2.6 Client-Side Integer Overflow Risk in `getAnotherTuple()`

- **Severity:** Low (Client-side)
- **File:** `src/interfaces/libpq/fe-protocol3.c`, lines 803-806

**Description:** Row buffer resizing computes `nfields * sizeof(PGdataValue)` without explicit overflow checking. Currently safe due to 16-bit protocol field bounds, but lacks defense-in-depth.

**Remediation:** Add explicit upper-bound checks on field counts.

---

### 2.7 `XML_PARSE_DTDATTR` Enables Internal DTD Processing

- **Severity:** Low
- **File:** `src/backend/utils/adt/xml.c`, line 1882

**Description:** Intentional per SQL/XML:2008, but internal DTD processing enables entity-based attacks and can consume significant CPU for complex DTDs.

---

### 2.8 Fastpath Function Calls Bypass SQL-Level Security Policies

- **Severity:** Medium (Design-level)
- **File:** `src/backend/tcop/fastpath.c`, lines 187-299

**Description:** The fastpath (PQfn) interface calls functions by OID, bypassing Row-Level Security policies, event triggers, and query-level auditing. It does check schema USAGE and function EXECUTE ACLs.

**Remediation:** Add security hooks to the fastpath path, or fully deprecate the protocol.

---

### 2.9 SSL Buffered Data MITM Detection

- **Severity:** Informational (Positive finding)
- **File:** `src/backend/tcop/backend_startup.c`, lines 626-630

**Description:** After SSL negotiation, the code correctly checks for buffered unencrypted data that arrived before the handshake, detecting potential MITM injection. Good security practice.

---

### 2.10 Extended Query Protocol Error Handling

- **Severity:** Informational
- **File:** `src/backend/tcop/postgres.c`, lines 4789-4790

**Description:** The `ignore_till_sync` mechanism correctly handles protocol desynchronization during extended query errors. Well-implemented.

---

## 3. Memory Safety & Privilege Escalation

### 3.1 TOCTOU Race Condition in `pg_signal_backend()`

- **Severity:** Medium
- **File:** `src/backend/storage/ipc/signalfuncs.c`, lines 52-124

**Description:** Race between privilege check (which looks up the target process's role) and the `kill()` call. Between these points, the PID could be recycled by a more privileged process. The code acknowledges this risk in a comment.

**Exploitation scenario:** On systems with randomized PID assignment, an attacker with `pg_signal_backend` could race to terminate a superuser-owned backend.

**Remediation:** Consider using `pidfd_send_signal()` on Linux, or compare process start timestamps.

---

### 3.2 Trusted Extension Privilege Escalation Surface

- **Severity:** Medium
- **File:** `src/backend/commands/extension.c`, lines 1266-1304

**Description:** When a trusted extension has `superuser = true` and `trusted = true`, a non-superuser with CREATE privilege triggers the backend to elevate to `BOOTSTRAP_SUPERUSERID` to execute the extension's SQL script. Security depends entirely on directory permissions.

**Vulnerable code:**
```c
if (switch_to_superuser)
{
    SetUserIdAndSecContext(BOOTSTRAP_SUPERUSERID,
                           save_sec_context | SECURITY_LOCAL_USERID_CHANGE);
}
```

**Exploitation scenario:** If `extension_control_path` includes a user-writable directory, a non-superuser places a malicious `.control` file with `trusted = true` and `superuser = true`, gaining superuser execution.

**Remediation:** Validate directory permissions on `extension_control_path` entries.

---

### 3.3 Integer Truncation in `pg_terminate_backend()` Timeout

- **Severity:** Low
- **File:** `src/backend/storage/ipc/signalfuncs.c`, lines 239-242

**Description:** `timeout` declared as `int` but read via `PG_GETARG_INT64()`. Values like 2^32 truncate to 0, causing the function to skip the wait entirely.

**Remediation:** Use `int64` for the timeout variable or validate range before truncation.

---

### 3.4 Trigger Argument Count Integer Overflow (int16)

- **Severity:** Low
- **File:** `src/backend/commands/trigger.c`, line 888

**Description:** `nargs` stored as `int16` but `list_length()` returns `int`. If > 32767 arguments, the value silently wraps.

**Remediation:** Add explicit bounds check: `if (nargs > PG_INT16_MAX) ereport(ERROR, ...)`.

---

### 3.5 Systemic Use of Unbounded `sprintf()`

- **Severity:** Medium (Systemic risk)
- **File:** `src/port/snprintf.c`, lines 213-227

**Description:** `pg_vsprintf()` sets `bufend = NULL` (no bounds checking). Any caller using `sprintf()` into a fixed-size buffer has a potential buffer overflow. While individually audited instances appear safe, the pattern is fragile for future code.

**Vulnerable code:**
```c
target.bufend = NULL;  /* no limit! */
```

**Remediation:** Systematically replace `sprintf()` with `snprintf()`. Add `-Wformat-overflow` compiler warnings.

---

### 3.6 `system()` Calls with Command Injection Risk Surface

- **Severity:** Medium (Configuration-dependent)
- **File:** `src/backend/archive/shell_archive.c`, line 81; `src/backend/access/transam/xlogarchive.c`, line 178

**Description:** Archive and restore commands pass superuser-configured GUC strings to `system()`. The `%p` placeholder (path) is interpolated without shell escaping. A data directory path containing shell metacharacters could cause command injection.

**Remediation:** Apply shell escaping to substitution values before interpolation.

---

### 3.7 Superuser Cache Staleness Window

- **Severity:** Informational
- **File:** `src/backend/utils/misc/superuser.c`, lines 57-97

**Description:** `superuser_arg()` uses a single-entry cache that is invalidated asynchronously. Revoking superuser status does not take immediate effect in existing sessions. This is expected PostgreSQL behavior.

---

### 3.8 `check_function_bodies` Disabled During Extension Scripts

- **Severity:** Low
- **File:** `src/backend/commands/extension.c`, lines 1334-1338

**Description:** SQL functions in extension scripts are not validated during creation. Combined with trusted extensions (Finding 3.2), a compromised script could define malicious functions bypassing creation-time validation.

---

### 3.9 `MODULE_PATHNAME` Substitution Without Quoting Validation

- **Severity:** Low
- **File:** `src/backend/commands/extension.c`, lines 1477-1484

**Description:** `MODULE_PATHNAME` replacement in extension SQL scripts does not check for quoting-relevant characters (`"`, `$`, `'`, `\`), unlike `@extowner@` and `@extschema@`. A malicious `module_pathname` in a control file could inject SQL.

**Remediation:** Apply the same `quoting_relevant_chars` validation to `module_pathname`.

---

## Recommendations Summary

### Immediate (High Priority)

1. **Replace all non-constant-time comparisons** in auth code (`strcmp`/`memcmp` -> constant-time compare) -- Findings 1.1-1.4
2. **Set SCRAM iteration minimum to 4096** (server GUC and client enforcement) -- Findings 1.5-1.6
3. **Add directory permission validation** for `extension_control_path` -- Finding 3.2

### Short-Term (Medium Priority)

4. **Zero sensitive memory** (`explicit_bzero`) before freeing passwords and key material -- Findings 1.8, 1.10
5. **Add bounds checking** to `numeric_recv()` digit count -- Finding 2.5
6. **Migrate `sprintf()` -> `snprintf()`** systematically -- Finding 3.5
7. **Apply shell escaping** in archive/restore command substitution -- Finding 3.6
8. **Set entity expansion limits** for XML parsing -- Finding 2.1
9. **Validate `module_pathname`** for quoting-relevant characters -- Finding 3.9

### Long-Term (Design-Level)

10. **Complete MD5 authentication deprecation** and removal -- Finding 1.7
11. **Deprecate `lo_compat_privileges`** GUC -- Finding 2.4
12. **Add directory restrictions** for `lo_import`/`lo_export` -- Finding 2.3
13. **Add security hooks to fastpath** or fully deprecate it -- Finding 2.8
14. **Use `pidfd_send_signal()`** on modern Linux to close TOCTOU window -- Finding 3.1
15. **Require LDAPS/StartTLS** or warn when LDAP is configured without encryption -- Finding 1.9

---

*End of report*
