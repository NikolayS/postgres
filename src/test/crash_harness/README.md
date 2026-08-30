# crash_harness — dm-log-writes crash-consistency harness for Postgres

Seed implementation of **P1** from the crash-recovery testing effort tracked in
[NikolayS/postgres#31](https://github.com/NikolayS/postgres/issues/31).
This harness records every write Postgres does (including fsyncs, FUAs and
cache-flush barriers) at the block layer, then replays the log to arbitrary
"what-if-power-cut-here" endpoints, mounts each replayed image, starts
Postgres on it, and runs a suite of oracles that are designed to catch bugs
that `kill -9` testing cannot.

This directory is intentionally self-contained. It is not wired into the
Postgres build: it's an orchestration tool you run separately against a
stock Postgres (or, later, against a storage layer like the
[postgres.ai](https://postgres.ai) engine).

---

## Why `kill -9` isn't enough

`kill -9` on a Postgres process kills only the process. The kernel page cache
is untouched; the block-device write cache is untouched. When the database
restarts, everything the process wrote is still visible via reads — regardless
of whether `fsync()` has actually happened. That means **a test that passes
with fsync disabled isn't testing fsync**. This was demonstrated empirically
in [Exp A](https://github.com/NikolayS/postgres/issues/31#issuecomment-4315473425)
of issue #31: 109 168 fsyncs nullified by an `LD_PRELOAD` shim, `kill -9`
applied, every committed row present after restart.

The real failure modes in production — power loss, hypervisor reset,
firmware panic, storage-layer crash — make **only what has been flushed to
disk with fsync/FUA** visible after recovery. A specific bug class this
surfaces that `kill -9` cannot: *a directory entry persists without the
corresponding inode or extent metadata*, so `readdir()` lists the file but
`open()` returns `ENOENT` or `EIO`. Oracle (5) below is written specifically
to catch that.

## dm-log-writes mechanics (the 90-second version)

`dm-log-writes` is a device-mapper target (the same mechanism `dm-crypt`,
`dm-thin` and friends use). Its table takes two underlying devices:

    0 <sz> log-writes <data_dev> <log_dev>

Every write, flush, or FUA request issued to the mapped device is forwarded
to `<data_dev>` as usual **and** recorded in order into `<log_dev>` with
precise flag bits. The log records a causal "this happened, and it was
tagged as flushable / forced unit access / etc." history.

Between workload phases we inject named marks via

    dmsetup message <target> 0 mark <name>

which get stamped into the log.

After recording, Josef Bacik's
[`replay-log`](https://github.com/josefbacik/log-writes) tool reconstructs
the on-disk state that **would** have been visible if power had been cut at
that mark:

    replay-log --log <log_dev> --replay <scratch_dev> --end-mark <name>

The replayed image is a crash-consistent snapshot at exactly that point in
the write stream. We mount it, start Postgres, and run oracles. Iterate
over every mark and you enumerate a family of crash-consistent states, each
with a deterministic reproducer (the recorded log + the mark name).

This is the same primitive ext4/xfs/btrfs developers use in `xfstests` and
that the OSDI '18 CrashMonkey+ACE paper built on top of.
[Exp B](https://github.com/NikolayS/postgres/issues/31#issuecomment-4315483624)
of issue #31 proved end-to-end that Postgres 16 recovers cleanly from every
replay endpoint we threw at it on stock ext4 — this harness is the
productionization of that experiment.

## How the oracles catch bugs

Each replayed image is checked by five oracles plus one optional one. They
are intentionally layered from cheap + shallow to expensive + deep:

1. **`recovery_completed`** — `database system is ready` follows the
   recovery marker in the startup log, within a deadline. If Postgres can't
   even finish recovery, nothing else matters.

2. **`amcheck_clean`** — installs `amcheck`, runs
   `pg_amcheck --all --no-dependent-indexes`. Catches B-tree, heap, and
   index-vs-heap corruption that replay can produce if a storage layer
   mis-orders writes.

3. **`checksum_scan`** — `SELECT count(*) FROM relation` on every user
   relation. Any page-checksum error raised is a failure. Forces every
   page to be read through the buffer manager so torn writes / flipped
   bits are exercised.

4. **`catalog_fs_crosscheck`** — for every `pg_class.relfilenode`, a file
   must exist at `base/<dboid>/<relfilenode>[.N]`; for every file under
   `base/*/*`, either a `pg_class` row must reference it or it must be a
   known exception (FSM, VM, init fork, `pg_internal.init`, `PG_VERSION`,
   `pg_filenode.map`). Any divergence is a filesystem-vs-catalog drift
   that should never survive recovery.

5. **`readdir_open_sanity`** — **this is the one #31 specifically calls out.**
   Walks the entire `pgdata/` tree via `os.scandir()`; for every dirent,
   attempts `open(path, O_RDONLY)` (files) or `O_DIRECTORY` (dirs). Any
   `ENOENT` / `EIO` / `EACCES` on something `scandir` just listed is a
   failure. This is the signature of a storage bug where the directory
   entry persists independently of inode/extent metadata.

6. **`committed_xact_visibility`** *(optional, best-effort)* — if the
   workload wrote a `workload_committed_xids.log` before the crash point,
   verify each xid is visible via `pg_xact_status(xid)` post-recovery.

The oracle suite runs to completion even when earlier oracles fail, so a
single replay gives you a matrix of findings rather than one early exit.

## Prerequisites

- Linux kernel with the `dm-log-writes` module. On Debian/Ubuntu that's
  usually in the `linux-modules-extra-$(uname -r)` package.
  Confirm with `modprobe dm-log-writes`.
- `dmsetup`, `losetup`, `mount`, `mkfs.ext4`, `e2fsck` (util-linux +
  e2fsprogs — standard everywhere).
- Postgres **16+** (`initdb`, `pg_ctl`, `psql`, `pg_amcheck`). The harness
  defaults to `/usr/lib/postgresql/16/bin` but accepts `--pg-bin`.
- `amcheck` contrib extension built and available (Debian/Ubuntu:
  `postgresql-contrib-16`).
- Python 3.8+ stdlib. No third-party packages.
- `replay-log` from https://github.com/josefbacik/log-writes, built via
  `make install-deps` below.
- Root / sudo (dmsetup, losetup, mount).

Non-Linux hosts: the Makefile's `guard-linux` target aborts cleanly on macOS
and Windows. The harness itself will `die("linux_required")` if invoked
there.

## Install

Three lines from this directory:

    sudo make install-deps       # clones josefbacik/log-writes and builds it
    sudo cp /var/tmp/crash-harness/log-writes/replay-log /usr/local/bin/
    chmod +x harness.py

Everything else is vendored inside this directory.

## Quick-start

End-to-end in one command (setup + record + replay every mark + teardown):

    sudo make check

Or wire it up step-by-step:

    sudo ./harness.py setup \
        --backing /var/tmp/ch/back.img --log /var/tmp/ch/log.img \
        --backing-size 8G --log-size 4G

    sudo ./harness.py record \
        --log /var/tmp/ch/log.img --mount /mnt/ch \
        --pg-bin /usr/lib/postgresql/16/bin \
        --random-every 3

    sudo ./harness.py replay \
        --log /var/tmp/ch/log.img --backing /var/tmp/ch/back.img \
        --replay-image /var/tmp/ch/replay.img \
        --replay-to-mark all --verify

    sudo ./harness.py teardown \
        --backing /var/tmp/ch/back.img --log /var/tmp/ch/log.img

`--json` on any subcommand makes stdout machine-parseable (line-delimited
JSON; the final summary is a single JSON object with `summary.ok` and a
per-mark `results` array).

## Workloads

The default workload (`workloads/default.sh`) is a ~30-60 s mixed script:
`pgbench -i -s 2`, `pgbench -c 2 -T 15`, `CHECKPOINT`, create/drop table
churn, `VACUUM`, three `pg_switch_wal()` calls, and a `CREATE DATABASE
scratch; DROP DATABASE scratch;` cycle. Exp D of issue #31 mapped the
fsync call-graph for almost exactly this script — 24 682 fdatasyncs, 290
fsyncs, 26 renames across 104 unique paths — so it covers the
high-frequency durability surfaces we actually care about (`pg_wal/*`,
`global/pg_control`, `pg_xact/*`, `pg_logical/replorigin_checkpoint`).

Pass `--workload-script path/to/your.sh` to plug in your own. Your script
gets `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `CRASH_HARNESS_PG_BIN`,
`CRASH_HARNESS_MOUNT`, `CRASH_HARNESS_TARGET`, `CRASH_HARNESS_LOG` from
the env. Call `dmsetup message $CRASH_HARNESS_TARGET 0 mark your-mark`
and append `your-mark` to `$CRASH_HARNESS_LOG.marks` to drop custom marks;
the default script includes a `mark()` helper you can copy.

If you write `workload_committed_xids.log` to the mounted filesystem root
before the crash, oracle (6) will cross-check those xids.

## Repository layout

```
src/test/crash_harness/
├── README.md            (this file)
├── Makefile             convenience targets (install-deps, check, clean)
├── harness.py           orchestrator + all oracles (Python 3 stdlib)
├── oracles/             (reserved for future per-oracle modules; see below)
└── workloads/
    └── default.sh       default mixed workload (pgbench + DDL + WAL switch)
```

The oracles live inside `harness.py` today so there's one file to read.
A future refactor can split them out under `oracles/` without changing the
CLI — `run_all_oracles()` in `harness.py` is the seam.

## Known limitations / TODO

- **`replay-log` doesn't expose a `list-marks` command.** We mirror mark
  names to a sidecar file (`<log>.marks`) during `record` so
  `--replay-to-mark all` can iterate. If you recorded with an older harness
  or lost the sidecar, pass specific `--replay-to-mark <name>` values.
- **Serial replay only.** Each replayed mark rewrites the replay image from
  scratch. Parallel replay (multiple scratch images, one per mark) is
  future work — trivial but not implemented.
- **ext4 only by default.** The `--fs` flag accepts any `mkfs.*` target,
  but the default script uses `mkfs.ext4` + `e2fsck`. XFS / btrfs variants
  need small tweaks (different fsck, different mount options).
- **Oracles are conservative.** Several of them (checksum_scan, amcheck)
  can in principle report spurious noise on a badly truncated catalog;
  we err on the side of flagging and letting a human triage.
- **`pg_amcheck` is required.** If your Postgres build lacks the `amcheck`
  contrib, oracle (2) returns `ok=false, err="amcheck not available"`.
- **No Tier-3 crash modes yet.** P1 is dm-log-writes only. `dm-flakey
  drop_writes`, `dm-dust`, and LD_PRELOAD fsync-liar (Exps C and A from
  issue #31) belong in a sibling harness and aren't included here.

## References

- Issue thread (full context + all four experiments): [NikolayS/postgres#31](https://github.com/NikolayS/postgres/issues/31)
  - Exp A, LD_PRELOAD no-fsync + kill -9: [comment](https://github.com/NikolayS/postgres/issues/31#issuecomment-4315473425)
  - **Exp B, dm-log-writes + replay-log (the experiment this harness productionizes)**: [comment](https://github.com/NikolayS/postgres/issues/31#issuecomment-4315483624)
  - Exp C, dm-flakey drop_writes: [comment](https://github.com/NikolayS/postgres/issues/31#issuecomment-4315487036)
  - Exp D, fsync call-graph: [comment](https://github.com/NikolayS/postgres/issues/31#issuecomment-4315490876)
  - Consolidated findings: [comment](https://github.com/NikolayS/postgres/issues/31)
- `dm-log-writes` kernel docs: `Documentation/admin-guide/device-mapper/log-writes.rst`
- `replay-log` tool: https://github.com/josefbacik/log-writes
- CrashMonkey + ACE (OSDI '18): https://www.usenix.org/conference/osdi18/presentation/mohan
