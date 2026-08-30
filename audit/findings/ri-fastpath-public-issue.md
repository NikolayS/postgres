# PG19 FK fast-path (`ri_FastPath*`): three reachable defects from running user-defined cast/operator code inside the deferred batch flush

*Public bug report drafted for the PostgreSQL 19 beta cycle. The `ri_FastPath*`
foreign-key existence-check fast path is new in PG 19 (master) and is now in
`REL_19_BETA1`; it is absent from all released branches (18, 17). None of these
is a `security@`/CVE matter — the code has not shipped in a GA release — but all
three are reachable by an **unprivileged table owner** and should be fixed
before PG 19 GA.*

## Affected code / provenance

- File: `src/backend/utils/adt/ri_triggers.c`, the `ri_FastPath*` machinery.
- Present in upstream `master` (verified against `postgres/postgres@193a4ded`)
  and in `REL_19_BETA1` (identical for this file); **absent** from `REL_18_4`
  and `REL_17_6` (0 occurrences of `ri_FastPath`). So this is a **PG 19-only**
  feature.
- Line numbers below are from `REL_19_BETA1`.

## Background

PG 19 adds a fast path for the FK *existence* check (INSERT/UPDATE on the
referencing side) that probes the PK unique index directly instead of going
through SPI. For throughput it **buffers** referencing-side rows in a
transaction-lived cache (`ri_fastpath_cache`, keyed by `pg_constraint` OID) and
only runs the actual checks when the per-constraint buffer fills (64 rows) or
when the after-trigger firing pass ends (`ri_FastPathEndBatch`, an
`AfterTriggerBatchCallback`).

The flush runs **arbitrary user-defined code**: for a cross-type FK,
`ri_FastPathFlushArray()` / `ri_FastPathFlushLoop()` call the column's
implicit-cast function (`FunctionCall3(cast_func_finfo, …)`) and the FK equality
operator (`FunctionCall2Coll(eq_opr_finfo, …)`). All three defects below stem
from that: user code runs in the middle of a half-updated batch / an in-progress
cache scan.

**Unprivileged reachability (common to all three).** The cast route needs no
superuser and no contrib module: a user may `CREATE TYPE` on a type they own and
`CREATE CAST (ownedtype AS sometype) WITH FUNCTION f(...) AS IMPLICIT` (allowed
for the source-type owner; `f` may be PL/pgSQL). An ordinary single-column FK
whose column implicitly casts to the PK type then wires that IMPLICIT cast into
`cast_func_finfo` (`ri_HashCompareOp()`), and the fast path invokes it during the
flush. The PK uses the default btree opclass; the FK is an ordinary FK; the fast
path is always on for non-partitioned, non-temporal FKs (no GUC).

---

## Defect 1 — re-entrancy → out-of-bounds heap write (memory safety / crash)

`ri_FastPathBatchAdd()` (line 2859) appends to the fixed 64-element array and
bounds-checks only **after** the write:

```c
fpentry->batch[fpentry->batch_count] = ExecCopySlotHeapTuple(newslot); /* 2866: write */
fpentry->batch_count++;
if (fpentry->batch_count >= RI_FASTPATH_BATCH_SIZE)                    /* then check */
    ri_FastPathBatchFlush(fpentry, fk_rel, riinfo);
```

`batch_count` is reset to 0 only at the *end* of the flush, so during a
full-batch flush it stays at 64. The flush invokes user code (cast/operator).
`RI_FastPathEntry` has **no re-entrancy guard**, and `ri_FastPathGetEntry()`
returns the *same* cached entry on re-entry. If that user code performs DML on
the same referencing table, the nested `ri_FastPathBatchAdd()` runs with
`batch_count == 64`:

1. `batch[64] = ptr` aliases the `batch_count` field that follows the array →
   `batch_count` becomes the low 32 bits of a heap pointer (a large/negative
   `int`);
2. the next add indexes `batch[<garbage>]` → **wild OOB heap write**; or the
   recursive flush runs `memset(matched, 0, nvals * sizeof(bool))` (line 3054)
   with a garbage `nvals` → oversized `memset`.

**Reproduced** as a non-superuser (implicit-cast vehicle) on a `--enable-cassert
-O0` build: SIGSEGV, whole-cluster restart; gdb backtrace
`#1 ri_FastPathFlushArray (...) at ri_triggers.c:3054`. Instrumented trace shows
`batch_count` going `62 → 63 → 64 → -55227815` then a wild write.

Per PostgreSQL's security model this is a **bug, not a vulnerability** (an
authenticated crash/DoS; the written value/index derive from a heap address, so
a *controlled* write is speculative and not demonstrated). It is still a
must-fix memory-safety defect.

---

## Defect 2 — buffered FK checks dropped on subtransaction abort (integrity bypass)

`ri_FastPathSubXactCallback()` (line 4208), on `SUBXACT_EVENT_ABORT_SUB`, simply
NULLs the static cache pointer:

```c
ri_fastpath_cache = NULL;
ri_fastpath_callback_registered = false;
```

The assumption that everything in the cache belongs to the aborting subxact is
wrong: `batch[]` holds outstanding FK rows of the **enclosing** transaction. When
an internal subtransaction aborts during after-trigger firing — canonically a
PL/pgSQL `BEGIN … EXCEPTION … END` block in another AFTER ROW trigger firing in
the same batch — the whole cache is discarded **unflushed**. Those FK existence
checks never run and **orphan rows commit** behind a still-`convalidated`
constraint (`ALTER TABLE … VALIDATE CONSTRAINT` is a no-op, so it stays hidden).

**Reproduced** (single-column array path and multi-column loop path), unprivileged:

```sql
create table pk(id int primary key);
create table fk(a int, tag text);
insert into pk select g from generate_series(1,10) g;
alter table fk add constraint fk_a_fkey foreign key (a) references pk(id);

create function abort_subxact() returns trigger language plpgsql as $$
begin
  if NEW.tag = 'boom' then
    begin perform 1/0; exception when others then null; end;  -- internal subxact abort
  end if;
  return NEW;
end;$$;
create trigger fk_after after insert on fk for each row execute function abort_subxact();

insert into fk values (999,'bad'),(0,'boom'),(1,'ok'),(2,'ok'),(3,'ok');  -- INSERT 0 5, no error
select f.a from fk f left join pk p on f.a=p.id where p.id is null;       -- => 0, 999 (orphans)
```

Controls (no `EXCEPTION`/subxact; between-statement `SAVEPOINT`; `DEFERRABLE
INITIALLY DEFERRED`) all behave correctly. Security-relevant where apps rely on
FK for authz joins / multi-tenant isolation.

---

## Defect 3 — EndBatch cross-table re-entrancy silently drops a check (integrity bypass)

`ri_FastPathEndBatch()` (line 4133) flushes by iterating the cache with
`hash_seq_search` (line 4143). The flush runs user cast/operator code. If that
code `INSERT`s into a **different** fast-path FK table, `ri_FastPathGetEntry()`
(line 4234) adds a **new** cache entry (and registers no new batch callback). That
entry can land in a hash bucket the running `hash_seq_search` has already passed →
it is never flushed. `ri_FastPathEndBatch` then calls `ri_FastPathTeardown()`
(line 4165), which `hash_destroy`s the cache (line 4188) **without flushing
entries that still have `batch_count > 0`**. The buffered FK check is discarded
and an orphan commits.

This **survives the per-entry guard proposed for Defect 1** (it adds a *different*
entry, not a re-entry of the busy one).

**Reproduced**, unprivileged: `child`(type `t`, IMPLICIT cast `evil()`→int) and
`child2`(int), both → `parent(id)`; `evil()`, run during `child`'s EndBatch
flush, inserts an orphan into `child2`. Control `INSERT INTO child2 VALUES (888888)`
is rejected (FK violation); `INSERT INTO child SELECT 'z'::t …` commits and leaves
the orphan in `child2` with `convalidated = t`.

---

## Common root cause

All three are instances of one design issue: **the fast path runs user-defined
cast/operator code inside a deferred batch flush** — once while a per-entry batch
is half-updated (Defect 1), once while a cache-wide `hash_seq_search` is in
progress and the teardown drops non-empty entries (Defect 3), and against a
subxact-abort cache-invalidation that cannot distinguish parent rows from
aborted-subxact rows (Defect 2).

## Suggested fix directions

- **Defect 1:** add a `flushing` flag to `RI_FastPathEntry`, set across the flush
  body, and reject re-entrant batch modification of a busy entry (a nested
  per-row probe is unsafe — the flush may hold PK-index buffer locks, tripping
  `Assert(lockmode == BUFFER_LOCK_UNLOCK)` in `bufmgr.c`). Also reorder
  `ri_FastPathBatchAdd()` to bounds-check before the write. (Verified locally:
  closes the crash; normal batched FK + genuine-violation detection intact.)
- **Defect 3:** make `ri_FastPathEndBatch` loop-flush until no entry has
  `batch_count > 0`, and/or have `ri_FastPathTeardown` flush any non-empty entry
  before `hash_destroy`.
- **Defect 2:** do not discard outstanding parent-transaction batch rows on
  `SUBXACT_EVENT_ABORT_SUB`; track which subxact buffered each row, or flush
  immediate-constraint batches at subxact boundaries.
- **Better, unifying:** promote the per-entry `flushing` guard to a global
  "in fast-path flush" guard that routes any re-entrant FK check to the immediate
  per-row path — and reconsider invoking arbitrary user code mid-flush at all.

## Disclosure note

PG 19 is unreleased (now `REL_19_BETA1`), so these are pre-GA bugs for the patch
author / pgsql-hackers, not `security@postgresql.org` CVEs. Reproduced live on a
build from the affected code; minimal fix for Defect 1 verified.
