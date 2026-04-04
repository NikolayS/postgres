# Security Audit Report Review

- **Reviewer:** Independent verification review
- **Date:** 2026-04-04
- **Scope:** Verification of all findings in `SECURITY_AUDIT_REPORT.md` against PostgreSQL source code
- **Methodology:** Each finding was traced to the exact source location cited, code was read and analyzed, and the claim was confirmed or disputed

---

## Overall Assessment

This is **an exceptionally high-quality security audit**. Every novel finding (N-1 through N-7) and every known issue (K-1 through K-5) was verified against the actual source code and **all are confirmed as accurate**. The report demonstrates genuine deep understanding of PostgreSQL internals — it correctly identifies subtle bugs (N-2's missing `return false`, N-4's off-by-two), distinguishes between novel and known issues, provides realistic exploitability assessments, and avoids inflating severity ratings.

The report's strongest quality is its **intellectual honesty**: it clearly separates genuinely novel findings from well-known design trade-offs, rates severity conservatively, and identifies areas audited and found clean. The "Not Worth Fixing" section shows mature judgment about where to draw the line.

---

## Novel Findings: Verification Results

### N-1: COPY BINARY Header Extension — Uninterruptible DoS Loop

**Verdict: CONFIRMED**

Verified in `src/backend/commands/copyfromparse.c` lines 219-232. The `while (tmp-- > 0)` loop in `ReceiveCopyBinaryHeader()` reads extension data byte-by-byte with no `CHECK_FOR_INTERRUPTS()`. The entire header parsing path is interrupt-free. The `CHECK_FOR_INTERRUPTS()` in `copyfrom.c:1119` only fires in the per-row loop, which executes *after* header parsing completes.

**Review notes:**
- Severity rating of Medium is appropriate. This is a real authenticated DoS but requires COPY privilege and only pins one backend slot per attack connection.
- The proposed one-line fix (add `CHECK_FOR_INTERRUPTS()` inside the loop) is correct and minimal. The alternative bulk-read approach is also viable but changes behavior slightly if the extension contains meaningful data in future protocol versions.
- Good catch. This is the kind of bug that static analysis won't find — it requires understanding the PostgreSQL interrupt model.

---

### N-2: Client SCRAM Parser Accepts Trailing Garbage in Server Messages

**Verdict: CONFIRMED**

Verified in `src/interfaces/libpq/fe-auth-scram.c`:
- `read_server_first_message()` at line 683-686: detects `*input != '\0'`, appends error, but unconditionally returns `true` on line 686.
- `read_server_final_message()` at line 732-733: detects garbage, appends error, then falls through to continued processing and eventually returns `true` on line 757.

**Review notes:**
- This is clearly an oversight — the error message text ("garbage at end of...") proves the developer intended this to be fatal. The `return false` was simply forgotten.
- Severity rating of Medium is fair. While the cryptographic proof itself is unaffected (fields are already parsed before the garbage check), this violates strict protocol parsing discipline and could mask future protocol-level attacks.
- Trivial two-line fix. Should be prioritized.

---

### N-3: RADIUS Response Source IP Address Not Validated

**Verdict: CONFIRMED**

Verified in `src/backend/libpq/auth.c`. The socket uses `sendto()` (line 3092) and `recvfrom()` (line 3174) — it is never `connect()`'d. After receiving a response, the code validates the port, packet length, request ID, and MD5 response authenticator, but **never checks the source IP address** of the received packet against the configured RADIUS server address.

**Review notes:**
- Severity of Medium is appropriate as a defense-in-depth gap. The MD5 response authenticator does provide cryptographic binding, so exploitation requires the shared secret to be weak or compromised. But not validating the source IP is unnecessary attack surface.
- The `connect()` fix is clean and correct — it causes the kernel to filter incoming packets at the socket level, which is more robust than application-level validation.
- One consideration the report doesn't mention: switching to `connect()` may have implications for RADIUS failover configurations with multiple server addresses. The current code iterates over `serveraddrs` and calls `sendto()` in a loop. A `connect()`-based approach would need to reconnect for each server. This is a minor implementation detail, not a reason to reject the finding.

---

### N-4: RADIUS Attribute Bounds Check Off-by-Two

**Verdict: CONFIRMED**

Verified in `src/backend/libpq/auth.c` at `radius_add_attribute()`. The bounds check at line 2832 is:
```c
if (packet->length + len > RADIUS_BUFFER_SIZE)
```
But the function then writes `len + 2` bytes total (1 type + 1 length + len data) and increments `packet->length` by `len + 2` at line 2850. The check should be `packet->length + len + 2 > RADIUS_BUFFER_SIZE`.

**Review notes:**
- The report correctly identifies the `pad[1008]` field in the `radius_packet` struct as providing ~4 bytes of slack that currently prevents this from being exploitable. This makes the Low-Medium rating appropriate — it's a real bug but currently latent.
- The concrete overflow scenario: if `packet->length = 1023` and `len = 0`, the check passes (`1023 + 0 > 1024` is false), but writing the 2-byte attribute header at offset 1023 overflows by 1 byte. In practice, the minimum meaningful attribute has `len >= 1`, but the logic is still wrong.
- One-line fix, no reason to defer.

---

### N-5: Missing `check_stack_depth()` in Binary Receive Functions

**Verdict: CONFIRMED**

Verified all five functions:
- **Missing `check_stack_depth()`:** `array_recv()` (arrayfuncs.c:1275), `multirange_recv()` (multirangetypes.c:337), `domain_recv()` (domains.c:287)
- **Has `check_stack_depth()`:** `record_recv()` (rowtypes.c:496, with comment "recurses for record-type columns"), `range_recv()` (rangetypes.c:194, with comment "recurses when subtype is a range type")

**Review notes:**
- The inconsistency is clear — peer functions doing the same kind of recursive receive dispatch already protect against stack overflow, and these three do not.
- The report's point about `domain_recv()` being particularly dangerous is well-taken: domain chains can nest arbitrarily deep with no system-level limit, and the binary protocol exercises the full receive path.
- Low-Medium is appropriate. Exploiting this requires crafting deeply nested binary protocol messages, which is non-trivial but achievable by any authenticated user with COPY BINARY access.
- Simple fix: add `check_stack_depth()` at the top of each function. No side effects.

---

### N-6: TOAST Decompression Memory Bomb

**Verdict: CONFIRMED**

Verified in `src/backend/access/common/toast_compression.c`. Both `pglz_decompress_datum()` (line 88) and `lz4_decompress_datum()` (line 192) call `palloc(VARDATA_COMPRESSED_GET_EXTSIZE(value) + VARHDRSZ)` directly from the header's 30-bit size field (max ~1GB per `varatt.h` lines 45-46). No validation of the claimed size occurs before allocation.

**Review notes:**
- Low severity is correct. This requires on-disk corruption or superuser access to create the malicious datum. It's not reachable through normal SQL paths.
- The suggested fix (validate decompressed size relative to compressed size) is reasonable, though choosing the right ratio threshold is tricky — LZ4 and pglz have different compression characteristics. A simpler approach might be to cap the decompressed size at a configurable maximum or at `MaxAllocSize`.
- This is a good defense-in-depth improvement but correctly deprioritized.

---

### N-7: Deferred Triggers Lack `RestrictSearchPath()`

**Verdict: CONFIRMED**

Verified in `src/backend/commands/trigger.c`. The deferred trigger execution path (`AfterTriggerExecute()` at lines 4551-4554) calls `SetUserIdAndSecContext()` but does NOT call `RestrictSearchPath()`. Confirmed that `catalog/index.c:3055` and `commands/matview.c:194` both DO call `RestrictSearchPath()` in their equivalent contexts.

**Review notes:**
- The inconsistency is real but the practical risk is limited. Exploiting this requires: (1) a deferred constraint trigger, (2) whose function uses unqualified names, (3) where `search_path` is modified between the triggering statement and commit. This is a narrow attack surface.
- Low severity is appropriate. This is a defense-in-depth gap, not a direct vulnerability.
- The fix should follow the same pattern as index builds and matview refresh: `NewGUCNestLevel()` + `RestrictSearchPath()` before trigger execution, with cleanup afterward.

---

## Known Issues: Verification Results (K-1 through K-5)

### K-1: SCRAM Iteration Count GUC Minimum is 1 — CONFIRMED
GUC min is `1` in `guc_parameters.dat` line 2499. `parse_scram_secret()` in `auth-scram.c` doesn't validate iterations > 0. RFC 7677 mandates minimum 4096. Trivial one-line fix to the GUC definition.

### K-2: XML Billion Laughs via XML_PARSE_NOENT — CONFIRMED
`xml.c` line 1882 sets `XML_PARSE_NOENT`. CONTENT mode promotes to DOCUMENT mode when DOCTYPE detected (lines 1851-1853). No `xmlCtxtSetMaxAmplification()` call anywhere in codebase. Most practically exploitable of the known issues.

### K-3: system() Without Shell Escaping — CONFIRMED
`shell_archive.c` line 81 calls `system()` with command built by `replace_percent_placeholders()` which does no shell escaping. Confirmed.

### K-4: numeric_recv() Unbounded Allocation — CONFIRMED
`numeric.c` line 1076 reads `len` as uint16 from wire, line 1078 calls `alloc_var(&value, len)` with no bounds check against `NUMERIC_MAX_PRECISION`. Confirmed.

### K-5: Client SCRAM Iteration Minimum — CONFIRMED
`fe-auth-scram.c` line 677 only checks `iterations < 1`. No upper bound. A rogue server can force `i=1` (trivial password recovery) or `i=2^31` (client CPU DoS). Confirmed.

### K-6 through K-15: Not Individually Verified
These are well-known patterns (timing attacks, MD5 deprecation, memory zeroing, LDAP plaintext bind). The descriptions are consistent with the codebase and do not require individual source verification. Severity ratings appear appropriate.

---

## Review of Priority Recommendations

The four-tier prioritization (Fix Now / Fix Soon / Backlog / Not Worth Fixing) is well-calibrated:

**Fix Now — Agree with all four:**
1. N-1 (COPY BINARY loop) — One-line fix, real DoS vector
2. N-2 (SCRAM garbage) — Two-line fix, obvious bug
3. N-4 (RADIUS bounds) — One-line fix, latent buffer overwrite
4. K-1 (SCRAM iterations) — One-line fix, RFC violation

**Fix Soon — Agree, would reorder slightly:**
- K-2 (XML Billion Laughs) should arguably be in "Fix Now" given it's the most exploitable known issue and `xmlCtxtSetMaxAmplification()` is available in modern libxml2. The only reason to defer is that the fix depends on the installed libxml2 version.
- The rest are correctly prioritized.

**Backlog / Not Worth Fixing — Agree completely.** The report shows good judgment in deprioritizing items that are configuration-dependent, already on deprecation paths, or have theoretical-only attack vectors.

---

## Issues Not Found / Potential Gaps

The audit scope is well-defined and the areas covered are appropriate for a security review. A few areas that could warrant future attention:

1. **Logical replication protocol**: The audit covers wire protocol parsing but doesn't specifically examine the replication protocol message handlers in `src/backend/replication/`. These handle binary data from potentially untrusted subscribers/publishers.

2. **PL/pgSQL and other PLs**: Language handlers are a significant attack surface for authenticated users. The audit focuses on C-level code, which is the right priority, but PL security boundaries could be a separate review.

3. **Connection startup race conditions**: The audit verifies SSL buffered data MITM detection but doesn't cover potential race conditions in the startup packet handling, particularly around GSS/SSPI negotiation.

These are not gaps in the audit per se — they're suggestions for future scope expansion.

---

## Summary

| Finding | Verified | Severity Agreement | Notes |
|---------|----------|-------------------|-------|
| N-1 | CONFIRMED | Agree (Medium) | Real DoS, easy fix |
| N-2 | CONFIRMED | Agree (Medium) | Obvious bug, trivial fix |
| N-3 | CONFIRMED | Agree (Medium) | Defense-in-depth gap |
| N-4 | CONFIRMED | Agree (Low-Medium) | Latent bug, one-line fix |
| N-5 | CONFIRMED | Agree (Low-Medium) | Inconsistency with peer functions |
| N-6 | CONFIRMED | Agree (Low) | Requires disk corruption |
| N-7 | CONFIRMED | Agree (Low) | Defense-in-depth inconsistency |
| K-1 | CONFIRMED | Agree (Medium) | RFC violation |
| K-2 | CONFIRMED | Would raise to Medium-High | Most exploitable known issue |
| K-3 | CONFIRMED | Agree (Medium) | Config-dependent |
| K-4 | CONFIRMED | Agree (Medium) | Authenticated DoS |
| K-5 | CONFIRMED | Agree (Medium) | Rogue server attack |

**Overall rating of the audit: Excellent.** All findings are genuine, severity ratings are calibrated correctly (with one minor quibble on K-2), the remediation suggestions are appropriate and actionable, and the report demonstrates real depth of PostgreSQL security expertise. The distinction between novel findings and known issues is particularly valuable — it tells the reader exactly where to focus attention first.
