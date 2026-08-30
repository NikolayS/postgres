#!/usr/bin/env bash
#
# dblab_example.sh
#
# STUB storage-adapter for postgres.ai DBLab / ZFS-backed storage.
# This is a starting point, NOT a working adapter. An operator is
# expected to fill in the TODO sections with site-specific dataset
# names, pool names, mount points, and — most importantly — to audit
# whether their ZFS configuration actually produces snapshots at
# durability boundaries.
#
# =====================================================================
# IMPORTANT: crash-consistency correctness prerequisite
# =====================================================================
#
# The crash-consistency harness reports PASS when oracles succeed
# against every replayed snapshot state. That report is only
# meaningful if each `zfs snapshot` taken here corresponds to a
# **genuine durability boundary** of the underlying storage. For ZFS
# that means:
#
#   1. The ZIL has been flushed for all synchronous writes issued by
#      Postgres up to the snapshot point (i.e. the data returned by
#      fsync() is durable, not merely queued).
#   2. The txg containing those writes has committed — `zpool sync`
#      style guarantees — so that a clone of the snapshot replays to
#      the same state a post-crash import would land in.
#
# If you snapshot from inside a running txg without syncing, you are
# effectively testing an arbitrary intermediate in-memory state, not
# a crash-consistent one. The harness cannot detect that from the
# outside; it will happily report PASS or FAIL on a state that has
# no operational meaning.
#
# See ./README.md ("Why this abstraction exists") for the general
# version of this argument.
#
# =====================================================================

set -euo pipefail

ADAPTER_ID="${HARNESS_ADAPTER_ID:-crash-harness}"

# TODO: set these for your DBLab / ZFS environment.
ZFS_POOL="${HARNESS_ZFS_POOL:-dblab_pool}"
ZFS_DATASET="${HARNESS_ZFS_DATASET:-${ZFS_POOL}/${ADAPTER_ID}}"
MOUNT_BASE="${HARNESS_MOUNT_BASE:-/var/lib/dblab/${ADAPTER_ID}}"

log() { printf '[%s] %s\n' "${ADAPTER_ID}" "$*" >&2; }

cmd_setup() {
    # TODO: create (or locate) a fresh ZFS dataset to back the
    # Postgres data directory. Example outline:
    #
    #   zfs create -o mountpoint="${MOUNT_BASE}/data" \
    #              -o compression=lz4 \
    #              -o recordsize=8K \
    #              "${ZFS_DATASET}"
    #
    # Return the *block device* path OR set ADAPTER_REPLAY_MODE=mount
    # and return the mountpoint directly. DBLab typically uses
    # mountpoints, not raw block devices, so the `mount` mode is the
    # natural fit.
    log "TODO: provision ZFS dataset ${ZFS_DATASET}"
    log "TODO: export ADAPTER_REPLAY_MODE=mount if returning a path"
    echo "${MOUNT_BASE}/data"
}

cmd_attach() {
    # ZFS-backed adapters have their own crash-consistency machinery
    # (ZIL + txg commits), so no external write log is attached.
    # This verb is a deliberate no-op.
    log "attach: no-op (ZFS supplies its own durability boundaries)"
}

cmd_snapshot() {
    local name="${1:?snapshot name required}"
    # TODO: ensure we are at a durability boundary before snapping.
    #
    #   sync            # flush Postgres' issued writes down to ZFS
    #   zpool sync "${ZFS_POOL}"  # force the current txg to commit
    #   zfs snapshot "${ZFS_DATASET}@${name}"
    #
    # Without the sync + zpool sync, the snapshot may capture an
    # in-memory txg that has not yet committed — which is NOT a
    # crash-consistent state from the harness's point of view. See
    # the top-of-file comment and ./README.md.
    log "TODO: zpool sync ${ZFS_POOL} && zfs snapshot ${ZFS_DATASET}@${name}"
}

cmd_replay() {
    local name="${1:?snapshot name required}"
    # TODO: clone the snapshot into a disposable dataset and emit
    # the mount path. Outline:
    #
    #   local clone="${ZFS_DATASET}-replay-${name}"
    #   local mnt="${MOUNT_BASE}/replay-${name}"
    #   zfs clone -o mountpoint="${mnt}" \
    #             "${ZFS_DATASET}@${name}" "${clone}"
    #   echo "${mnt}"
    #
    # Signal mount-mode so the harness uses the path directly instead
    # of trying to mount it as a block device.
    export ADAPTER_REPLAY_MODE=mount
    log "TODO: zfs clone ${ZFS_DATASET}@${name} -> ${MOUNT_BASE}/replay-${name}"
    echo "${MOUNT_BASE}/replay-${name}"
}

cmd_teardown() {
    # TODO: destroy clones first, then snapshots, then the primary
    # dataset. Must be idempotent; the harness may call teardown
    # after a partial or crashed previous run.
    #
    #   for c in $(zfs list -H -o name -t filesystem \
    #                | grep "^${ZFS_DATASET}-replay-"); do
    #       zfs destroy -r "${c}" || true
    #   done
    #   for s in $(zfs list -H -o name -t snapshot \
    #                | grep "^${ZFS_DATASET}@"); do
    #       zfs destroy "${s}" || true
    #   done
    #   zfs destroy -r "${ZFS_DATASET}" || true
    log "TODO: destroy clones, snapshots, and the primary dataset"
}

verb="${1:-}"; shift || true
case "${verb}" in
    setup)    cmd_setup "$@" ;;
    attach)   cmd_attach "$@" ;;
    snapshot) cmd_snapshot "$@" ;;
    replay)   cmd_replay "$@" ;;
    teardown) cmd_teardown "$@" ;;
    *)
        echo "usage: $0 {setup|attach <log-dev>|snapshot <name>|replay <name>|teardown}" >&2
        exit 2
        ;;
esac
