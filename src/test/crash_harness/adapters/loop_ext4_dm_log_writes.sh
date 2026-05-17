#!/usr/bin/env bash
#
# loop_ext4_dm_log_writes.sh
#
# Reference storage-adapter implementation for the crash-consistency
# harness. Wraps a loop-file-backed ext4 filesystem behind a
# dm-log-writes target, which is the default stack assumed by the
# harness (see ./README.md for the adapter contract).
#
# This file is intentionally small and readable top-to-bottom: it is
# the teaching example for implementers of other adapters (ZFS,
# btrfs, LVM-thin, vendor storage). Each of the five contract verbs
# (setup, attach, snapshot, replay, teardown) maps to one case
# branch.
#
# Requirements: Linux, dmsetup, losetup, a recent enough kernel with
# dm-log-writes compiled in. Run as root or via sudo.

set -euo pipefail

ADAPTER_ID="${HARNESS_ADAPTER_ID:-crash-harness}"
STATE_DIR="${HARNESS_STATE_DIR:-/var/tmp/${ADAPTER_ID}}"
DATA_SIZE="${HARNESS_DATA_SIZE:-2G}"

DATA_IMG="${STATE_DIR}/data.img"
LOG_IMG="${STATE_DIR}/log.img"
DATA_LOOP_TAG="${ADAPTER_ID}-data"
LOG_LOOP_TAG="${ADAPTER_ID}-log"
DM_DATA="${ADAPTER_ID}-data"      # dm-log-writes target
DM_REPLAY="${ADAPTER_ID}-replay"  # dm-linear target for replays

log() { printf '[%s] %s\n' "${ADAPTER_ID}" "$*" >&2; }

loop_for() {
    # Resolve the loop device backing a given tag (first match).
    losetup -a | awk -F: -v tag="$1" '$0 ~ tag {print $1; exit}'
}

cmd_setup() {
    mkdir -p "${STATE_DIR}"
    # Data volume.
    if [[ ! -f "${DATA_IMG}" ]]; then
        truncate -s "${DATA_SIZE}" "${DATA_IMG}"
    fi
    # Log volume for dm-log-writes; sized generously relative to data.
    if [[ ! -f "${LOG_IMG}" ]]; then
        truncate -s "${DATA_SIZE}" "${LOG_IMG}"
    fi

    losetup --find --show "${DATA_IMG}" >"${STATE_DIR}/data.loop"
    losetup --find --show "${LOG_IMG}"  >"${STATE_DIR}/log.loop"
    local data_loop log_loop
    data_loop="$(cat "${STATE_DIR}/data.loop")"
    log_loop="$(cat "${STATE_DIR}/log.loop")"

    # Stack dm-log-writes on top of the data loop; the first
    # argument after "log-writes" is the log device.
    local sectors
    sectors=$(blockdev --getsz "${data_loop}")
    dmsetup create "${DM_DATA}" --table \
        "0 ${sectors} log-writes ${data_loop} ${log_loop}"

    mkfs.ext4 -q -F "/dev/mapper/${DM_DATA}" >&2
    log "provisioned /dev/mapper/${DM_DATA} (data=${data_loop}, log=${log_loop})"
    printf '/dev/mapper/%s\n' "${DM_DATA}"
}

cmd_attach() {
    # The loop+dm-log-writes stack already has its log wired up at
    # setup time, so attach is a no-op here. Present for contract
    # uniformity with adapters that defer log-device wiring.
    log "attach: no-op (log device already wired by setup)"
}

cmd_snapshot() {
    local name="${1:?snapshot name required}"
    # dmsetup message places a named marker into the log stream.
    dmsetup message "${DM_DATA}" 0 "mark ${name}"
    log "marked snapshot ${name}"
}

cmd_replay() {
    local name="${1:?snapshot name required}"
    local log_loop
    log_loop="$(cat "${STATE_DIR}/log.loop")"

    # Produce a fresh data image by replaying the log up to the named
    # mark, using the bundled `replay-log` userspace tool that ships
    # with dm-log-writes (log-writes/src/replay-log.c in linux/tools).
    local replay_img="${STATE_DIR}/replay-${name}.img"
    cp --reflink=auto "${DATA_IMG}" "${replay_img}"
    local replay_loop
    replay_loop="$(losetup --find --show "${replay_img}")"

    # Roll writes forward up to the named mark.
    replay-log --log "${log_loop}" --replay "${replay_loop}" \
               --end-mark "${name}" >&2

    # Expose the replayed image under a stable dm-linear name so the
    # harness can mount it.
    local sectors
    sectors=$(blockdev --getsz "${replay_loop}")
    dmsetup create "${DM_REPLAY}-${name}" --table \
        "0 ${sectors} linear ${replay_loop} 0"
    printf '/dev/mapper/%s-%s\n' "${DM_REPLAY}" "${name}"
}

cmd_teardown() {
    # Remove any replay targets first (they reference loop devices
    # distinct from the primary data loop).
    for dm in $(dmsetup ls --target linear 2>/dev/null \
                 | awk -v p="${DM_REPLAY}-" '$1 ~ p {print $1}'); do
        dmsetup remove "${dm}" || true
    done
    # Primary data target.
    dmsetup remove "${DM_DATA}" 2>/dev/null || true
    # Detach loop devices.
    for f in "${STATE_DIR}"/*.loop; do
        [[ -f "${f}" ]] || continue
        losetup -d "$(cat "${f}")" 2>/dev/null || true
        rm -f "${f}"
    done
    # Detach any stray replay-img loops.
    for dev in $(losetup -a | awk -F: -v img="${STATE_DIR}/replay-" \
                 '$2 ~ img {print $1}'); do
        losetup -d "${dev}" || true
    done
    rm -f "${STATE_DIR}"/replay-*.img
    log "torn down"
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
