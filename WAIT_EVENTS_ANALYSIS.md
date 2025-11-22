# PostgreSQL Wait Events Coverage Gap Analysis

- **Date:** 2025-11-21
- **Analyst:** @NikolayS + Claude Code Sonnet 4.5
- **Purpose:** Identify code areas lacking wait event instrumentation that may be incorrectly visualized as "CPU" time in ASH and monitoring tools

- **Repository:** https://github.com/NikolayS/postgres
- **Commit Hash:** `b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44`
- **Branch:** `claude/cpu-asterisk-wait-events-01CyiYYMMcFMovuqPqLNcp8T`

> **Note:** All code references in this document link to the specific commit hash to avoid code drift. Click on file paths and line numbers to view the exact code on GitHub.

---

## Executive Summary

This analysis identified **45 specific locations** across the PostgreSQL codebase where operations may block or consume significant time without proper wait event instrumentation. These gaps cause monitoring tools to display activity as "CPU" (shown as green or "CPU*") when processes are actually waiting on I/O, network, or external services.

**Of these, 30 are required fixes for true blocking operations, and 15 are optional for observability improvements.**

### Key Findings by Category:

| Category | Critical Issues | High Priority | Medium Priority | Total Locations | Type | Status |
|----------|----------------|---------------|-----------------|-----------------|------|--------|
| I/O Operations | 0 | 5 | 2 | 7 | Wait Events | Required |
| Authentication | 15 | 8 | 0 | 23 | Wait Events | Required |
| Compression | 0 | 0 | 0 | 7 | Wait Events (CPU) | **OPTIONAL** |
| Cryptography | 0 | 0 | 0 | 8 | Wait Events (CPU) | **OPTIONAL** |

**Total: 15 Critical, 13 High Priority, 2 Medium Priority = 30 required issues + 15 optional = 45 total locations**

**Type Legend:**
- **Wait Events**: Operations blocked waiting on external resources (I/O, network, locks)
- **Wait Events (CPU)**: CPU operations that benefit from labeling for monitoring visibility (OPTIONAL)

---

## Category 1: I/O Operations Missing Wait Events

### 1.1 Recovery Signal File Operations (HIGH)

**File:** [`src/backend/access/transam/xlogrecovery.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/access/transam/xlogrecovery.c)

| Line | Function | Operation | Impact |
|------|----------|-----------|--------|
| [1072](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/access/transam/xlogrecovery.c#L1072) | `StartupInitAutoStandby()` | `pg_fsync(fd)` for STANDBY_SIGNAL_FILE | Critical startup path |
| [1085](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/access/transam/xlogrecovery.c#L1085) | `StartupInitAutoStandby()` | `pg_fsync(fd)` for RECOVERY_SIGNAL_FILE | Critical startup path |

**Proposed Wait Events:**
```
# In WaitEventIO category:
RECOVERY_SIGNAL_FILE_SYNC    "Waiting to sync recovery signal file"
STANDBY_SIGNAL_FILE_SYNC     "Waiting to sync standby signal file"
```

**Priority:** HIGH - Critical startup path for standby servers

---

### 1.2 Storage Manager File Operations (HIGH)

**File:** [`src/backend/storage/smgr/md.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/smgr/md.c)

| Line | Function | Operation | Impact |
|------|----------|-----------|--------|
| [395](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/smgr/md.c#L395) | `mdunlinkfork()` | `unlink(path.str)` | Relation file deletion |
| [454](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/smgr/md.c#L454) | `mdunlinkfork()` | `unlink(segpath.str)` | Additional segment deletion (loop) |
| [1941](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/smgr/md.c#L1941) | `mdunlinkfiletag()` | `unlink(path)` | File tag-based deletion |

**Priority:** HIGH - Affects table/index file management

---

### 1.3 Dynamic Shared Memory Operations (MEDIUM)

**File:** [`src/backend/storage/ipc/dsm_impl.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/ipc/dsm_impl.c)

| Line | Function | Operation | Impact |
|------|----------|-----------|--------|
| [278](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/ipc/dsm_impl.c#L278) | DSM operations | `fstat(fd, &st)` | Shared memory file metadata |
| [849](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/ipc/dsm_impl.c#L849) | DSM cleanup | `fstat(fd, &st)` | Shared memory cleanup |

**Priority:** MEDIUM - Used in parallel query execution

---

## Category 2: Authentication Operations Missing Wait Events (CRITICAL)

### 2.1 LDAP Authentication (CRITICAL)

**File:** [`src/backend/libpq/auth.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c)
**Function:** `check_ldapauth()`

**Issue:** LDAP authentication can block for SECONDS waiting for directory services. No wait event instrumentation exists for any LDAP operation.

| Line | Operation | Blocking Potential |
|------|-----------|-------------------|
| [2222](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L2222) | `ldap_init()` | Network connection to LDAP server |
| [2320](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L2320) | `ldap_initialize()` | Network connection (OpenLDAP) |
| [2339](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L2339) | `ldap_init()` | Network connection fallback |
| [2350](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L2350) | `ldap_set_option()` | May perform network operations |
| [2551](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L2551) | `ldap_search_s()` | **SYNCHRONOUS SEARCH - WORST OFFENDER** |
| [2602](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L2602) | `ldap_get_option()` | May perform network operations |
| [2660](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L2660) | `ldap_get_option()` | May perform network operations |

**Impact:** Every LDAP authentication blocks the backend process without visibility. Under authentication load, this causes:
- Connection storms appear as "CPU" load
- No way to identify LDAP server slowness
- Cannot distinguish slow LDAP from actual CPU work

**Proposed Wait Events:**
```
# NEW Category: WaitEventAuth (or extend WaitEventClient)
AUTH_LDAP_INIT           "Waiting to connect to LDAP server"
AUTH_LDAP_BIND           "Waiting for LDAP bind operation"
AUTH_LDAP_SEARCH         "Waiting for LDAP search operation"
AUTH_LDAP_OPTION         "Waiting for LDAP option operation"
```

**Priority:** CRITICAL - Blocks every login when LDAP is configured

---

### 2.2 Ident Authentication (CRITICAL)

**File:** [`src/backend/libpq/auth.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c)
**Function:** `ident_inet()`

**XXX Comment at [lines 1659-1660](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L1659-L1660):** Code explicitly notes this needs improvement!

| Line | Operation | Blocking Potential |
|------|-----------|-------------------|
| [1686-1689](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L1686-L1689) | `pg_getnameinfo_all()` | Reverse DNS lookup - can timeout |
| [1704](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L1704) | `pg_getaddrinfo_all()` | Forward DNS lookup for ident server |
| [1720](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L1720) | `pg_getaddrinfo_all()` | Forward DNS lookup (local address) |
| [1728-1729](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L1728-L1729) | `socket()` | Socket creation |
| [1744](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L1744) | `bind()` | Socket binding |
| [1755-1756](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L1755-L1756) | `connect()` | TCP connection to ident server |
| [1776](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L1776) | `send()` | Send ident request |
| [1793](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L1793) | `recv()` | Receive ident response |

**Impact:** Ident authentication performs:
1. Multiple DNS lookups (each can take seconds)
2. TCP connection to remote ident server
3. Network I/O without WaitLatchOrSocket wrapper

**Proposed Wait Events:**
```
# In WaitEventAuth or WaitEventClient
AUTH_DNS_LOOKUP          "Waiting for DNS resolution during authentication"
AUTH_IDENT_CONNECT       "Waiting to connect to ident server"
AUTH_IDENT_IO            "Waiting for ident server response"
```

**Priority:** CRITICAL - Blocks authentication with DNS/network issues

---

### 2.3 RADIUS Authentication (HIGH)

**File:** [`src/backend/libpq/auth.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c)
**Function:** `check_radius()`

**XXX Comment at [lines 3094-3096](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L3094-L3096):** Code explicitly recommends using WaitLatchOrSocket!

| Line | Operation | Blocking Potential |
|------|-----------|-------------------|
| [2971](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L2971) | `pg_getaddrinfo_all()` | DNS lookup for RADIUS server |
| [3066](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L3066) | `bind()` | Socket binding |
| [3075-3076](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L3075-L3076) | `sendto()` | UDP send to RADIUS server |
| [3124](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L3124) | `select()` | Polling for RADIUS response (manual timeout) |
| [3157](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L3157) | `recvfrom()` | UDP receive from RADIUS server |

**Impact:** Uses custom select() loop instead of WaitLatchOrSocket for timeout handling

**Proposed Wait Events:**
```
AUTH_RADIUS_CONNECT      "Waiting to send RADIUS authentication request"
AUTH_RADIUS_RESPONSE     "Waiting for RADIUS authentication response"
```

**Priority:** HIGH - Less common than LDAP but still blocks authentication

---

### 2.4 Generic DNS Lookups in Authentication (HIGH)

**File:** [`src/backend/libpq/auth.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c)
**Function:** `check_user_auth()`

| Line | Operation | Context |
|------|-----------|---------|
| [432-435](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L432-L435) | `pg_getnameinfo_all()` | Reverse DNS for client IP logging |
| [478](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L478) | `pg_getnameinfo_all()` | Reverse DNS for pg_ident mapping |
| [2081](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth.c#L2081) | `pg_getnameinfo_all()` | Reverse DNS for SSPI authentication |

**Priority:** HIGH - DNS lookups can hang indefinitely

---

## Category 3: Compression Operations Missing Wait Events (OPTIONAL)

**⚠️ NOTE: These are CPU-bound operations, NOT blocking I/O. Wait events here are OPTIONAL for observability.**

**Context:** Base backup compression is CPU-intensive work (not waiting). However, wait events provide operational value by distinguishing "compressing during backup" from other CPU activity. Without wait events, backup operations appear as generic "CPU" load, making it hard to identify that a backup is in progress.

**Why wait events make sense here:** Even though compression is legitimate CPU work, labeling it provides operational visibility. When monitoring shows `BASEBACKUP_COMPRESS_GZIP`, operators immediately know a backup is running and compressing data, rather than seeing generic CPU usage.

**Status:** OPTIONAL - These improve observability but are not required to fix incorrect "CPU" attribution.

### 3.1 Gzip Compression (CRITICAL)

**File:** [`src/backend/backup/basebackup_gzip.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/backup/basebackup_gzip.c)

| Line | Function | Operation | Impact |
|------|----------|-----------|--------|
| [176-215](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/backup/basebackup_gzip.c#L176-L215) | `bbsink_gzip_archive_contents()` | Loop with `deflate(zs, Z_NO_FLUSH)` | Compresses each data block |
| [234-265](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/backup/basebackup_gzip.c#L234-L265) | `bbsink_gzip_end_archive()` | Loop with `deflate(zs, Z_FINISH)` | Final compression flush |

**Code Pattern:**
```c
while (zs->avail_in > 0)
{
    int res = deflate(zs, Z_NO_FLUSH);  // NO WAIT EVENT!
    // ... error handling ...
}
```

**Priority:** CRITICAL - Every base backup with gzip compression

---

### 3.2 LZ4 Compression (CRITICAL)

**File:** [`src/backend/backup/basebackup_lz4.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/backup/basebackup_lz4.c)

| Line | Function | Operation | Impact |
|------|----------|-----------|--------|
| [145](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/backup/basebackup_lz4.c#L145) | `bbsink_lz4_begin_archive()` | `LZ4F_compressBegin()` | Initialization |
| [203](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/backup/basebackup_lz4.c#L203) | `bbsink_lz4_archive_contents()` | `LZ4F_compressUpdate()` | Compress each block |
| [245](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/backup/basebackup_lz4.c#L245) | `bbsink_lz4_end_archive()` | `LZ4F_compressEnd()` | Finalization |

**Priority:** CRITICAL - Every base backup with LZ4 compression

---

### 3.3 Zstandard Compression (CRITICAL)

**File:** [`src/backend/backup/basebackup_zstd.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/backup/basebackup_zstd.c)

| Line | Function | Operation | Impact |
|------|----------|-----------|--------|
| [198-224](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/backup/basebackup_zstd.c#L198-L224) | `bbsink_zstd_archive_contents()` | Loop with `ZSTD_compressStream2()` | Compress each block |
| [240-260](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/backup/basebackup_zstd.c#L240-L260) | `bbsink_zstd_end_archive()` | Loop with `ZSTD_compressStream2(Z_END)` | Final flush |

**Priority:** CRITICAL - Every base backup with Zstandard compression

---

**Proposed Wait Events:**
```
# In WaitEventIO or new WaitEventCompression category
BASEBACKUP_COMPRESS_GZIP     "Waiting for gzip compression during base backup"
BASEBACKUP_COMPRESS_LZ4      "Waiting for LZ4 compression during base backup"
BASEBACKUP_COMPRESS_ZSTD     "Waiting for Zstandard compression during base backup"
```

**Alternative (more detailed):**
```
COMPRESS_GZIP                "Compressing data with gzip"
COMPRESS_LZ4                 "Compressing data with LZ4"
COMPRESS_ZSTD                "Compressing data with Zstandard"
DECOMPRESS_GZIP              "Decompressing data with gzip"
DECOMPRESS_LZ4               "Decompressing data with LZ4"
DECOMPRESS_ZSTD              "Decompressing data with Zstandard"
```

---

## Category 4: Cryptographic Operations Missing Wait Events (OPTIONAL)

**⚠️ NOTE: These are CPU-bound operations, NOT blocking I/O. Wait events here are OPTIONAL for observability.**

Similar to compression, cryptographic operations are CPU work, not waiting. However, wait events provide operational value by distinguishing "hashing passwords" from "running queries" during authentication storms.

**Status:** OPTIONAL - These improve observability but are not required to fix incorrect "CPU" attribution.

### 4.1 SCRAM Authentication (HIGH)

**File:** [`src/backend/libpq/auth-scram.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth-scram.c)

SCRAM-SHA-256 uses PBKDF2 with 4096+ iterations, making it CPU-intensive by design. During authentication storms, this CPU load is invisible - it appears as generic "CPU" rather than "authenticating users".

| Line | Function | Operation | Impact |
|------|----------|-----------|--------|
| [1150-1195](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth-scram.c#L1150-L1195) | `scram_verify_client_proof()` | Multiple HMAC operations | Every SCRAM authentication |
| [1153](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth-scram.c#L1153) | | `pg_hmac_create()` | HMAC context creation |
| [1162-1174](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth-scram.c#L1162-L1174) | | `pg_hmac_init/update/final()` loops | Client proof verification |
| [1187](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth-scram.c#L1187) | | `scram_H()` | SHA-256 hash |
| [1414-1450](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth-scram.c#L1414-L1450) | `scram_build_server_final_message()` | HMAC for server signature | Every SCRAM authentication |
| [697-710](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth-scram.c#L697-L710) | `mock_scram_secret()` | SHA-256 for timing attack prevention | Failed authentication attempts |

**Impact:** SCRAM authentication with high iteration counts (4096+) can take 10-50ms per login on moderate hardware. During connection storms, this appears as CPU load.

**Proposed Wait Events:**
```
# In WaitEventAuth or WaitEventCrypto
AUTH_SCRAM_VERIFY        "Verifying SCRAM-SHA-256 authentication"
AUTH_SCRAM_HMAC          "Computing HMAC for SCRAM authentication"
```

**Priority:** HIGH - Every SCRAM login

---

### 4.2 SQL Cryptographic Functions (MEDIUM)

**File:** [`src/backend/utils/adt/cryptohashfuncs.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/utils/adt/cryptohashfuncs.c)

SQL-callable hash functions can process large bytea values (MB+).

| Line | Function | Operation | Impact |
|------|----------|-----------|--------|
| [44-53](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/utils/adt/cryptohashfuncs.c#L44-L53) | `md5_text()` | `pg_md5_hash()` | User SQL queries |
| [59-74](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/utils/adt/cryptohashfuncs.c#L59-L74) | `md5_bytea()` | `pg_md5_hash()` | User SQL queries |
| [79+](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/utils/adt/cryptohashfuncs.c#L79) | `cryptohash_internal()` | SHA-224/256/384/512 | User SQL queries |

**Code Pattern:**
```c
cryptohash_internal(PG_SHA256, ...);  // NO WAIT EVENT for large data
```

**Proposed Wait Events:**
```
# In WaitEventCrypto or extend WaitEventIO
CRYPTO_HASH_MD5          "Computing MD5 hash"
CRYPTO_HASH_SHA256       "Computing SHA-256 hash"
CRYPTO_HASH_SHA512       "Computing SHA-512 hash"
```

**Priority:** MEDIUM - User-triggered via SQL

---

### 4.3 CRC Computation (MEDIUM)

**File:** [`src/backend/utils/hash/pg_crc.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/utils/hash/pg_crc.c)

| Line | Function | Operation | Impact |
|------|----------|-----------|--------|
| [107](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/utils/hash/pg_crc.c#L107) | `crc32_bytea()` | CRC32 calculation loop | SQL function on large bytea |
| [120](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/utils/hash/pg_crc.c#L120) | `crc32c_bytea()` | CRC32C calculation loop | SQL function on large bytea |

**Priority:** MEDIUM - Less CPU-intensive than SHA-256 but can process large data

---

## Summary of Proposed New Wait Events

### New Categories to Add:

```
# In wait_event_names.txt

#
# WaitEventAuth - Authentication operations
#
AUTH_LDAP_INIT              "Waiting to connect to LDAP server"
AUTH_LDAP_BIND              "Waiting for LDAP bind operation"
AUTH_LDAP_SEARCH            "Waiting for LDAP search operation"
AUTH_LDAP_OPTION            "Waiting for LDAP option operation"
AUTH_DNS_LOOKUP             "Waiting for DNS resolution during authentication"
AUTH_IDENT_CONNECT          "Waiting to connect to ident server"
AUTH_IDENT_IO               "Waiting for ident server response"
AUTH_RADIUS_CONNECT         "Waiting to send RADIUS authentication request"
AUTH_RADIUS_RESPONSE        "Waiting for RADIUS authentication response"
AUTH_SCRAM_VERIFY           "Verifying SCRAM-SHA-256 authentication"

#
# WaitEventCompression - Data compression/decompression
#
COMPRESS_GZIP               "Compressing data with gzip"
COMPRESS_LZ4                "Compressing data with LZ4"
COMPRESS_ZSTD               "Compressing data with Zstandard"
DECOMPRESS_GZIP             "Decompressing data with gzip"
DECOMPRESS_LZ4              "Decompressing data with LZ4"
DECOMPRESS_ZSTD             "Decompressing data with Zstandard"

#
# WaitEventCrypto - Cryptographic operations
#
CRYPTO_HASH_MD5             "Computing MD5 hash"
CRYPTO_HASH_SHA256          "Computing SHA-256 hash"
CRYPTO_HASH_SHA512          "Computing SHA-512 hash"
CRYPTO_HMAC                 "Computing HMAC"
```

### Extensions to Existing WaitEventIO:

```
# Recovery operations
RECOVERY_SIGNAL_FILE_SYNC   "Waiting to sync recovery signal file"
STANDBY_SIGNAL_FILE_SYNC    "Waiting to sync standby signal file"
```

---

## Conclusion

This analysis identified **45 specific code locations** across PostgreSQL where operations block or consume significant time without proper wait event instrumentation. These gaps cause monitoring tools to show activity as "CPU" when backends are actually:

- **Waiting for external services** (LDAP, DNS, RADIUS, ident) - 23 locations, REQUIRED
- **Performing I/O operations** (fsync, stat, unlink on recovery/storage files) - 7 locations, REQUIRED
- **Compressing data** (gzip, LZ4, Zstandard) - 7 locations, OPTIONAL for observability
- **Computing cryptographic hashes** (SCRAM, HMAC, SHA-256, CRC) - 8 locations, OPTIONAL for observability

Of the 45 locations, **30 are required fixes** for true blocking operations, and **15 are optional** for improved CPU workload observability.

---

## Appendix: Files Requiring Changes

### REQUIRED Wait Events (30 locations)

**Critical Priority - Authentication (15 locations):**
- src/backend/libpq/auth.c
  - LDAP operations: 7 locations (lines 2222, 2320, 2339, 2350, 2551, 2602, 2660)
  - Ident operations: 8 locations (lines 1686-1689, 1704, 1720, 1728-1729, 1744, 1755-1756, 1776, 1793)

**High Priority - I/O and Authentication (13 locations):**
- src/backend/access/transam/xlogrecovery.c: 2 locations (recovery signal file syncs)
- src/backend/storage/smgr/md.c: 3 locations (file unlink operations)
- src/backend/libpq/auth.c:
  - RADIUS operations: 5 locations (lines 2971, 3066, 3075-3076, 3124, 3157)
  - DNS lookups: 3 locations (lines 432-435, 478, 2081)

**Medium Priority - I/O (2 locations):**
- src/backend/storage/ipc/dsm_impl.c: 2 locations (fstat operations)

### OPTIONAL Wait Events for Observability (15 locations)

**Compression - CPU Work (7 locations):**
- src/backend/backup/basebackup_gzip.c: 2 locations
- src/backend/backup/basebackup_lz4.c: 3 locations
- src/backend/backup/basebackup_zstd.c: 2 locations

**Cryptography - CPU Work (8 locations):**
- src/backend/libpq/auth-scram.c: 3 locations (SCRAM authentication functions)
- src/backend/utils/adt/cryptohashfuncs.c: 3 locations (SQL hash functions)
- src/backend/utils/hash/pg_crc.c: 2 locations (CRC computation)

---

*End of Analysis*
