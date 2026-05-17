# Storage adapters for the crash-consistency harness

This directory defines the **storage adapter contract** used by the
Postgres crash-consistency harness (see the top-level
`src/test/crash_harness/` directory, landing in P1 of
[NikolayS/postgres#31](https://github.com/NikolayS/postgres/issues/31)).

The harness provisions a block device, drives a Postgres workload
against it, captures one or more durability boundaries ("snapshots"),
and — for each snapshot — brings up a replica Postgres on a replay of
that state and runs a set of oracles (WAL redo, `pg_amcheck`,
`amcheck`, a readdir-vs-open cross-check, etc.).

By default the harness uses the reference adapter,
[`loop_ext4_dm_log_writes.sh`](./loop_ext4_dm_log_writes.sh), which
layers `dm-log-writes` over a loop-backed ext4 filesystem. That stack
works well for stock Linux storage, but it assumes two things that are
not universally true:

1. The storage layer has no internal write log of its own, so we have
   to interpose `dm-log-writes` to get a replayable barrier stream.
2. Durability boundaries are synthesized by the harness via
   `dmsetup message ... 0 mark <name>`.

Neither assumption holds for storage systems that already implement
their own crash-consistency machinery — ZFS, btrfs, LVM-thin,
postgres.ai DBLab, or any vendor storage layer with native snapshots.
For those, the crash-consistency guarantee you want to test is the
vendor's own snapshot boundary, not a synthetic dm-log-writes marker
over a device the vendor owns.

Hence this adapter layer.

## The contract

A storage adapter is a single executable (typically bash) that
implements the following verbs. The harness invokes it as:

    $ADAPTER <verb> [args...]

with the environment variable `HARNESS_ADAPTER_ID` set to a unique
identifier for this test run (the adapter should use it to namespace
any global resources it creates: dm target names, ZFS dataset names,
loop device tags, etc.).

### `setup`

Provision a fresh block device suitable for a Postgres data
directory. On success, write the path of the device as a **single
line** to stdout, e.g.:

    /dev/mapper/crash-harness-data

No trailing whitespace, no log noise on stdout — logs go to stderr.
The harness will `mkfs` and mount this device itself (unless the
adapter opts out; see below).

### `attach <log-device>`  (optional)

Ask the storage to record writes to an external log device, for
dm-log-writes-style replay. On adapters that have their own
crash-consistency machinery (native snapshots that are themselves
durability boundaries), this verb is a **no-op** and must exit 0.

### `snapshot <name>`

Capture a durability snapshot named `<name>`. On dm-log-writes-based
setups this is implemented as `dmsetup message ... 0 mark <name>`. On
snapshot-based systems (ZFS, btrfs, LVM-thin, DBLab) this calls the
native snapshot API (`zfs snapshot`, `btrfs subvolume snapshot`,
`lvcreate --snapshot`, etc.).

**Crucial**: the snapshot must be taken at a genuine durability
boundary of the underlying storage. For ZFS that means after a ZIL
flush and txg commit; for btrfs, after the transaction is on disk;
for LVM-thin, after the thin-pool metadata commit. If the "snapshot"
the adapter returns is not itself a crash-consistent state of the
device, the oracles downstream will report noise that is indistinguishable
from real bugs.

### `replay <snapshot-name>`

Produce a block device (or mount path — see below) whose contents are
exactly the snapshot state. Write the path as a single line to
stdout.

For dm-log-writes the implementation is "roll the log up to the mark
and export the result as a new dm-linear target". For ZFS it is
`zfs clone` of the snapshot into a throwaway dataset and echoing its
mount path. The harness treats the returned path opaquely: if it is a
block device it gets mounted read-only; if it is already a directory
(because the adapter cloned a filesystem) the harness uses it
directly. Adapters indicate which by setting the `ADAPTER_REPLAY_MODE`
env var to `block` (default) or `mount` in their output — see the
reference adapter.

### `teardown`

Release everything provisioned by `setup` and any outstanding replays
or snapshots created during this run. Must be idempotent.

## Why this abstraction exists

Two reasons.

**First**, storage layers may or may not have an external write log.
The dm-log-writes stack exists precisely to *manufacture* a replayable
stream of barriers on top of storage that doesn't give you one
natively. When the storage *does* give you one natively — via
snapshots that are themselves durability boundaries — interposing
dm-log-writes is both redundant and misleading: you'd be testing
whether dm-log-writes preserves the storage's internal ordering
rather than whether the storage itself is crash-consistent.

**Second**, we want the same harness — same workload, same oracles —
to produce the same kind of evidence for all storage layers. If a
storage layer passes the harness's oracles for every snapshot state
of a representative workload, that is strong evidence of crash
consistency at the snapshot boundary. Failures at any snapshot are
reproducible bugs: the snapshot is named, the log position is known,
and the adapter can re-emit the same device state deterministically.

That is the property we want from every adapter. The specific
mechanism by which the adapter achieves it is deliberately
underspecified.

## Reference adapters

- [`loop_ext4_dm_log_writes.sh`](./loop_ext4_dm_log_writes.sh) — the
  default. Loop-backed ext4 + dm-log-writes. Small, ~120 lines,
  intended to be readable top-to-bottom as a teaching example for
  implementers of other adapters.

- [`dblab_example.sh`](./dblab_example.sh) — stub for the postgres.ai
  DBLab / ZFS-backed case. Not functional out of the box; it is laid
  out with `TODO:` markers so an operator can fill in site-specific
  dataset names, mountpoints, and durability-boundary invariants.
  Read the comments in that file carefully: it explicitly calls out
  that the ZFS snapshots taken must correspond to ZIL flush + txg
  commit boundaries, otherwise the crash-consistency guarantee the
  harness reports is meaningless.

## Writing a new adapter

The shortest viable path is:

1. Copy `loop_ext4_dm_log_writes.sh` to a new file.
2. Replace the case branches with your storage's native operations.
3. Make sure `snapshot` lands on a real durability boundary.
4. Make sure `teardown` is idempotent and cleans up even after a
   mid-run crash (the harness may invoke `teardown` on a failed
   previous run).
5. Point the harness at it by exporting `HARNESS_ADAPTER=/path/to/your_adapter.sh`.

The harness does not care what language the adapter is written in, as
long as it is a single executable that accepts the verbs above.
