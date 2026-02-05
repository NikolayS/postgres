# Additional PostgreSQL Wait Event Coverage Gaps

This document extends the analysis from https://gaps.wait.events/ with newly discovered gaps found through comprehensive source code analysis.

## Executive Summary

Beyond the **39 gaps** already documented (32 authentication + 7 I/O), this analysis identified **80+ additional locations** across multiple subsystems where PostgreSQL operations can block without proper wait event instrumentation.

| Category | Known Gaps | New Gaps | Priority |
|----------|------------|----------|----------|
| Authentication | 32 | 2 | CRITICAL |
| I/O Operations | 7 | 15+ | HIGH |
| Procedural Languages | 0 | 25+ | CRITICAL |
| JIT Compilation | 0 | 8 | HIGH |
| FDW/Foreign Data | 0 | 12+ | HIGH |
| Contrib Modules | 0 | 20+ | HIGH |
| Logical Replication | 0 | 10+ | MEDIUM |
| Extension Loading | 0 | 11+ | MEDIUM |
| Text Search/XML | 0 | 15+ | LOW-MEDIUM |

---

## 1. CRITICAL: Procedural Languages (NEW - 25+ gaps)

**Impact**: All external PL code execution is completely invisible to monitoring.

### PL/Python (`src/pl/plpython/`)

| Location | Operation | Impact |
|----------|-----------|--------|
| `plpy_main.c:73` | `Py_Initialize()` | Interpreter startup |
| `plpy_procedure.c:390` | `Py_CompileString()` | Code compilation |
| `plpy_exec.c:1111` | `PyEval_EvalCode()` | **Every function call** |

User Python code can perform:
- Network I/O (urllib, requests, socket)
- File operations
- External module imports (late imports)
- Database calls via external libraries

### PL/Perl (`src/pl/plperl/plperl.c`)

| Location | Operation | Impact |
|----------|-----------|--------|
| Line 811 | `perl_construct()` | Interpreter creation |
| Line 848 | `perl_parse()` | Parser initialization |
| Line 855 | `perl_run()` | Startup code execution |
| Line 1025 | `eval_pv(plperl_on_plperl_init)` | Init script |
| Line 2237 | `call_sv()` | **Every function call** |

### PL/Tcl (`src/pl/tcl/pltcl.c`)

| Location | Operation | Impact |
|----------|-----------|--------|
| Line 441 | `Tcl_CreateInterp()` | Interpreter creation |
| Lines 938, 1267, 1350, 1781, 2585, 2996 | `Tcl_EvalObjEx()` / `Tcl_EvalEx()` | Code execution |

**Recommendation**: Create `WAIT_EVENT_PL_EXECUTE` category with language-specific events.

---

## 2. CRITICAL: JIT Compilation (NEW - 8 gaps)

**Impact**: LLVM JIT compilation appears as unexplained "CPU" activity.

### File: `src/backend/jit/llvm/llvmjit.c`

| Location | Operation | Phase |
|----------|-----------|-------|
| Line 720-727 | `llvm_inline()` | Inlining (timed but no wait event) |
| Line 742-746 | `llvm_optimize_module()` | Optimization passes |
| Line 768-799 | `LLVMOrcLLJITAddLLVMIRModuleWithRT()` | Code emission |
| Line 363-410 | `llvm_get_function()` | Symbol lookup + lazy compilation |

### File: `src/backend/jit/llvm/llvmjit.c` - `llvm_optimize_module()`

| Location | Operation | Notes |
|----------|-----------|-------|
| Line 693 | `LLVMRunPasses()` | LLVM ≥17: Full optimization pipeline |
| Lines 645-648 | `LLVMRunFunctionPassManager()` | LLVM <17: Function passes |
| Line 666 | `LLVMRunPassManager()` | LLVM <17: Module passes |

**Note**: Timing infrastructure exists (`inlining_counter`, `optimization_counter`, `emission_counter`) but is NOT connected to wait events.

**Recommendation**: Create `WAIT_EVENT_JIT_COMPILE`, `WAIT_EVENT_JIT_OPTIMIZE`, `WAIT_EVENT_JIT_INLINE`, `WAIT_EVENT_JIT_EMIT`.

---

## 3. HIGH: Foreign Data Wrappers (NEW - 12+ gaps)

### file_fdw (`contrib/file_fdw/file_fdw.c`)

**Complete absence of wait event instrumentation**:

| Location | Function | Operation |
|----------|----------|-----------|
| Line 769 | `fileIterateForeignScan()` | `NextCopyFrom()` - per-row I/O |
| Line 1218, 1249, 1325 | `file_acquire_sample_rows()` | ANALYZE statistics sampling |
| Line 702 | `fileBeginForeignScan()` | `BeginCopyFrom()` - initialization |
| Lines 665, 897 | `fileAnalyzeForeignTable()` | `stat()` - metadata |
| Line 831 | `fileReScanForeignScan()` | `BeginCopyFrom()` - re-init |
| Line 863 | `fileEndForeignScan()` | `EndCopyFrom()` - cleanup |

**postgres_fdw** (`contrib/postgres_fdw/`) is properly instrumented - use as reference.

---

## 4. HIGH: Contrib Modules (NEW - 20+ gaps)

### pg_stat_statements (`contrib/pg_stat_statements/pg_stat_statements.c`)

| Location | Operation | Context |
|----------|-----------|---------|
| Line 588 | `unlink()` | File deletion |
| Lines 622-679 | `fread()` x multiple | Query text file reading |
| Lines 699-835 | `fwrite()`, `unlink()` | Stats dump/cleanup |
| Lines 2303-2409 | `pg_pwrite()`, `read()` | Query text operations |

### pg_prewarm/autoprewarm (`contrib/pg_prewarm/autoprewarm.c`)

| Location | Operation | Context |
|----------|-----------|---------|
| Lines 744, 762 | `fprintf()` | Prewarm file writing |
| Lines 750-801 | `unlink()`, `durable_rename()` | File operations |
| Lines 622-643 | `read_stream_*()` | Prefetch I/O |

### basebackup_to_shell (`contrib/basebackup_to_shell/basebackup_to_shell.c`)

| Location | Operation | Context |
|----------|-----------|---------|
| Line 268 | `OpenPipeStream()` | popen() to shell |
| Line 287 | `fwrite()` | Backup data to pipe |
| Line 232 | `ClosePipeStream()` | pclose() |

### Other Contrib Gaps

| Module | File | Operation | Severity |
|--------|------|-----------|----------|
| basic_archive | basic_archive.c | `fsync_fname()`, `copy_file()` | MEDIUM |
| sepgsql | selinux.c | `security_compute_av_flags_raw()` | MEDIUM |
| passwordcheck | passwordcheck.c | `FascistCheck()` (cracklib) | LOW |

---

## 5. HIGH: External Program Execution (NEW - 4 gaps)

Beyond the known COPY FROM/TO PROGRAM (now fixed):

| File | Location | Operation | Context |
|------|----------|-----------|---------|
| `be-secure-common.c` | Lines 54, 77 | `OpenPipeStream()`, `ClosePipeStream()` | SSL passphrase command |
| `collationcmds.c` | Lines 872, 929 | `OpenPipeStream()`, `ClosePipeStream()` | `locale -a` enumeration |

**Recommendation**: These should follow the pattern of `WAIT_EVENT_ARCHIVE_COMMAND`.

---

## 6. MEDIUM: Logical Replication (NEW - 10+ gaps)

### libpqwalreceiver.c

| Location | Operation | Notes |
|----------|-----------|-------|
| Lines 873-881 | `PQputCopyData()`, `PQflush()` | Network send - no wait event |

Comment at line 643-645 acknowledges: *"this could theoretically block, but the risk seems small"*

### snapbuild.c

| Location | Operation | Notes |
|----------|-----------|-------|
| Lines 1558-1559 | `fsync_fname()` x2 | Before write |
| Lines 1697, 1712-1713 | `fsync_fname()` x3 | After write |
| Lines 1773-1774 | `fsync_fname()` x2 | After restore |

**Note**: `pg_fsync()` at line 1680 IS instrumented with `WAIT_EVENT_SNAPBUILD_SYNC`, but `fsync_fname()` is not.

### logical.c - Plugin Callbacks

| Location | Callback | Notes |
|----------|----------|-------|
| Line 786 | `startup_cb` | Plugin startup |
| Line 814 | `shutdown_cb` | Plugin shutdown |
| Line 850 | `begin_cb` | Transaction begin |
| Line 882 | `commit_cb` | Transaction commit |
| Lines 1109, 1151, 1250 | `change_cb`, `truncate_cb`, `message_cb` | Data changes |

All invoke external plugin code without wait event context.

---

## 7. MEDIUM: Extension & Library Loading (NEW - 11+ gaps)

### dfmgr.c

| Location | Operation | Context |
|----------|-----------|---------|
| Line 211 | `stat()` | Library file check |
| Line 244 | `dlopen()` | **Dynamic library loading** |
| Lines 485, 503, 633 | `pg_file_exists()` | Path search loop |

### extension.c

| Location | Operation | Context |
|----------|-----------|---------|
| Line 1754 | `stat()` | Script file check |
| Lines 3877, 3888, 3896 | `stat()`, `AllocateFile()`, `fread()` | Script file loading |
| Lines 1460-1461 | `AllocateDir()`, `ReadDir()` | Version discovery |
| Line 605 | `AllocateFile()` | Control file parsing |

---

## 8. MEDIUM: Background Worker Operations (NEW - 11 gaps)

### Error Recovery Sleep (No Wait Events)

| File | Location | Operation |
|------|----------|-----------|
| checkpointer.c | Line 335 | `pg_usleep(1000000L)` after error |
| bgwriter.c | Line 201 | `pg_usleep(1000000L)` after error |
| walwriter.c | Line 194 | `pg_usleep(1000000L)` after error |
| autovacuum.c | Line 514 | `pg_usleep(1000000L)` after error |

### pgarch.c File Operations (No Wait Events)

| Location | Operation | Context |
|----------|-----------|---------|
| Line 449 | `stat()` | WAL file existence |
| Line 454 | `unlink()` | Orphan status file |
| Line 678 | `stat()` | Archive status file |
| Line 837 | `rename()` | Status file rename |

---

## 9. LOW-MEDIUM: Text Processing (NEW - 15+ gaps)

### XML Processing (`src/backend/utils/adt/xml.c`)

| Location | Operation | Notes |
|----------|-----------|-------|
| Lines 1867, 4459, 4747 | `xmlNewParserCtxt()` | Parser context creation |
| Lines 1884, 1924 | `xmlCtxtReadDoc()`, `xmlParseBalancedChunkMemory()` | Document parsing |
| Lines 4504, 4516, 4878, 4912, 4939, 5003 | `xmlXPathCtxtCompile()`, `xmlXPathCompiledEval()` | XPath operations |

### Full-Text Search Dictionary Loading

| File | Location | Operation |
|------|----------|-----------|
| ts_locale.c | Lines 80, 116 | `AllocateFile()`, `pg_get_line_buf()` |
| spell.c | Lines 524, 530, 1224, 1230 | Dictionary/affix file reading |
| dict_thesaurus.c | Lines 176, 182 | Thesaurus file reading |
| dict_synonym.c | Lines 131, 139 | Synonym file reading |

### Regular Expressions (`src/backend/utils/adt/regexp.c`)

| Location | Operation | Notes |
|----------|-----------|-------|
| Line 209 | `pg_regcomp()` | Regex compilation |
| Line 289 | `pg_regexec()` | Pattern matching |

---

## 10. Additional Authentication Gaps (NEW - 2 gaps)

### hba.c - DNS Lookups During Authentication

| Location | Operation | Context |
|----------|-----------|---------|
| Line 1091 | `pg_getnameinfo_all()` | Reverse DNS lookup |
| Line 1115 | `getaddrinfo()` | Forward DNS verification |

These are in `check_hostname()` function called during pg_hba.conf hostname matching.

---

## 11. WAL/Storage Operations (NEW - 6 gaps)

### xlog.c

| Location | Operation | Context |
|----------|-----------|---------|
| Lines 3249, 3277, 3431 | `BasicOpenFile()` | WAL file open |
| Line 3689 | `posix_fadvise()` | Page cache advisory |

### slru.c

| Location | Operation | Context |
|----------|-----------|---------|
| Line 1418 | `fsync_fname()` | Directory sync |
| Line 1544 | `unlink()` | Segment deletion |

---

## Summary: New Gaps by Severity

### CRITICAL (Must Fix)
1. **Procedural Languages** (25+ locations) - Zero visibility into user code execution
2. **JIT Compilation** (8 locations) - Optimization time invisible

### HIGH (Should Fix)
3. **FDW file_fdw** (12+ locations) - All file operations uninstrumented
4. **Contrib Modules** (20+ locations) - pg_stat_statements, pg_prewarm, basebackup_to_shell
5. **External Program Execution** (4 locations) - SSL passphrase, locale enumeration

### MEDIUM (Consider)
6. **Logical Replication** (10+ locations) - Network send, plugin callbacks
7. **Extension Loading** (11+ locations) - dlopen, script loading
8. **Background Workers** (11 locations) - Error recovery, file operations

### LOW-MEDIUM (Optional)
9. **Text Processing** (15+ locations) - XML, full-text search, regex

---

## Methodology

This analysis examined the PostgreSQL source code at commit `b8ccd29` using pattern matching for:
- Blocking syscalls: `socket`, `connect`, `send`, `recv`, `select`, `poll`, `read`, `write`
- External processes: `popen`, `system`, `fork`, `exec`, `pipe`
- File I/O: `stat`, `fread`, `fwrite`, `fsync`, `unlink`, `rename`, `dlopen`
- External library calls: libxml2, LLVM, Python/Perl/Tcl interpreters, libcurl
- DNS operations: `gethostbyname`, `getaddrinfo`, `getnameinfo`

Each finding was verified against existing wait event instrumentation in nearby code.

---

## References

- Original gap analysis: https://gaps.wait.events/
- PostgreSQL wait event documentation: https://www.postgresql.org/docs/current/monitoring-stats.html#WAIT-EVENT-TABLE
- Mailing list discussion: https://www.postgresql.org/message-id/flat/CAM527d9PkaSj-gNjLZqjJXnqaWT8kHPtm2Yj8-1Gh_0pTRgDA@mail.gmail.com
