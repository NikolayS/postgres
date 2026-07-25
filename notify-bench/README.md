# notify-bench — measuring the LISTEN/NOTIFY commit lock

Fork-local benchmark harness for the cluster-wide heavyweight lock that
`PreCommit_Notify()` takes at `src/backend/commands/async.c:1309`:

```c
LockSharedObject(DatabaseRelationId, InvalidOid, 0, AccessExclusiveLock);
```

Because `LockSharedObject()` builds the locktag with dbid `InvalidOid`, this lock is
cluster-wide (all databases). It is released at
`ResourceOwnerRelease(RESOURCE_RELEASE_LOCKS)` (`xact.c:2480`), i.e. **after**
`RecordTransactionCommit()` (`:2407`, containing `XLogFlush()` at `:1544` and
`SyncRepWaitForLSN()` at `:1599`) and **after** `ProcArrayEndTransaction()` (`:2431`).
Notifying transactions therefore cannot group-commit with one another.

Context, full analysis and discussion: issue #82 in this fork.

> **This directory is fork-local.** It is not proposed for upstream inclusion in this
> form. The instrumentation patch is a measurement device and is deliberately unsafe.

## Headline result: the lock, isolated

The problem with comparing `INSERT` against `INSERT; NOTIFY` is that the delta contains
the lock *plus* the SLRU queue insert, the utility statement, and an extra client round
trip. To isolate the lock, `instrumentation/0001-MEASUREMENT-ONLY-skip-notify-commit-lock.patch`
makes the identical binary skip **only** that one call when `PG_NOTIFY_NOLOCK` is set in
the postmaster environment.

`synchronous_commit=on`, zero listeners, 3 reps of 10 s, median [min–max]:

| clients | control | NOTIFY (lock) | NOTIFY (no lock) | gap recovered |
|--:|--:|--:|--:|--:|
| 1  | 824 [794–835] | 790 [618–844] | 733 [695–778] | — (no gap at c=1) |
| 4  | 2,059 [1946–2075] | 1,033 [934–1051] | 2,177 [2115–2300] | 111% |
| 16 | 7,811 [7430–8006] | 1,027 [911–1074] | 7,893 [7606–8290] | 101% |
| 64 | 16,307 [16044–16469] | 1,055 [979–1135] | 12,369 [11077–12973] | 74% |

Lock-removal speedup: 2.1x (4 clients), 7.7x (16), 11.7x (64). Arm separation is
asserted by the harness: 72 `Lock`/`object` wait samples in the lock arm, **0** in the
no-lock arm. A run where that check fails to separate is void.

This answers the open question from the 2025 pgsql-hackers thread — whether
`NotifyQueueLock` would simply become the next bottleneck. It does not: it is a short
LWLock around the SLRU insert and never spans the fsync. At 64 clients the residual
(NotifyQueueLock + SLRU + one extra round trip) is ~26% of the gap.

### The mechanism, stated hardware-independently

From `results/master.waits.csv`, both arms show exactly one backend in `IO`/`WalSync` at
any instant — one fsync in flight. The difference is who is queued behind it:

| | `Lock`/`object` | `LWLock`/`WALWrite` | `IO`/`WalSync` |
|---|--:|--:|--:|
| NOTIFY, 32 clients | 610 | **0** | 18 |
| control, 32 clients | 0 | **373** | 18 |

Control queues ~21 backends per in-flight fsync — group commit working. NOTIFY queues
**zero**, because everyone is stuck one step earlier on the heavyweight lock.
**Group-commit batch factor ~21 versus exactly 1.** Throughput ratios on any particular
disk are a consequence of that; this statement is the portable one.

## Scripts

All run as an unprivileged user; PostgreSQL refuses to start as root.

```
scripts/writers.sh   <PGBIN> <PGDATA> <PORT> <LABEL> <OUTDIR> [initdb]
scripts/listeners.sh <PGBIN> <PGDATA> <PORT> <LABEL> <OUTDIR>
scripts/ab_lock.sh   <PGBIN> <PGDATA> <PORT> <OUTDIR>          # needs instrumented build
scripts/verify.sh                                              # arm-separation smoke test
scripts/checkjam.sh                                            # demonstrates the defect in D1 below
```

`ab_lock.sh` is the one that matters. `writers.sh` and `listeners.sh` are the earlier,
weaker harness, kept because the published numbers in issue #82 §3 came from them and the
raw data should stay auditable.

## Builds used

Same repo, same container, `./configure --prefix=... --without-readline --without-zlib --without-icu`:

- `master` — `13b7a8a` (20devel), i.e. **with** the v19 fix `282b1cde`
- `v18` — `REL_18_BETA1`, i.e. **before** it
- instrumented — `13b7a8a` plus the patch in `instrumentation/`

## Known defects — read before citing any number here

These were found by adversarial review and are documented rather than quietly fixed,
because several published numbers depend on them.

**D1 — the "interested listener" measurements are invalid and are retracted.**
`listeners.sh` starts listeners as `psql -f <fifo>`. A psql blocked reading a fifo never
calls `PQconsumeInput`, so it never collects notifications; the backend fills the socket
buffer and parks in `ClientWrite`, stopping draining. On master a jammed listener latches
`wakeupPending` and is then skipped forever by `SignalBackends()`; on v18 there is no such
flag and it is signalled on every notifying commit. **The defect flatters master and
punishes v18** — the direction of the bias favours the conclusion the harness was built to
test. `scripts/checkjam.sh` demonstrates it: 50 of 50 listeners in `Client`/`ClientWrite`
for the whole run. Any future listener work needs a real libpq client looping on
`PQconsumeInput`/`PQnotifies`, plus a `received ≈ sent × listeners` assertion.
The *uninterested* listener numbers are unaffected — those listeners receive nothing and
never jam.

**D2 — single samples in `writers.sh`/`listeners.sh`.** `master.listeners.csv` and
`master.listeners2.csv` are two runs of the same configuration; the 500-interested cell
differs by 7,380% (386 vs 28,881) because an earlier cleanup bug leaked 169 sessions.
Only `ab_lock.csv` has repetitions.

**D3 — the `synchronous_commit=off` rows are noise.** Cross-comparing the control arm
between builds (identical code path) shows up to 31% disagreement, and `master.csv` has
NOTIFY *beating* the control at 8 clients. Noise floor ~50%. Do not quote a ratio.

**D4 — 4 vCPU box, pgbench and up to 500 listener processes co-resident with the server.**
Everything at ≥8 clients is CPU-oversubscribed. The listener runs are at 125 listeners per
core and will not reproduce at realistic ratios. The NOTIFY `synchronous_commit=on` rows
are the least affected — at ~1,000 TPS with 96% of backends parked on a lock, the box is
idle.

**D5 — no latency percentiles** (only pgbench's mean), **no sync-rep configuration**
despite the claim that sync rep worsens the effect, **no `pg_test_fsync`** to establish
that the ~1 ms fsync is genuinely durable, and **different pgbench binaries** between the
master and v18 arms in `writers.sh`.

**D6 — `bigserial primary key`** puts a sequence and a monotonic rightmost btree page in
both arms, capping the control ceiling — i.e. the numerator of every ratio.

## Before publishing any of this

Fix D1, D2 and D4 first. Then: a machine with ≥32 cores, pgbench and listeners on separate
hosts, ≥5 runs per cell with medians and bootstrap CIs on every published ratio, 30 s
warmup discarded plus ≥60 s measured, latency p50/p90/p99, `pg_test_fsync` output, a
synchronous standby with `netem` RTT sweep, and a `commit_delay` sweep (it should help the
control and do nothing for NOTIFY — a knob that provably moves one arm and not the other
is clean mechanistic evidence).

The single cleanest confirmation available: WAL fsyncs per commit from `pg_stat_io`
(`object='wal'`, `context='normal'`), which should be pinned at **1.00 for NOTIFY at every
concurrency** while the control falls toward ~0.05 at 64 clients.
