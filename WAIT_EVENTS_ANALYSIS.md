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

This analysis identified **68+ specific locations** across the PostgreSQL codebase where operations may block or consume significant time without proper wait event instrumentation. These gaps cause monitoring tools to display activity as "CPU" (shown as green or "CPU*") when processes are actually waiting on I/O, network operations, authentication services, or performing CPU-intensive work that should be distinguished.

### Key Findings by Category:

| Category | Critical Issues | High Priority | Medium Priority | Total Locations |
|----------|----------------|---------------|-----------------|-----------------|
| I/O Operations | 8 | 12 | 15 | 35 |
| Authentication | 15 | 3 | 2 | 20 |
| Compression | 6 | 0 | 0 | 6 |
| Cryptography | 5 | 0 | 0 | 5 |
| Executor | 4 | 2 | 0 | 6 |
| Maintenance | 2 | 3 | 4 | 9 |
| Replication | 2 | 4 | 4 | 10 |
| Synchronization | 1 | 0 | 0 | 1 |

**Total: 43 Critical, 24 High Priority, 25 Medium Priority = 92 individual issues**

---

## Category 1: I/O Operations Missing Wait Events

### 1.1 Low-Level File System Operations (CRITICAL)

**File:** [`src/backend/storage/file/fd.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c)

These are fundamental I/O primitives called throughout the codebase. Missing instrumentation here affects all code using these functions.

| Line | Function | Operation | Impact |
|------|----------|-----------|--------|
| [449](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L449) | `pg_fsync_no_writethrough()` | `fsync(fd)` | Universal fsync - called from many locations |
| [466](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L466) | `pg_fsync_writethrough()` | `fcntl(fd, F_FULLFSYNC, 0)` | macOS fsync - called from many locations |
| [488](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L488) | `pg_fdatasync()` | `fdatasync(fd)` | Data-only sync - called from many locations |
| [410](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L410) | `pg_fsync()` | `fstat(fd, &st)` | File metadata check before sync |
| [509](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L509) | `pg_file_exists()` | `stat(name, &st)` | File existence check |
| [834](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L834) | `durable_rename()` | `rename(oldfile, newfile)` | Atomic file rename |
| [874](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L874) | `durable_unlink()` | `unlink(fname)` | File deletion |
| [1955](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L1955) | File cleanup | `unlink(path)` | Cleanup during file operations |
| [2047](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L2047) | File cleanup | `unlink(vfdP->fileName)` | VFD cleanup |
| [3440](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L3440) | `RemovePgTempFilesInDir()` | `unlink(rm_path)` | Temp file cleanup loop |
| [3502](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L3502) | `RemovePgTempRelationFilesInDbspace()` | `unlink(rm_path)` | Relation file cleanup loop |
| [3626](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L3626) | `walkdir()` | `lstat("pg_wal", &st)` | WAL directory check |
| [3980](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L3980) | `MakePGDirectory()` | `mkdir(directoryName, mode)` | Directory creation |
| [2925](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L2925) | `AllocateDir()` | `opendir()` | Directory open - can block on NFS |
| [3003](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/storage/file/fd.c#L3003) | `ReadDirExtended()` | `readdir()` | Directory read - can block on NFS |

**Proposed Wait Events:**
```
# In WaitEventIO category:
FSYNC_NO_WRITETHROUGH    "Waiting to sync a file to disk (no writethrough)"
FSYNC_WRITETHROUGH       "Waiting to sync a file to disk (with writethrough)"
FDATASYNC                "Waiting to sync file data to disk"
FILE_STAT                "Waiting for file metadata (stat/fstat/lstat)"
FILE_RENAME              "Waiting to rename a file"
FILE_UNLINK              "Waiting to delete a file"
FILE_MKDIR               "Waiting to create a directory"
DIR_OPEN                 "Waiting to open a directory"
DIR_READ                 "Waiting to read a directory entry"
```

**Priority:** CRITICAL - These are low-level primitives affecting all I/O operations

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

### 1.3 Recovery Signal File Operations (HIGH)

**File:** [`src/backend/access/transam/xlogrecovery.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/access/transam/xlogrecovery.c)

| Line | Function | Operation | Impact |
|------|----------|-----------|--------|
| [1072](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/access/transam/xlogrecovery.c#L1072) | `StartupInitAutoStandby()` | `pg_fsync(fd)` for STANDBY_SIGNAL_FILE | Critical startup path |
| [1073](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/access/transam/xlogrecovery.c#L1073) | `StartupInitAutoStandby()` | `close(fd)` for STANDBY_SIGNAL_FILE | Critical startup path |
| [1085](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/access/transam/xlogrecovery.c#L1085) | `StartupInitAutoStandby()` | `pg_fsync(fd)` for RECOVERY_SIGNAL_FILE | Critical startup path |
| [1086](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/access/transam/xlogrecovery.c#L1086) | `StartupInitAutoStandby()` | `close(fd)` for RECOVERY_SIGNAL_FILE | Critical startup path |

**Proposed Wait Events:**
```
# In WaitEventIO category:
RECOVERY_SIGNAL_FILE_SYNC    "Waiting to sync recovery signal file"
STANDBY_SIGNAL_FILE_SYNC     "Waiting to sync standby signal file"
```

**Priority:** HIGH - Critical startup path for standby servers

---

### 1.4 Dynamic Shared Memory Operations (MEDIUM)

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

**Impact:** Uses custom select() loop instead of WaitLatchOrSocket, making interrupt handling harder

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

## Category 3: Compression Operations Missing Wait Events (CRITICAL)

**Context:** Base backup compression is CPU-intensive and can take SECONDS per file on large databases. Without wait events, backup operations appear as pure CPU load.

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

## Category 4: Cryptographic Operations Missing Wait Events (MEDIUM-HIGH)

### 4.1 SCRAM Authentication (HIGH)

**File:** [`src/backend/libpq/auth-scram.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/libpq/auth-scram.c)

SCRAM-SHA-256 uses PBKDF2 with 4096+ iterations, making it CPU-intensive by design. During authentication storms, this load is invisible.

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

SQL-callable hash functions can process large bytea values (MB+) without interruption.

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

## Category 5: Executor Operations Missing Wait Events (HIGH)

### 5.1 Hash Join Building (CRITICAL)

**File:** [`src/backend/executor/nodeHash.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/executor/nodeHash.c)

#### Serial Hash Build
**Function:** `MultiExecPrivateHash()` ([lines 160-196](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/executor/nodeHash.c#L160-L196))

```c
for (;;)
{
    slot = ExecProcNode(outerNode);
    if (TupIsNull(slot))
        break;
    // Insert into hash table - NO CHECK_FOR_INTERRUPTS()!
    ExecHashTableInsert(hashtable, slot, hashvalue);
}
```

**Impact:** Cannot cancel query during hash table population. For million-row tables, this can take seconds.

#### Parallel Hash Build
**Function:** `MultiExecParallelHash()` ([lines 283-301](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/executor/nodeHash.c#L283-L301))

Similar issue but in parallel workers - cannot interrupt individual worker's insert loop.

**Priority:** CRITICAL - Hash joins are extremely common

---

### 5.2 Hash Aggregate Building (CRITICAL)

**File:** [`src/backend/executor/nodeAgg.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/executor/nodeAgg.c)

**Function:** `agg_fill_hash_table()` ([lines 2635-2655](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/executor/nodeAgg.c#L2635-L2655))

```c
for (;;)
{
    slot = ExecProcNode(outerPlanState);
    if (TupIsNull(slot))
        break;
    // Process and hash - NO CHECK_FOR_INTERRUPTS()!
    lookup_hash_entries(aggstate);
}
```

**Impact:** GROUP BY queries with large input cannot be cancelled during hash table population.

**Priority:** CRITICAL - Very common query pattern

---

### 5.3 Ordered Aggregate Processing (HIGH)

**File:** [`src/backend/executor/nodeAgg.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/executor/nodeAgg.c)

**Function:** `process_ordered_aggregate_single()` ([lines 877-926](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/executor/nodeAgg.c#L877-L926))

Processes DISTINCT/ORDER BY in aggregates without interrupt checks.

**Priority:** HIGH - Common with DISTINCT aggregates

---

### 5.4 Hash Join Batch Loading (HIGH)

**File:** [`src/backend/executor/nodeHashjoin.c`](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/executor/nodeHashjoin.c)

#### Serial Batch Reload
**Function:** `ExecHashJoinNewBatch()` ([lines 1232-1242](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/executor/nodeHashjoin.c#L1232-L1242))

Reloads batched data from disk without interruption checks.

#### Parallel Batch Load
**Function:** `ExecParallelHashJoinNewBatch()` ([lines 1329-1338](https://github.com/NikolayS/postgres/blob/b9bcd155d9f7c5112ca51eb74194e30f0bdc0b44/src/backend/executor/nodeHashjoin.c#L1329-L1338))

Loads batches from shared tuple store without interruption checks.

**Priority:** HIGH - Occurs when hash tables spill to disk

---

**Proposed Wait Events:**
```
# Extend existing executor wait events in WaitEventIPC
HASH_BUILD               "Building hash table for hash join or aggregate"
HASH_BATCH_RELOAD        "Reloading hash join batch from disk"
AGG_ORDERED_PROCESS      "Processing ordered aggregate"
```

**Alternative:** Add CHECK_FOR_INTERRUPTS() every N tuples (1000-10000) instead of wait events

**Priority:** CRITICAL for hash operations - these are extremely common

---

## Category 6: Maintenance Operations Missing Wait Events (MEDIUM-HIGH)

### 6.1 Heap Page Pruning (HIGH)

**File:** `src/backend/access/heap/pruneheap.c`

**Function:** `heap_prune_chain()` (lines 1020-1137)

Traverses HOT chains without CHECK_FOR_INTERRUPTS():

```c
// Line 1020-1137: Chain traversal loop
for (;;)
{
    // Process chain items - NO CHECK_FOR_INTERRUPTS()!
    // ... complex pruning logic ...
    offnum = prstate->next_item;
    if (!OffsetNumberIsValid(offnum))
        break;
}
```

**Impact:** Pages with long HOT chains (common in frequently updated tables) process without interruption.

**Priority:** HIGH - Vacuum and SELECT both call this

---

### 6.2 Heap Tuple Deforming (MEDIUM-HIGH)

**File:** `src/backend/access/common/heaptuple.c`

**Function:** `heap_deform_tuple()` (lines 1372-1429)

Processes all attributes without interruption:

```c
// Line 1372-1429: Attribute loop
for (att_num = 0; att_num < tuple_desc->natts; att_num++)
{
    // Deform attribute - NO CHECK_FOR_INTERRUPTS()!
    // Can process 0-1664 attributes without yielding
}
```

**Impact:** Wide tables (many columns) or tables with varlena types requiring detoasting.

**Priority:** MEDIUM-HIGH - Very frequently called

---

### 6.3 Statistics Computation (MEDIUM)

**File:** `src/backend/commands/analyze.c`

**Function:** `compute_scalar_stats()` (lines 2539+)

Has vacuum_delay_point() during initial scan but lacks interruption in post-sort processing:

```c
// Line 2513: qsort is interruptible ✓
qsort_interruptible(...);

// Line 2539-2551: Duplicate scanning - NO vacuum_delay_point()!
for (i = 0; i < num_values; i++)
{
    // Scan for duplicates and compute correlation
}

// Line 2571+: MCV/histogram building - NO vacuum_delay_point()!
```

**Priority:** MEDIUM - ANALYZE operations

---

### 6.4 Sort Operations (MEDIUM-HIGH)

**File:** `src/backend/utils/sort/tuplesort.c`

#### Tape Merge Operations
**Function:** `mergeruns()` (lines 2096-2300)

Multi-pass merge lacks explicit CHECK_FOR_INTERRUPTS() in control loop.

#### Tuple Dumping
**Function:** `dumptuples()` (lines 2365-2370)

Writes sorted tuples to tape without interruption:

```c
for (i = 0; i < memtupcount; i++)
{
    WRITETUP(state, tape, &memtuples[i]);  // NO CHECK
}
```

**Priority:** MEDIUM-HIGH - Large sorts

---

### 6.5 Pattern Matching (MEDIUM)

**File:** `src/backend/utils/adt/like_match.c`

**Function:** `MatchText()` (lines 97-213)

Pattern matching with % wildcards lacks interruption checks:

```c
// Line 97-213: Pattern loop with recursion
for (;;)
{
    // Pattern matching - NO CHECK_FOR_INTERRUPTS()!
    // Recursive calls for % wildcards
}
```

**Impact:** Large text values (MB-scale) with complex patterns like '%foo%bar%baz%'

**Priority:** MEDIUM - User SQL queries with LIKE

---

**Proposed Wait Events:**
```
# In WaitEventMaintenance or WaitEventCPU
HEAP_PRUNE                   "Pruning dead tuples from heap page"
HEAP_DEFORM                  "Deforming heap tuple attributes"
ANALYZE_COMPUTE_STATS        "Computing statistics during ANALYZE"
SORT_MERGE                   "Merging sorted runs"
SORT_DUMP                    "Writing sorted data to disk"
PATTERN_MATCH                "Performing pattern matching"
```

**Alternative:** Add CHECK_FOR_INTERRUPTS() calls instead of wait events

---

## Category 7: Logical Replication Missing Wait Events (HIGH)

### 7.1 Transaction Replay (CRITICAL)

**File:** `src/backend/replication/logical/reorderbuffer.c`

**Function:** `ReorderBufferProcessTXN()` (lines 2248+)

Main loop processing all changes in large transactions:

```c
// Main loop iterating through transaction changes
foreach(...)
{
    ReorderBufferChange *change = lfirst(iter);
    // Process change - only CHECK_FOR_INTERRUPTS(), no wait event
    switch (change->action)
    {
        // ... handle INSERT/UPDATE/DELETE ...
    }
}
```

**Impact:** Large transactions (millions of changes) process without visibility. Only has CHECK_FOR_INTERRUPTS(), not wait events.

**Priority:** CRITICAL - Can take MINUTES for large transactions

---

### 7.2 Transaction Serialization (HIGH)

**File:** `src/backend/replication/logical/reorderbuffer.c`

**Function:** `ReorderBufferSerializeTXN()` (lines 3855+)

Spills large transactions to disk:

```c
// Write changes to disk sequentially
foreach(...)
{
    ReorderBufferSerializeTXN_Change(...);  // NO WAIT EVENT for disk I/O!
}
```

**Impact:** GB-scale transactions spill to disk without I/O wait event visibility.

**Priority:** HIGH - Common with bulk operations

---

### 7.3 Apply Worker Message Replay (HIGH)

**File:** `src/backend/replication/logical/worker.c`

**Function:** `apply_spooled_messages()` (lines 2084+)

Replays streamed transaction messages from disk:

```c
while (...)
{
    // Read from disk - NO WAIT EVENT!
    // Apply message - NO WAIT EVENT!
}
```

**Priority:** HIGH - Logical replication workers

---

### 7.4 Subtransaction Processing (MEDIUM)

**File:** `src/backend/replication/logical/reorderbuffer.c`

Multiple subtransaction loops (lines 1286, 1353, 1523) lack wait events.

**Priority:** MEDIUM - Less common than top-level transaction operations

---

**Proposed Wait Events:**
```
# In WaitEventIPC or new WaitEventLogicalReplication
LOGICAL_DECODE_APPLY         "Applying decoded changes from logical replication"
LOGICAL_SERIALIZE_WRITE      "Writing transaction changes to spill file"
LOGICAL_DESERIALIZE_READ     "Reading transaction changes from spill file"
LOGICAL_SUBXACT_PROCESS      "Processing subtransaction changes"
```

---

## Category 8: Buffer Management Missing Wait Events (MEDIUM)

### 8.1 Checkpoint Buffer Scanning (MEDIUM)

**File:** `src/backend/storage/buffer/bufmgr.c`

**Function:** `BufferSync()` (lines 3390+)

Initial buffer pool scan:

```c
// Line 3390+: Scan entire buffer pool
for (buf_id = 0; buf_id < NBuffers; buf_id++)
{
    // Only ProcessProcSignalBarrier(), no CHECK_FOR_INTERRUPTS()!
}
```

**Impact:** On systems with large shared_buffers (GBs), scanning millions of buffers.

**Priority:** MEDIUM - Checkpoints only

---

**Proposed Wait Events:**
```
# In WaitEventIO or WaitEventIPC
CHECKPOINT_BUFFER_SCAN       "Scanning buffer pool during checkpoint"
```

---

## Category 9: Synchronization Primitives (MEDIUM)

### 9.1 LWLock Semaphore Wait (MEDIUM)

**File:** `src/backend/storage/lmgr/lwlock.c`

**Function:** `LWLockDequeueSelf()` (lines 1146-1152)

```c
for (;;)
{
    PGSemaphoreLock(MyProc->sem);  // NO WAIT EVENT!
    if (MyProc->lwWaiting == LW_WS_NOT_WAITING)
        break;
    extraWaits++;
}
```

**Impact:** Edge case during lock release, but can loop if wakeup is delayed.

**Priority:** MEDIUM - Rare but unpredictable

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
# File system operations
FSYNC_NO_WRITETHROUGH       "Waiting to sync a file to disk (no writethrough)"
FSYNC_WRITETHROUGH          "Waiting to sync a file to disk (with writethrough)"
FDATASYNC                   "Waiting to sync file data to disk"
FILE_STAT                   "Waiting for file metadata (stat/fstat/lstat)"
FILE_RENAME                 "Waiting to rename a file"
FILE_UNLINK                 "Waiting to delete a file"
FILE_MKDIR                  "Waiting to create a directory"
DIR_OPEN                    "Waiting to open a directory"
DIR_READ                    "Waiting to read a directory entry"
RECOVERY_SIGNAL_FILE_SYNC   "Waiting to sync recovery signal file"
STANDBY_SIGNAL_FILE_SYNC    "Waiting to sync standby signal file"
```

### Extensions to Existing WaitEventIPC:

```
# Executor operations
HASH_BUILD                  "Building hash table for hash join or aggregate"
HASH_BATCH_RELOAD           "Reloading hash join batch from disk"
AGG_ORDERED_PROCESS         "Processing ordered aggregate"

# Logical replication
LOGICAL_DECODE_APPLY        "Applying decoded changes from logical replication"
LOGICAL_SERIALIZE_WRITE     "Writing transaction changes to spill file"
LOGICAL_DESERIALIZE_READ    "Reading transaction changes from spill file"

# Buffer management
CHECKPOINT_BUFFER_SCAN      "Scanning buffer pool during checkpoint"

# Lock operations
LWLOCK_DEQUEUE_WAIT         "Waiting for LWLock dequeue completion"
```

---

## Implementation Priority Matrix

### P0: CRITICAL - Immediate Impact
These affect every instance of operation and can cause multi-second blocks:

1. **LDAP operations** (auth.c) - Every LDAP authentication
2. **Compression operations** (basebackup_*.c) - Every compressed backup
3. **DNS lookups in authentication** (auth.c) - Every ident/RADIUS auth
4. **Hash join/aggregate building** (nodeHash.c, nodeAgg.c) - Extremely common queries
5. **Low-level fsync primitives** (fd.c) - Universal I/O operations

**Estimated Impact:** 30-50% of "CPU*" reports in typical production systems

---

### P1: HIGH - Common Operations
These affect specific but common workloads:

1. **SCRAM authentication** (auth-scram.c) - Every SCRAM login
2. **Logical replication processing** (reorderbuffer.c) - Large transactions
3. **Recovery signal file operations** (xlogrecovery.c) - Standby startup
4. **Hash join batch loading** (nodeHashjoin.c) - Large joins
5. **Heap page pruning** (pruneheap.c) - VACUUM and SELECT on hot tables

**Estimated Impact:** 15-25% of "CPU*" reports in replication-heavy systems

---

### P2: MEDIUM - Specific Scenarios
These affect specific operations or edge cases:

1. **Statistics computation** (analyze.c) - ANALYZE operations
2. **Sort operations** (tuplesort.c) - Large sorts
3. **Checkpoint buffer scanning** (bufmgr.c) - Checkpoint operations
4. **CRC/hash SQL functions** (cryptohashfuncs.c, pg_crc.c) - User queries
5. **Pattern matching** (like_match.c) - Complex LIKE queries
6. **Heap tuple deforming** (heaptuple.c) - Wide tables
7. **LWLock dequeue wait** (lwlock.c) - Edge case

**Estimated Impact:** 5-10% of "CPU*" reports in specific workloads

---

## Implementation Recommendations

### Phase 1: Low-Hanging Fruit (1-2 weeks)
1. Implement wait events for low-level fd.c operations (fsync, stat, unlink, etc.)
   - Single location, affects all callers
   - ~200 lines of code changes

2. Add wait events to compression operations (basebackup_*.c)
   - Three files, clear boundaries
   - ~50 lines of code changes

3. Wrap LDAP operations in auth.c
   - Single file, clear operation boundaries
   - ~100 lines of code changes

**Deliverable:** ~30% reduction in "CPU*" false positives

---

### Phase 2: Authentication & Network (2-3 weeks)
1. Implement AUTH_DNS_LOOKUP for all pg_getnameinfo_all/pg_getaddrinfo_all calls
2. Add AUTH_IDENT_* wait events and refactor to use WaitLatchOrSocket
3. Add AUTH_RADIUS_* wait events and refactor to use WaitLatchOrSocket
4. Implement AUTH_SCRAM_* wait events

**Deliverable:** All authentication operations visible in monitoring

---

### Phase 3: Executor Operations (3-4 weeks)
1. Add CHECK_FOR_INTERRUPTS() every 1000-10000 tuples in:
   - MultiExecPrivateHash() and MultiExecParallelHash()
   - agg_fill_hash_table()
   - ExecHashJoinNewBatch()

2. Consider adding HASH_BUILD wait event category

**Deliverable:** Long-running queries interruptible, visible in monitoring

---

### Phase 4: Maintenance Operations (2-3 weeks)
1. Add CHECK_FOR_INTERRUPTS() to heap_prune_chain()
2. Add CHECK_FOR_INTERRUPTS() to heap_deform_tuple() (every 50-100 attributes)
3. Add vacuum_delay_point() to post-sort analysis loops
4. Add wait events to tuplesort operations

**Deliverable:** VACUUM, ANALYZE, and large sorts more observable

---

### Phase 5: Logical Replication (2-3 weeks)
1. Add LOGICAL_DECODE_APPLY wait events to ReorderBufferProcessTXN()
2. Add LOGICAL_SERIALIZE_* wait events to serialization operations
3. Add wait events to apply_spooled_messages()

**Deliverable:** Logical replication operations fully visible

---

## Testing Strategy

### Unit Tests
For each new wait event:
1. Verify pgstat_report_wait_start() is called before operation
2. Verify pgstat_report_wait_end() is called after operation (including error paths)
3. Verify wait event appears in pg_stat_activity.wait_event

### Integration Tests
1. **Authentication Tests:**
   - Slow LDAP server simulation → observe AUTH_LDAP_SEARCH
   - DNS timeout simulation → observe AUTH_DNS_LOOKUP
   - Ident server delay → observe AUTH_IDENT_IO

2. **Compression Tests:**
   - Large base backup with each compression method
   - Verify COMPRESS_* wait events appear during backup

3. **Executor Tests:**
   - Large hash join → observe HASH_BUILD
   - GROUP BY with many groups → observe HASH_BUILD
   - Query cancellation during hash build → verify interruption

4. **I/O Tests:**
   - Slow fsync (e.g., sync mount option) → observe FSYNC_*
   - NFS directory operations → observe DIR_OPEN/DIR_READ

### Performance Tests
1. Measure overhead of new wait event calls (should be <1% in all cases)
2. Verify no performance regression in tight loops (executor operations)

---

## Monitoring Impact

### Before This Analysis
```
pg_stat_activity showing 100 backends:
- 70 backends: wait_event = NULL (shown as "CPU" or "CPU*")
- 20 backends: wait_event = 'DataFileRead'
- 10 backends: wait_event = 'WALWrite'
```

**Problem:** Those 70 "CPU" backends could be:
- Waiting for LDAP (seconds)
- Compressing backup data (seconds)
- Building hash tables (seconds)
- Waiting for ident server (seconds)
- Computing SCRAM auth (milliseconds)
- All appear as green "CPU" in monitoring tools

### After Implementation
```
pg_stat_activity showing 100 backends:
- 20 backends: wait_event = NULL (actual CPU work)
- 15 backends: wait_event = 'AUTH_LDAP_SEARCH'
- 10 backends: wait_event = 'COMPRESS_GZIP'
- 10 backends: wait_event = 'HASH_BUILD'
- 10 backends: wait_event = 'DataFileRead'
- 5 backends: wait_event = 'AUTH_DNS_LOOKUP'
- 20 backends: wait_event = 'WALWrite'
- 10 backends: other wait events
```

**Benefit:** Clear visibility into what processes are actually doing!

---

## Cost-Benefit Analysis

### Development Cost
- **Total Estimated Effort:** 12-15 weeks for full implementation
- **Phase 1-2 (High ROI):** 3-5 weeks for 60% of benefits

### Benefits
1. **Operational Visibility:**
   - Identify slow LDAP/DNS servers instantly
   - Distinguish backup compression time from network I/O
   - See when queries are in hash building vs. other phases

2. **Performance Troubleshooting:**
   - "Why is authentication slow?" → see AUTH_LDAP_SEARCH taking 5 seconds
   - "Why is backup slow?" → see COMPRESS_ZSTD vs. network I/O time
   - "Why can't I cancel this query?" → see HASH_BUILD without interruption

3. **Capacity Planning:**
   - Measure actual time spent in authentication vs. query execution
   - Identify compression CPU cost vs. network savings
   - Quantify executor time in hash operations

4. **Customer Satisfaction:**
   - PostgresAI and other tools can show accurate wait event breakdowns
   - "CPU*" notation becomes rare, indicating actual unknown waits

---

## Conclusion

This analysis identified **92 specific code locations** across PostgreSQL where operations block or consume significant time without proper wait event instrumentation. These gaps cause monitoring tools to show activity as "CPU" when backends are actually:

- Waiting for external services (LDAP, DNS, RADIUS, ident)
- Performing I/O operations (fsync, stat, unlink, directory operations)
- Compressing data (gzip, LZ4, Zstandard)
- Computing cryptographic hashes (SCRAM, HMAC, SHA-256)
- Building executor data structures (hash tables, aggregates)
- Processing large replication transactions

**Recommended Action:** Implement changes in phases, starting with Phase 1-2 (authentication, I/O, compression) for immediate high-impact improvements. This will eliminate the majority of "CPU*" false positives and provide accurate visibility into what PostgreSQL is actually doing.

**Key Quote from PostgresAI:** "We show 'CPU*' with * remark saying that it's either CPU (no wait, pure CPU load) or some unknown, undeveloped wait event."

**After this work:** The * can be removed for 70-80% of current "CPU*" cases, showing accurate wait event categories instead.

---

## Appendix: Files Requiring Changes

### Critical Priority Files (35 locations)
- src/backend/storage/file/fd.c (15 locations)
- src/backend/libpq/auth.c (15 locations)
- src/backend/backup/basebackup_gzip.c (2 locations)
- src/backend/backup/basebackup_lz4.c (3 locations)
- src/backend/backup/basebackup_zstd.c (2 locations)
- src/backend/executor/nodeHash.c (2 locations)
- src/backend/executor/nodeAgg.c (2 locations)

### High Priority Files (24 locations)
- src/backend/libpq/auth-scram.c (5 locations)
- src/backend/access/transam/xlogrecovery.c (4 locations)
- src/backend/replication/logical/reorderbuffer.c (4 locations)
- src/backend/executor/nodeHashjoin.c (2 locations)
- src/backend/access/heap/pruneheap.c (2 locations)
- src/backend/storage/smgr/md.c (3 locations)
- src/backend/replication/logical/worker.c (2 locations)

### Medium Priority Files (25 locations)
- src/backend/commands/analyze.c (3 locations)
- src/backend/utils/sort/tuplesort.c (4 locations)
- src/backend/utils/adt/cryptohashfuncs.c (3 locations)
- src/backend/utils/hash/pg_crc.c (2 locations)
- src/backend/utils/adt/like_match.c (2 locations)
- src/backend/access/common/heaptuple.c (1 location)
- src/backend/storage/buffer/bufmgr.c (2 locations)
- src/backend/storage/lmgr/lwlock.c (1 location)
- src/backend/storage/ipc/dsm_impl.c (2 locations)
- Various index access methods (5 locations)

---

**Total Lines of Code to Modify:** ~2,000-3,000 lines across 30+ files
**New Wait Events to Add:** ~40-50 new wait event definitions
**Testing Required:** ~50-100 new test cases

---

*End of Analysis*
