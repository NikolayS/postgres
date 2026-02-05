# Additional PostgreSQL Wait Event Coverage Gaps

This document extends the analysis from https://gaps.wait.events/ with newly discovered gaps found through comprehensive source code analysis.

## Executive Summary

Beyond the **39 gaps** already documented (32 authentication + 7 I/O), this analysis identified **239+ additional locations** across multiple subsystems where PostgreSQL operations can block without proper wait event instrumentation.

| Category | Known | New Gaps | Priority |
|----------|-------|----------|----------|
| Sleep/Delay Operations | 0 | 30+ | CRITICAL |
| Shared Memory/IPC | 0 | 35+ | CRITICAL |
| Network Operations | 0 | 42+ | CRITICAL |
| Procedural Languages | 0 | 25+ | CRITICAL |
| JIT Compilation | 0 | 8 | CRITICAL |
| TOAST/Large Objects | 0 | 16+ | HIGH |
| Compression Libraries | 0 | 12+ | HIGH |
| File I/O Operations | 0 | 50+ | HIGH |
| Logging/Error Handling | 0 | 20+ | HIGH |
| Contrib Modules | 0 | 25+ | HIGH |
| Configuration Loading | 0 | 30+ | MEDIUM |
| Recovery/Startup | 0 | 15+ | MEDIUM |
| MVCC/Snapshots | 0 | 70+ | MEDIUM |
| Data Type Operations | 0 | 30+ | MEDIUM |
| Parallel Query | 0 | 2 | MEDIUM |

---

## 1. CRITICAL: Sleep/Delay Operations (30+ gaps)

### pg_usleep() calls WITHOUT wait event instrumentation

#### Backend Daemons - Error Recovery

| File | Line | Function | Duration | Purpose |
|------|------|----------|----------|---------|
| walwriter.c | 194 | Error recovery | 1 second | Post-error cooling |
| checkpointer.c | 335 | Error recovery | 1 second | Post-error cooling |
| checkpointer.c | 1148 | File error | 0.1 second | Retry checkpoint file |
| bgwriter.c | 201 | Error recovery | 1 second | Post-error cooling |
| autovacuum.c | 398 | Launcher startup | Configurable | PostAuthDelay |
| autovacuum.c | 514 | Error recovery | 1 second | Prevent log flooding |
| autovacuum.c | 640 | Fork failure | 1 second | Retry backoff |
| autovacuum.c | 1599 | Worker startup | Configurable | PostAuthDelay |
| pgarch.c | 475, 507 | Archive retry | 1 second | WAL archiving backoff |

#### Backend Initialization

| File | Line | Function | Purpose |
|------|------|----------|---------|
| postinit.c | 979, 1202 | Backend init | PostAuthDelay |
| backend_startup.c | 162 | Backend startup | PreAuthDelay |
| bgworker.c | 763 | BGW main | PostAuthDelay |

#### Lock and Synchronization

| File | Line | Function | Duration | Purpose |
|------|------|----------|----------|---------|
| lmgr.c | 722, 765 | LockWaitCancel | 1ms | Lock state polling |
| standby.c | 400 | Lock conflict | 5ms | Lock retry |
| standby.c | 590 | LSN replay | 10ms | Replay completion poll |
| procarray.c | 3789 | Group update | 100ms | Process array retry |
| fd.c | 2184, 2315 | Transient file | 1ms | Resource exhaustion retry |

#### Replication

| File | Line | Function | Duration | Purpose |
|------|------|----------|----------|---------|
| walsender.c | 3937 | WalSndDone | 10ms | Confirmation poll |
| xlogutils.c | 950 | WAL read | 1ms | Future WAL polling |

#### Network

| File | Line | Function | Duration | Purpose |
|------|------|----------|----------|---------|
| pqcomm.c | 813 | Accept rate | 0.1 second | FD exhaustion backoff |
| auth.c | 3141 | RADIUS auth | Dynamic | select() for response |

---

## 2. CRITICAL: Shared Memory and IPC (35+ gaps)

### Semaphore Operations (BLOCKING)

| File | Line | Operation | Impact |
|------|------|-----------|--------|
| posix_sema.c | 322 | `sem_wait()` | Blocks indefinitely |
| posix_sema.c | 347 | `sem_post()` | Signal semaphore |

### Shared Memory Operations

| File | Line | Operation | Impact |
|------|------|-----------|--------|
| sysv_shmem.c | 156, 186, 783, 907 | `shmget()` | Allocate shared memory |
| sysv_shmem.c | 255, 411 | `shmat()` | Attach shared memory |
| sysv_shmem.c | 289, 323, 838, 974 | `shmdt()` | Detach shared memory |
| sysv_shmem.c | 207, 300, 360 | `shmctl()` | Control shared memory |
| dsm_impl.c | 509, 533 | shmget/shmdt | DSM allocation |

### Memory Mapping Operations

| File | Line | Operation | Impact |
|------|------|-----------|--------|
| sysv_shmem.c | 622, 646 | `mmap()` | Memory mapping |
| sysv_shmem.c | 680, 986 | `munmap()` | Memory unmapping |
| fd.c | 639, 656 | mmap/munmap | Data sync |
| fd.c | 647 | `msync()` | **BLOCKS for I/O** |
| method_io_uring.c | 183, 215 | mmap/munmap | io_uring setup |
| dsm_impl.c | 227, 315, 808, 918 | mmap/munmap | DSM operations |

### Pipe Operations

| File | Line | Operation | Context |
|------|------|-----------|---------|
| waiteventset.c | 295 | `pipe()` | Event set init |
| postmaster.c | 4603 | `pipe()` | Postmaster pipes |
| syslogger.c | 623 | `pipe()` | Syslogger pipes |

### Process Operations (BLOCKING)

| File | Line | Operation | Impact |
|------|------|-----------|--------|
| fork_process.c | 66 | `fork()` | Process creation |
| postmaster.c | 2253 | `waitpid()` | Child reaping |

---

## 3. CRITICAL: Network Operations (42+ gaps)

### Socket Creation and Setup

| File | Line | Operation |
|------|------|-----------|
| pqcomm.c | 541 | `socket()` |
| pqcomm.c | 608 | `bind()` |
| pqcomm.c | 645 | `listen()` |
| pqcomm.c | 798 | `accept()` |
| auth.c | 1745, 3066 | `socket()` (ident, RADIUS) |
| auth.c | 1761, 3083 | `bind()` |
| auth.c | 1772 | `connect()` |

### Data Transfer

| File | Line | Operation | Context |
|------|------|-----------|---------|
| auth.c | 1793, 3092 | `send()` | Ident/RADIUS |
| auth.c | 1810 | `recv()` | Ident response |
| auth.c | 3174 | `recvfrom()` | RADIUS response |
| postmaster.c | 3654 | `send()` | Fork failure report |

### DNS Resolution (BLOCKING)

| File | Line | Operation | Impact |
|------|------|-----------|--------|
| ip.c | 68 | `getaddrinfo()` | Forward lookup |
| ip.c | 130 | `getnameinfo()` | Reverse lookup |
| hba.c | 1091 | `pg_getnameinfo_all()` | Auth hostname check |
| hba.c | 1115 | `getaddrinfo()` | Forward verification |

---

## 4. CRITICAL: Procedural Languages (25+ gaps)

**Impact**: All external PL code execution is completely invisible to monitoring.

### PL/Python (`src/pl/plpython/`)

| Location | Operation | Impact |
|----------|-----------|--------|
| `plpy_main.c:73` | `Py_Initialize()` | Interpreter startup |
| `plpy_procedure.c:390` | `Py_CompileString()` | Code compilation |
| `plpy_exec.c:1111` | `PyEval_EvalCode()` | **Every function call** |

User Python code can perform network I/O, file operations, external imports, database calls.

### PL/Perl (`src/pl/plperl/plperl.c`)

| Line | Operation | Impact |
|------|-----------|--------|
| 811 | `perl_construct()` | Interpreter creation |
| 848 | `perl_parse()` | Parser initialization |
| 855 | `perl_run()` | Startup code execution |
| 1025 | `eval_pv()` | Init script |
| 2237 | `call_sv()` | **Every function call** |

### PL/Tcl (`src/pl/tcl/pltcl.c`)

| Line | Operation | Impact |
|------|-----------|--------|
| 441 | `Tcl_CreateInterp()` | Interpreter creation |
| 938, 1267, 1350, 1781, 2585, 2996 | `Tcl_EvalObjEx()` / `Tcl_EvalEx()` | Code execution |

---

## 5. CRITICAL: JIT Compilation (8 gaps)

**Impact**: LLVM JIT compilation appears as unexplained "CPU" activity.

### File: `src/backend/jit/llvm/llvmjit.c`

| Location | Operation | Phase |
|----------|-----------|-------|
| Line 720-727 | `llvm_inline()` | Inlining (timed but no wait event) |
| Line 742-746 | `llvm_optimize_module()` | Optimization passes |
| Line 768-799 | `LLVMOrcLLJITAddLLVMIRModuleWithRT()` | Code emission |
| Line 363-410 | `llvm_get_function()` | Symbol lookup + lazy compilation |
| Line 693 | `LLVMRunPasses()` | LLVM ≥17: Full optimization |
| Lines 645-648, 666 | `LLVMRunPassManager()` | LLVM <17: Passes |

**Note**: Timing infrastructure exists (`inlining_counter`, `optimization_counter`, `emission_counter`) but is NOT connected to wait events.

---

## 6. HIGH: TOAST and Large Object Operations (16+ gaps)

### TOAST Operations

| File | Line | Operation | Impact |
|------|------|-----------|--------|
| toast_internals.c | 119, 314, 331 | `toast_save_datum()` | Chunk-by-chunk writes |
| detoast.c | 343, 372-376 | `toast_fetch_datum()` | Table open, fetch |
| detoast.c | 396, 452-457 | `toast_fetch_datum_slice()` | Partial retrieval |
| toast_internals.c | 376 | `toast_delete_datum()` | Scan and delete |
| heaptoast.c | 96, 184-271 | `heap_toast_insert_or_update()` | Compression loops |
| detoast.c | 116, 123 | `detoast_attr()` | Fetch + decompress |

### Large Object Operations

| File | Line | Operation | Impact |
|------|------|-----------|--------|
| inv_api.c | 450, 486 | `inv_read()` | Systable scan, fetch |
| inv_api.c | 543, 604 | `inv_write()` | heap_insert, index_insert loop |
| inv_api.c | 738 | `inv_truncate()` | Catalog operations |
| be-fsstubs.c | 154 | `lo_read()` | Calls inv_read |
| be-fsstubs.c | 182 | `lo_write()` | Calls inv_write |
| be-fsstubs.c | 87, 126 | `lo_open()/lo_close()` | Descriptor ops |

---

## 7. HIGH: Compression Libraries (12+ gaps)

### PGLZ (Built-in)

| File | Line | Operation |
|------|------|-----------|
| xloginsert.c | 996 | `pglz_compress()` - WAL |
| xlogreader.c | 2109 | `pglz_decompress()` - WAL |
| toast_compression.c | 63, 91 | TOAST compress/decompress |

### Zlib

| File | Line | Operation |
|------|------|-----------|
| pgp-compress.c | 122, 152, 278 | `deflate()`, `inflate()` |
| basebackup_gzip.c | 198, 249 | `deflate()` |
| compress_gzip.c | 120, 206 | pg_dump compress |

### LZ4

| File | Line | Operation |
|------|------|-----------|
| xloginsert.c | 1001 | `LZ4_compress_default()` |
| xlogreader.c | 2116 | `LZ4_decompress_safe()` |

### ZSTD

| File | Line | Operation |
|------|------|-----------|
| xloginsert.c | 1012 | `ZSTD_compress()` |
| xlogreader.c | 2130 | `ZSTD_decompress()` |

---

## 8. HIGH: File I/O Operations (50+ gaps)

### Directory Operations

| File | Line | Operation |
|------|------|-----------|
| fd.c | 831 | `rename()` in durable_rename |
| fd.c | 871 | `unlink()` in durable_unlink |
| fd.c | 1286, 1978 | `close()` in LruDelete/FileClose |
| fd.c | 2021, 2027 | `stat()`, `unlink()` in FileClose |
| fd.c | 3421, 3483 | `unlink()` in RemoveDirectory |
| reinit.c | 80-355 | 18+ `AllocateDir/ReadDir/FreeDir` |

### Generic File Operations

| File | Line | Operation |
|------|------|-----------|
| genfile.c | 116, 127, 138-201 | `AllocateFile`, `fseeko`, `fread` |
| genfile.c | 430, 583-627 | `stat`, `AllocateDir`, `ReadDir` |
| slru.c | 1824-1844 | Directory scanning |

### Contrib Module I/O

| File | Lines | Operations |
|------|-------|------------|
| pg_stat_statements.c | 588-2660 | 15+ fread/fwrite/unlink |
| autoprewarm.c | 622-801 | fprintf/unlink/rename |
| basebackup_to_shell.c | 232-287 | Pipe I/O |

---

## 9. HIGH: Logging and Error Handling (20+ gaps)

### Syslog Operations

| File | Line | Operation | Impact |
|------|------|-----------|--------|
| elog.c | 2470-2484 | `syslog()` x4 calls | Blocks on syslog daemon |

### Windows Event Log

| File | Line | Operation | Impact |
|------|------|-----------|--------|
| elog.c | 2572, 2587 | `ReportEventW/A()` | Blocks on event log service |

### Log File Operations

| File | Line | Operation |
|------|------|-----------|
| syslogger.c | 1118 | `fwrite()` to log file |
| syslogger.c | 1229, 1496 | `fopen()` log creation |
| syslogger.c | 776-1348 | `fclose()` x5 |
| syslogger.c | 1486, 1590 | `unlink()` old logs |
| syslogger.c | 1519-1557 | `fprintf()`, `rename()` metadata |

### Error Pipe Communication

| File | Line | Operation | Impact |
|------|------|-----------|--------|
| elog.c | 3506, 3516 | `write()` to syslogger pipe | Blocks if pipe full |
| elog.c | 582, 608, 2665 | `fflush()`, `write()` stderr | Blocks on slow output |

---

## 10. HIGH: Contrib Modules (25+ gaps)

### pg_stat_statements

| Line | Operation | Context |
|------|-----------|---------|
| 588 | `unlink()` | File deletion |
| 622-679 | `fread()` x multiple | Query text reading |
| 699-835 | `fwrite()`, `unlink()` | Stats dump/cleanup |
| 2303-2409 | `pg_pwrite()`, `read()` | Query text ops |

### pg_prewarm/autoprewarm

| Line | Operation | Context |
|------|-----------|---------|
| 744, 762 | `fprintf()` | Prewarm file writing |
| 750-801 | `unlink()`, `durable_rename()` | File operations |
| 622-643 | `read_stream_*()` | Prefetch I/O |

### basebackup_to_shell

| Line | Operation | Context |
|------|-----------|---------|
| 268 | `OpenPipeStream()` | popen() to shell |
| 287 | `fwrite()` | Backup data to pipe |
| 232 | `ClosePipeStream()` | pclose() |

### file_fdw (ALL operations uninstrumented)

| Line | Operation |
|------|-----------|
| 665, 897 | `stat()` |
| 702 | `BeginCopyFrom()` |
| 769 | `NextCopyFrom()` per-row I/O |
| 831 | `BeginCopyFrom()` re-scan |
| 1218-1325 | ANALYZE sampling |

### Other Contrib

| Module | File | Operation |
|--------|------|-----------|
| basic_archive | basic_archive.c | `fsync_fname()`, `copy_file()` |
| sepgsql | selinux.c | `security_compute_av*()` |
| passwordcheck | passwordcheck.c | `FascistCheck()` |

---

## 11. MEDIUM: Configuration Loading (30+ gaps)

### GUC Loading

| File | Line | Operation |
|------|------|-----------|
| guc.c | 4638 | `AllocateFile()` - pg_autoconf.conf |
| guc.c | 5536, 5624 | Config param files (EXEC_BACKEND) |
| guc.c | 5648-5654 | `fread()` x4 |
| guc-file.l | 239 | `AllocateFile()` - postgresql.conf |
| conffiles.c | 95-133 | `AllocateDir`, `ReadDir`, `stat` |

### Authentication Config

| File | Line | Operation |
|------|------|-----------|
| hba.c | 616 | `AllocateFile()` - pg_hba.conf |
| hba.c | 688-755 | Lexer fread operations |
| hba.c | 2652 | HBA file loading |
| hba.c | 3048 | Ident file loading |

### Statistics Files

| File | Line | Operation |
|------|------|-----------|
| pgstat.c | 1603-1727 | Stats file write (fputc, fwrite) |
| pgstat.c | 1798-1831 | Stats file read (fgetc, fread) |

### SSL Certificates

| File | Line | Operation |
|------|------|-----------|
| be-secure-openssl.c | 146 | `SSL_CTX_use_certificate_chain_file()` |
| be-secure-openssl.c | 163 | `SSL_CTX_use_PrivateKey_file()` |
| be-secure-openssl.c | 332-374 | CA/CRL file loading |
| be-secure-openssl.c | 1058-1067 | DH parameters file |

---

## 12. MEDIUM: Recovery and Startup (15+ gaps)

### Backup Label Reading

| File | Line | Operation |
|------|------|-----------|
| xlogrecovery.c | 1252 | `AllocateFile()` - backup_label |
| xlogrecovery.c | 1268-1347 | 8x `fscanf()` calls |

### Tablespace Map Reading

| File | Line | Operation |
|------|------|-----------|
| xlogrecovery.c | 1387 | `AllocateFile()` - tablespace_map |
| xlogrecovery.c | 1405-1450 | `fgetc()` character loop |

### WAL Polling

| File | Line | Operation |
|------|------|-----------|
| xlogutils.c | 950 | `pg_usleep(1000L)` - WAL wait |
| xlog.c | 5616 | `pg_usleep(60000000L)` - Debug delay |

---

## 13. MEDIUM: MVCC and Snapshots (70+ gaps)

### Snapshot File Operations

| File | Line | Operation |
|------|------|-----------|
| snapmgr.c | 1256 | `fwrite()` - export snapshot |
| snapmgr.c | 1272 | `rename()` - finalize |
| snapmgr.c | 1455 | `fstat()` - import |
| snapmgr.c | 1460 | `fread()` - import |
| snapmgr.c | 1057, 1608 | `unlink()` - cleanup |

### MultiXact Lock Acquisitions (50+ without wait events)

| File | Lines | Lock |
|------|-------|------|
| multixact.c | 559-1846 | `MultiXactGenLock` (30+) |
| multixact.c | 794-2226 | SLRU bank locks (20+) |

### Predicate Lock Operations (60+ without wait events)

| File | Lines | Lock |
|------|-------|------|
| predicate.c | 835-1045 | `SerialControlLock` |
| predicate.c | 1462-1812 | `SerializableXactHashLock` (30+) |
| predicate.c | 1461-2764 | `PredicateLockHashPartitionLock` (20+) |

---

## 14. MEDIUM: Data Type Operations (30+ gaps)

### JSON/JSONB Path Execution (CRITICAL - No CHECK_FOR_INTERRUPTS)

| File | Line | Operation | Severity |
|------|------|-----------|----------|
| jsonpath_exec.c | 891-971 | jpiIndexArray nested loops | HIGH |
| jsonpath_exec.c | 1954-2010 | executeAnyItem while loop | HIGH |
| jsonpath_exec.c | 2054-2090 | executePredicate nested loops | HIGH |
| jsonpath_exec.c | 2873-2921 | keyvalue iteration | HIGH |
| jsonfuncs.c | 605-4197 | 6+ JsonbIteratorNext loops | CRITICAL |

### Array Operations

| File | Line | Operation |
|------|------|-----------|
| array_userfuncs.c | 633-680 | `array_agg_combine()` loops |
| arrayfuncs.c | 303-400+ | `parse_array()` char loop |

### Geometry Operations (O(n²) loops)

| File | Line | Operation | Complexity |
|------|------|-----------|------------|
| geo_ops.c | 1742-1778 | `path_distance()` | O(n²) |
| geo_ops.c | 4052-4080 | `poly_distance()` | O(n²) |

---

## 15. MEDIUM: Parallel Query (2 gaps)

### Parallel Hash Join Barriers

| File | Line | Operation |
|------|------|-----------|
| nodeHashjoin.c | 362 | `BarrierArriveAndWait(build_barrier, 0)` - NO wait event |
| nodeHash.c | 3167 | `BarrierArriveAndWait(&shared->batch_barrier, 0)` - NO wait event |

**Note**: All other parallel barriers are properly instrumented with `WAIT_EVENT_HASH_*`.

---

## 16. External Library Calls

### ICU/Unicode

| File | Lines | Operations |
|------|-------|------------|
| pg_locale_icu.c | 467-1291 | `ucol_open`, `ucol_strcoll`, `ucol_getSortKey` |
| pg_locale_icu.c | 890-1171 | `ucnv_fromUChars`, `ucnv_toUChars` |

### OpenSSL Cryptographic

| File | Lines | Operations |
|------|-------|------------|
| cryptohash_openssl.c | 149-331 | `EVP_DigestInit/Update/Final` |
| openssl.c | 92-639 | EVP encrypt/decrypt |
| pg_strong_random.c | 90 | `RAND_bytes()` |

### GSSAPI (Partial Coverage)

| File | Lines | Operations |
|------|-------|------------|
| be-secure-gssapi.c | 205, 394, 605, 725 | `gss_wrap`, `gss_unwrap`, `gss_accept` |
| fe-secure-gssapi.c | 197, 390, 655 | Client-side GSS |

**Note**: Only `GSS_OPEN_SERVER` wait event exists, not actual gss_* operations.

### LDAP (CRITICAL - No wait events)

| File | Lines | Operations |
|------|-------|------------|
| auth.c | 2237-2643 | All ldap_* functions (15+) |
| fe-connect.c | 5633-5750 | Client LDAP lookups |

---

## Summary: Total Gaps by Category

| Priority | Category | Gap Count |
|----------|----------|-----------|
| **CRITICAL** | Sleep/Delay | 30+ |
| **CRITICAL** | Shared Memory/IPC | 35+ |
| **CRITICAL** | Network Operations | 42+ |
| **CRITICAL** | Procedural Languages | 25+ |
| **CRITICAL** | JIT Compilation | 8 |
| **HIGH** | TOAST/Large Objects | 16+ |
| **HIGH** | Compression | 12+ |
| **HIGH** | File I/O | 50+ |
| **HIGH** | Logging | 20+ |
| **HIGH** | Contrib Modules | 25+ |
| **MEDIUM** | Configuration | 30+ |
| **MEDIUM** | Recovery | 15+ |
| **MEDIUM** | MVCC/Snapshots | 70+ |
| **MEDIUM** | Data Types | 30+ |
| **MEDIUM** | Parallel Query | 2 |
| | **TOTAL** | **410+** |

---

## Methodology

This analysis examined the PostgreSQL source code using pattern matching for:

**Blocking syscalls:**
- `pg_usleep`, `usleep`, `sleep`, `nanosleep`
- `socket`, `connect`, `bind`, `listen`, `accept`
- `send`, `recv`, `sendto`, `recvfrom`
- `select`, `poll`, `ppoll`
- `read`, `write`, `pread`, `pwrite`
- `fread`, `fwrite`, `fgets`, `fputs`, `fgetc`, `fputc`
- `fsync`, `fdatasync`, `msync`
- `stat`, `fstat`, `lstat`
- `open`, `close`, `unlink`, `rename`
- `fork`, `wait`, `waitpid`
- `pipe`, `popen`, `pclose`, `system`
- `shmget`, `shmat`, `shmdt`, `shmctl`
- `mmap`, `munmap`
- `sem_wait`, `sem_post`
- `gethostbyname`, `getaddrinfo`, `getnameinfo`
- `syslog`, `ReportEvent`

**External library calls:**
- libxml2, LLVM, Python/Perl/Tcl interpreters
- libcurl, OpenSSL, GSSAPI, LDAP
- zlib, LZ4, ZSTD, ICU

Each finding was verified against existing wait event instrumentation in nearby code.

---

## References

- Original gap analysis: https://gaps.wait.events/
- PostgreSQL wait event documentation: https://www.postgresql.org/docs/current/monitoring-stats.html#WAIT-EVENT-TABLE
- Mailing list discussion: https://www.postgresql.org/message-id/flat/CAM527d9PkaSj-gNjLZqjJXnqaWT8kHPtm2Yj8-1Gh_0pTRgDA@mail.gmail.com
