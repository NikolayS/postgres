#!/usr/bin/env python3
# src/test/crash_harness/harness.py
#
# dm-log-writes crash-consistency harness for PostgreSQL.
#
# Orchestrates record/replay of filesystem writes via dm-log-writes, mounts
# each replayed "what-if-power-cut-here" image, starts Postgres on it, and
# runs a suite of oracles to verify crash consistency.
#
# Linux-only. Requires: dm-log-writes kernel module (linux-modules-extra),
# dmsetup, losetup, mkfs.ext4, replay-log (josefbacik/log-writes), PG 16+.
#
# See README.md for the "why" and quick-start.
# See issue NikolayS/postgres#31 for full background.
#
# Python 3, stdlib only. No third-party deps on purpose (easy to drop into CI).

from __future__ import annotations

import argparse
import errno
import json
import os
import random
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator

# -----------------------------------------------------------------------------
# Globals & utilities
# -----------------------------------------------------------------------------

HARNESS_VERSION = "0.1.0"
DEFAULT_TARGET = "crash-harness"
DEFAULT_MOUNT = "/mnt/crash-harness"
DEFAULT_REPLAY_MOUNT = "/mnt/crash-harness-replay"
DEFAULT_PG_PORT = 55432

JSON_MODE = False  # toggled by --json


def log(event: str, **fields: Any) -> None:
    """Single log channel. Emits JSON lines in --json mode, else human text.

    JSON-mode output is line-delimited and stable (keys sorted) so callers can
    pipe through `jq` or friends.
    """
    if JSON_MODE:
        payload = {"ts": time.time(), "event": event, **fields}
        sys.stdout.write(json.dumps(payload, sort_keys=True, default=str) + "\n")
        sys.stdout.flush()
    else:
        extra = " ".join(f"{k}={v}" for k, v in fields.items())
        sys.stdout.write(f"[{event}] {extra}\n")
        sys.stdout.flush()


def die(msg: str, **fields: Any) -> "NoReturn":  # type: ignore[name-defined]
    log("fatal", msg=msg, **fields)
    sys.exit(2)


def require_linux() -> None:
    if sys.platform != "linux":
        die("linux_required", platform=sys.platform,
            hint="dm-log-writes is a Linux device-mapper target; no macOS/Win port")


def require_root() -> None:
    if os.geteuid() != 0:
        die("root_required",
            hint="dmsetup/losetup/mount need CAP_SYS_ADMIN; run under sudo")


def which_or_die(cmd: str) -> str:
    p = shutil.which(cmd)
    if not p:
        die("missing_tool", tool=cmd)
    return p


def run(cmd: list[str] | str, *, check: bool = True, capture: bool = False,
        timeout: float | None = None, env: dict[str, str] | None = None,
        cwd: str | None = None, input_bytes: bytes | None = None,
        ) -> subprocess.CompletedProcess:
    """Wrapped subprocess.run with consistent logging + error handling."""
    if isinstance(cmd, str):
        shown = cmd
        shell = True
    else:
        shown = " ".join(shlex.quote(c) for c in cmd)
        shell = False
    log("cmd", argv=shown)
    t0 = time.time()
    try:
        cp = subprocess.run(
            cmd, shell=shell, check=False,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            timeout=timeout, env=env, cwd=cwd, input=input_bytes,
        )
    except subprocess.TimeoutExpired as e:
        die("cmd_timeout", argv=shown, timeout=timeout, partial=str(e))
    dt = time.time() - t0
    if check and cp.returncode != 0:
        log("cmd_failed", argv=shown, rc=cp.returncode, dt=f"{dt:.2f}s",
            stderr=(cp.stderr or b"").decode("utf-8", "replace")[-2000:])
        die("cmd_failed", argv=shown, rc=cp.returncode)
    log("cmd_ok", argv=shown, rc=cp.returncode, dt=f"{dt:.2f}s")
    return cp


@contextmanager
def tempmount(device: str, mountpoint: str) -> Iterator[str]:
    os.makedirs(mountpoint, exist_ok=True)
    run(["mount", device, mountpoint])
    try:
        yield mountpoint
    finally:
        # Best-effort; a caller may have left pg running on it.
        subprocess.run(["umount", "-f", mountpoint], check=False)


# -----------------------------------------------------------------------------
# Device setup & teardown (setup / teardown subcommands)
# -----------------------------------------------------------------------------

def parse_size(s: str) -> int:
    """Accept e.g. 8G, 4096M, 1048576 (bytes). Return bytes."""
    s = s.strip().upper()
    m = re.fullmatch(r"(\d+)([KMGT]?)B?", s)
    if not m:
        die("bad_size", value=s)
    n = int(m.group(1))
    mult = {"": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}[m.group(2)]
    return n * mult


def losetup_find_or_attach(img: str) -> str:
    """Return /dev/loopN for img, attaching if not already attached."""
    cp = run(["losetup", "-j", img], capture=True)
    out = cp.stdout.decode()
    if out.strip():
        # `backing.img: [fd00]:123 (/dev/loop3)`
        m = re.match(r"(/dev/loop\d+):", out.splitlines()[0])
        if m:
            return m.group(1)
    cp = run(["losetup", "-f", "--show", img], capture=True)
    return cp.stdout.decode().strip()


def blockdev_sectors(dev: str) -> int:
    cp = run(["blockdev", "--getsz", dev], capture=True)
    return int(cp.stdout.decode().strip())


def dm_exists(name: str) -> bool:
    cp = subprocess.run(["dmsetup", "info", name], check=False,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return cp.returncode == 0


def cmd_setup(args: argparse.Namespace) -> int:
    require_linux()
    require_root()
    for t in ("losetup", "dmsetup", "mkfs." + args.fs):
        which_or_die(t)

    backing = os.path.abspath(args.backing)
    logimg = os.path.abspath(args.log)
    os.makedirs(os.path.dirname(backing) or ".", exist_ok=True)
    os.makedirs(os.path.dirname(logimg) or ".", exist_ok=True)

    for path, size in [(backing, args.backing_size), (logimg, args.log_size)]:
        if not os.path.exists(path):
            run(["truncate", "-s", str(parse_size(size)), path])
        else:
            log("reuse_image", path=path)

    back_dev = losetup_find_or_attach(backing)
    log_dev = losetup_find_or_attach(logimg)
    sectors = blockdev_sectors(back_dev)

    if dm_exists(args.target_name):
        log("dm_reuse", name=args.target_name)
    else:
        # dm-log-writes table: "0 <sz> log-writes <data_dev> <log_dev>"
        table = f"0 {sectors} log-writes {back_dev} {log_dev}"
        run(["dmsetup", "create", args.target_name, "--table", table])

    dev = f"/dev/mapper/{args.target_name}"

    # mkfs only if the first 1 KiB is zero (fresh image). Cheap + idempotent.
    with open(dev, "rb") as f:
        head = f.read(1024)
    if head == b"\x00" * 1024:
        run([f"mkfs.{args.fs}", "-F", dev])
    else:
        log("fs_reuse", dev=dev)

    log("setup_done", dm_device=dev, backing=back_dev, log=log_dev,
        sectors=sectors)
    if not JSON_MODE:
        print(dev)
    return 0


def cmd_teardown(args: argparse.Namespace) -> int:
    require_linux()
    require_root()
    # Unmount anything on our mountpoints
    for mp in (args.mount, DEFAULT_REPLAY_MOUNT):
        if mp and os.path.ismount(mp):
            subprocess.run(["umount", "-f", mp], check=False)

    for name in (args.target_name, args.target_name + "-replay"):
        if dm_exists(name):
            subprocess.run(["dmsetup", "remove", "-f", name], check=False)

    # Detach any loop devices pointing to our images.
    for img in (args.backing, args.log):
        if img and os.path.exists(img):
            cp = subprocess.run(["losetup", "-j", img], check=False,
                                capture_output=True)
            for line in cp.stdout.decode().splitlines():
                m = re.match(r"(/dev/loop\d+):", line)
                if m:
                    subprocess.run(["losetup", "-d", m.group(1)], check=False)
    log("teardown_done")
    return 0


# -----------------------------------------------------------------------------
# dm-log-writes mark helpers
# -----------------------------------------------------------------------------

def dm_mark(target: str, name: str) -> None:
    """Emit a named 'mark' entry into the write log."""
    safe = re.sub(r"[^A-Za-z0-9_.:-]", "_", name)[:64]
    run(["dmsetup", "message", target, "0", "mark", safe])
    log("mark", name=safe)


def list_marks(log_device: str, replay_log_bin: str) -> list[str]:
    """Parse marks from the log device using `replay-log --find --end-mark *`.

    replay-log doesn't expose a first-class list command; we emulate by asking
    for each candidate. As a cheap alternative we run a non-destructive replay
    against /dev/null and grep its verbose output. If that's not supported in
    the installed replay-log, fall back to marks tracked in a sidecar file.
    """
    sidecar = log_device + ".marks"
    if os.path.exists(sidecar):
        with open(sidecar) as f:
            return [l.strip() for l in f if l.strip()]
    # Best-effort probe via replay-log -v; works with recent josefbacik/log-writes.
    try:
        cp = subprocess.run(
            [replay_log_bin, "--log", log_device, "--find", "--end-mark", "END"],
            check=False, capture_output=True, timeout=60,
        )
        marks = re.findall(rb"mark\s+(\S+)", cp.stdout + cp.stderr)
        return [m.decode() for m in marks]
    except FileNotFoundError:
        return []


def record_mark(log_device: str, name: str) -> None:
    """Append to sidecar so `replay all` can iterate even if replay-log lacks
    a list command."""
    sidecar = log_device + ".marks"
    with open(sidecar, "a") as f:
        f.write(name + "\n")


# -----------------------------------------------------------------------------
# record: initdb + run workload while sprinkling marks
# -----------------------------------------------------------------------------

def initdb(pgdata: str, pg_bin: str) -> None:
    os.makedirs(pgdata, exist_ok=True)
    # -k enables checksums; we want to exercise them.
    run([os.path.join(pg_bin, "initdb"), "-D", pgdata, "-k",
         "--username=postgres", "--auth-local=trust", "--auth-host=trust"])


def pg_ctl(pgdata: str, pg_bin: str, action: str, *, logfile: str | None = None,
           opts: str | None = None, timeout: int = 60) -> None:
    cmd = [os.path.join(pg_bin, "pg_ctl"), "-D", pgdata, "-w", "-t", str(timeout),
           action]
    if logfile:
        cmd += ["-l", logfile]
    if opts:
        cmd += ["-o", opts]
    run(cmd)


def cmd_record(args: argparse.Namespace) -> int:
    require_linux()
    require_root()
    which_or_die("dmsetup")

    dm_dev = f"/dev/mapper/{args.target_name}"
    if not os.path.exists(dm_dev):
        die("no_dm_device", dev=dm_dev, hint="run `setup` first")

    os.makedirs(args.mount, exist_ok=True)
    if not os.path.ismount(args.mount):
        run(["mount", dm_dev, args.mount])
    pgdata = os.path.join(args.mount, args.pgdata_subdir)
    log_device = args.log  # image path; we use sidecar for marks

    # Reset marks sidecar for this recording.
    sidecar = log_device + ".marks"
    if os.path.exists(sidecar):
        os.unlink(sidecar)

    def mark(name: str) -> None:
        dm_mark(args.target_name, name)
        record_mark(log_device, name)

    pg_bin = args.pg_bin
    mark("phase:pre-initdb")
    if not os.path.exists(os.path.join(pgdata, "PG_VERSION")):
        initdb(pgdata, pg_bin)
    mark("phase:post-initdb")

    pglog = os.path.join(args.mount, "postgres.log")
    pg_ctl(pgdata, pg_bin, "start", logfile=pglog,
           opts=f"-p {args.port} -c unix_socket_directories={args.mount}")
    mark("phase:pg-started")

    env = os.environ.copy()
    env["PGPORT"] = str(args.port)
    env["PGHOST"] = args.mount
    env["PGUSER"] = "postgres"
    env["PGDATABASE"] = "postgres"
    env["CRASH_HARNESS_TARGET"] = args.target_name
    env["CRASH_HARNESS_LOG"] = log_device
    env["CRASH_HARNESS_MOUNT"] = args.mount
    env["CRASH_HARNESS_PG_BIN"] = pg_bin

    # Run workload. If --random-every is set, run the workload under a
    # background "mark sprinkler" that emits marks at random intervals.
    stop_sprinkler = None
    sprinkler_proc = None
    if args.random_every and args.random_every > 0:
        sprinkler_proc = _spawn_sprinkler(args.target_name, log_device,
                                          args.random_every, args.random_jitter)

    try:
        mark("phase:workload-start")
        run(["bash", args.workload_script], env=env,
            timeout=args.workload_timeout)
        mark("phase:workload-end")
    finally:
        if sprinkler_proc is not None:
            sprinkler_proc.terminate()
            try:
                sprinkler_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                sprinkler_proc.kill()

    # Final CHECKPOINT (best-effort) and a "final" mark.
    try:
        run([os.path.join(pg_bin, "psql"), "-h", args.mount, "-p",
             str(args.port), "-U", "postgres", "-d", "postgres",
             "-c", "CHECKPOINT;"], check=False)
    except Exception as e:  # noqa: BLE001
        log("checkpoint_skip", err=str(e))
    mark("phase:final")

    pg_ctl(pgdata, pg_bin, "stop", opts="-m fast", timeout=120)
    mark("phase:pg-stopped")

    # Unmount so nothing is dirty against the dm device for replay experiments.
    run(["umount", args.mount])
    log("record_done", marks_file=sidecar)
    return 0


def _spawn_sprinkler(target: str, log_device: str, every: int, jitter: float
                     ) -> subprocess.Popen:
    """Background process that emits a mark every N seconds (+/- jitter).

    Implemented as a subprocess so we can signal it cleanly, and so it runs
    while the workload script has the foreground.
    """
    script = f"""
import os, random, subprocess, sys, time
every = {every}
jitter = {jitter}
target = {target!r}
log_device = {log_device!r}
sidecar = log_device + '.marks'
i = 0
while True:
    time.sleep(max(0.1, every + random.uniform(-jitter, jitter)))
    i += 1
    name = f'rand:{{i}}:{{int(time.time())}}'
    subprocess.run(['dmsetup', 'message', target, '0', 'mark', name],
                   check=False)
    try:
        with open(sidecar, 'a') as f:
            f.write(name + chr(10))
    except Exception:
        pass
"""
    return subprocess.Popen([sys.executable, "-c", script])


# -----------------------------------------------------------------------------
# replay: call replay-log, mount, run oracles
# -----------------------------------------------------------------------------

def cmd_replay(args: argparse.Namespace) -> int:
    require_linux()
    require_root()
    replay_log = which_or_die(args.replay_log_bin)

    log_device_img = args.log
    replay_img = args.replay_image
    if not os.path.exists(replay_img):
        # Create a replay image sized like the backing file.
        size = os.path.getsize(args.backing)
        run(["truncate", "-s", str(size), replay_img])
    replay_dev = losetup_find_or_attach(replay_img)

    marks_to_run: list[str]
    if args.end_mark == "all":
        marks_to_run = list_marks(log_device_img, replay_log) or ["phase:final"]
    else:
        marks_to_run = [args.end_mark]

    overall_ok = True
    results: list[dict[str, Any]] = []
    for mark in marks_to_run:
        log("replay_begin", mark=mark, replay_dev=replay_dev)
        # Re-initialize the replay image: either by starting from zero and
        # replaying up to `mark`, or by using --start-mark from the previous
        # one. We choose the simpler "from scratch" form for correctness.
        run([replay_log, "--log", log_device_img, "--replay", replay_dev,
             "--end-mark", mark])

        # fsck the replayed FS to catch filesystem-level inconsistencies
        # that Postgres would never see but still indicate a corruption bug.
        fsck = subprocess.run(["e2fsck", "-fy", replay_dev], check=False,
                              capture_output=True)
        log("e2fsck", mark=mark, rc=fsck.returncode,
            out=fsck.stdout.decode("utf-8", "replace")[-400:])

        mount_ok = True
        oracle_results: dict[str, dict[str, Any]] = {}
        try:
            with tempmount(replay_dev, args.replay_mount):
                if args.verify:
                    oracle_results = run_all_oracles(
                        args, mount=args.replay_mount,
                        pgdata=os.path.join(args.replay_mount,
                                            args.pgdata_subdir))
        except Exception as e:  # noqa: BLE001
            mount_ok = False
            oracle_results = {"mount": {"ok": False, "err": str(e)}}

        ok = mount_ok and all(r.get("ok", False) for r in oracle_results.values())
        overall_ok = overall_ok and ok
        entry = {"mark": mark, "ok": ok, "oracles": oracle_results,
                 "e2fsck_rc": fsck.returncode}
        results.append(entry)
        log("replay_result", **entry)

    # Detach replay loop device.
    subprocess.run(["losetup", "-d", replay_dev], check=False)

    log("replay_done", ok=overall_ok, n=len(results))
    if JSON_MODE:
        sys.stdout.write(json.dumps({"summary": {"ok": overall_ok,
                                                  "results": results}},
                                    sort_keys=True, default=str) + "\n")
    return 0 if overall_ok else 1


# -----------------------------------------------------------------------------
# Oracles
# -----------------------------------------------------------------------------

def run_all_oracles(args: argparse.Namespace, *, mount: str, pgdata: str
                    ) -> dict[str, dict[str, Any]]:
    """Start Postgres on the replayed image and run each oracle. Stops PG at
    the end. A failure in any oracle is reported; we run all of them.
    """
    pg_bin = args.pg_bin
    pglog = os.path.join(mount, "postgres-replay.log")
    # First oracle runs without a live PG: it reads the startup log after start.
    # So we record the state of the log before starting.
    results: dict[str, dict[str, Any]] = {}

    # Guard against broken pgdata (e.g. no PG_VERSION)
    if not os.path.exists(os.path.join(pgdata, "PG_VERSION")):
        return {"precondition": {"ok": False,
                                  "err": f"no PG_VERSION in {pgdata}"}}

    start_env = os.environ.copy()
    start_env["PGPORT"] = str(args.port)
    try:
        pg_ctl(pgdata, pg_bin, "start", logfile=pglog,
               opts=f"-p {args.port} -c unix_socket_directories={mount} "
                    "-c fsync=on",
               timeout=args.start_timeout)
        pg_running = True
    except SystemExit:
        pg_running = False

    results["recovery_completed"] = oracle_recovery_completed(pglog)
    if not pg_running:
        # If PG refused to start, the remaining oracles that need SQL can't run.
        results["amcheck_clean"] = {"ok": False, "err": "pg not running"}
        results["checksum_scan"] = {"ok": False, "err": "pg not running"}
        results["catalog_fs_crosscheck"] = oracle_catalog_fs_crosscheck_fs_only(
            pgdata)
        results["readdir_open_sanity"] = oracle_readdir_open_sanity(pgdata)
        results["committed_xact_visibility"] = {"ok": True,
                                                "skipped": "pg not running"}
        return results

    try:
        results["amcheck_clean"] = oracle_amcheck_clean(args, mount)
        results["checksum_scan"] = oracle_checksum_scan(args, mount)
        results["catalog_fs_crosscheck"] = oracle_catalog_fs_crosscheck(
            args, mount, pgdata)
        results["readdir_open_sanity"] = oracle_readdir_open_sanity(pgdata)
        results["committed_xact_visibility"] = oracle_committed_xact_visibility(
            args, mount)
    finally:
        subprocess.run([os.path.join(pg_bin, "pg_ctl"), "-D", pgdata,
                        "-m", "fast", "-w", "-t", "60", "stop"],
                       check=False)
    return results


# -- oracle 1: recovery_completed --------------------------------------------

_STARTUP_READY_RE = re.compile(r"database system is ready to accept connections")
_AUTOMATIC_RECOVERY_RE = re.compile(
    r"(automatic recovery in progress|redo starts at|starting archive recovery)")


def oracle_recovery_completed(log_path: str, *, deadline_s: float = 60.0
                              ) -> dict[str, Any]:
    """Grep the startup log for evidence of automatic recovery + ready.

    We don't require automatic recovery (a clean shutdown + start won't have
    it), but if recovery markers appear, a "ready" line must follow them.
    """
    t0 = time.time()
    saw_recovery = False
    saw_ready = False
    last = ""
    while time.time() - t0 < deadline_s:
        try:
            with open(log_path, "r", errors="replace") as f:
                last = f.read()
        except FileNotFoundError:
            time.sleep(0.2)
            continue
        if _AUTOMATIC_RECOVERY_RE.search(last):
            saw_recovery = True
        if _STARTUP_READY_RE.search(last):
            saw_ready = True
        if saw_ready:
            break
        time.sleep(0.2)
    ok = saw_ready  # recovery markers optional
    return {"ok": ok, "saw_recovery": saw_recovery, "saw_ready": saw_ready,
            "log_tail": last[-500:]}


# -- oracle 2: amcheck_clean -------------------------------------------------

def _psql(mount: str, port: int, sql: str, *, db: str = "postgres",
          pg_bin: str = "") -> subprocess.CompletedProcess:
    bin_psql = os.path.join(pg_bin, "psql") if pg_bin else "psql"
    return subprocess.run(
        [bin_psql, "-h", mount, "-p", str(port), "-U", "postgres",
         "-d", db, "-At", "-X", "-v", "ON_ERROR_STOP=1", "-c", sql],
        check=False, capture_output=True, timeout=300,
    )


def oracle_amcheck_clean(args: argparse.Namespace, mount: str) -> dict[str, Any]:
    pg_bin = args.pg_bin
    # Install extension on all non-template DBs. We enumerate then CREATE
    # EXTENSION IF NOT EXISTS in each.
    dbs_cp = _psql(mount, args.port,
                   "SELECT datname FROM pg_database WHERE datallowconn",
                   pg_bin=pg_bin)
    if dbs_cp.returncode != 0:
        return {"ok": False, "err": "cannot list dbs",
                "stderr": dbs_cp.stderr.decode("utf-8", "replace")[-400:]}
    dbs = [d for d in dbs_cp.stdout.decode().splitlines() if d]
    for db in dbs:
        cp = _psql(mount, args.port, "CREATE EXTENSION IF NOT EXISTS amcheck",
                   db=db, pg_bin=pg_bin)
        if cp.returncode != 0:
            # amcheck missing => skip cleanly (still report OK=false so a user
            # can see it). Contrib build may not be installed.
            return {"ok": False, "err": "amcheck not available",
                    "db": db,
                    "stderr": cp.stderr.decode("utf-8", "replace")[-400:]}

    bin_amcheck = os.path.join(pg_bin, "pg_amcheck") if pg_bin else "pg_amcheck"
    cp = subprocess.run(
        [bin_amcheck, "-h", mount, "-p", str(args.port), "-U", "postgres",
         "--all", "--no-dependent-indexes"],
        check=False, capture_output=True, timeout=900,
    )
    ok = (cp.returncode == 0 and not cp.stderr.strip())
    return {"ok": ok, "rc": cp.returncode,
            "stdout_tail": cp.stdout.decode("utf-8", "replace")[-800:],
            "stderr_tail": cp.stderr.decode("utf-8", "replace")[-800:]}


# -- oracle 3: checksum_scan -------------------------------------------------

_CHECKSUM_SCAN_SQL = r"""
DO $$
DECLARE
    r record;
    n bigint;
BEGIN
    FOR r IN
        SELECT c.oid::regclass AS rel
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r','m','t')
          AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
    LOOP
        EXECUTE format('SELECT count(*) FROM ONLY %s', r.rel) INTO n;
    END LOOP;
END $$;
"""


def oracle_checksum_scan(args: argparse.Namespace, mount: str
                         ) -> dict[str, Any]:
    pg_bin = args.pg_bin
    # Iterate user DBs
    dbs_cp = _psql(mount, args.port,
                   "SELECT datname FROM pg_database WHERE datallowconn",
                   pg_bin=pg_bin)
    dbs = [d for d in dbs_cp.stdout.decode().splitlines() if d]
    errs: list[dict[str, Any]] = []
    for db in dbs:
        cp = _psql(mount, args.port, _CHECKSUM_SCAN_SQL, db=db, pg_bin=pg_bin)
        if cp.returncode != 0:
            errs.append({"db": db,
                         "stderr": cp.stderr.decode("utf-8", "replace")[-400:]})
    return {"ok": not errs, "errors": errs}


# -- oracle 4: catalog_fs_crosscheck -----------------------------------------

# Files under base/<dboid>/ that are not relfilenodes and must be ignored.
# Naming rules from src/backend/access/common/reloptions.c, storage/file/.
_BASE_IGNORE_SUFFIXES = ("_fsm", "_vm", "_init")
_BASE_IGNORE_EXACT = {"PG_VERSION", "pg_filenode.map", "pg_internal.init"}


def _is_base_segment(filename: str) -> tuple[bool, str]:
    """Is this a relfilenode main/segment file? Returns (is_main_or_seg,
    base_relfilenode_str).

    Main fork: "<N>"
    Seg:       "<N>.<M>"
    FSM:       "<N>_fsm", "<N>_fsm.<M>"
    VM:        "<N>_vm", "<N>_vm.<M>"
    init fork: "<N>_init"
    """
    if filename in _BASE_IGNORE_EXACT:
        return (False, "")
    if filename.startswith("pgsql_tmp"):
        return (False, "")
    m = re.fullmatch(r"(\d+)(?:\.(\d+))?", filename)
    if m:
        return (True, m.group(1))
    m = re.fullmatch(r"(\d+)_(?:fsm|vm|init)(?:\.(\d+))?", filename)
    if m:
        return (False, m.group(1))  # recognized but not main fork
    return (False, "")


def oracle_catalog_fs_crosscheck(args: argparse.Namespace, mount: str,
                                 pgdata: str) -> dict[str, Any]:
    pg_bin = args.pg_bin
    sql = (
        "SELECT d.oid::text, d.datname, c.relname, "
        "       CASE WHEN c.relfilenode=0 "
        "            THEN pg_relation_filenode(c.oid) "
        "            ELSE c.relfilenode END::text "
        "FROM pg_database d "
        "CROSS JOIN LATERAL ("
        "    SELECT relname, relfilenode, oid FROM pg_class"
        ") c "
        "WHERE d.datallowconn"
    )
    # Per-database enumeration (pg_class is per-DB). Cross-database lateral
    # join isn't possible; so iterate dbs client-side.
    missing: list[dict[str, Any]] = []
    unknown: list[dict[str, Any]] = []

    dbs_cp = _psql(mount, args.port,
                   "SELECT oid, datname FROM pg_database WHERE datallowconn",
                   pg_bin=pg_bin)
    dbs = [tuple(l.split("|")) for l in dbs_cp.stdout.decode().splitlines()
           if l]

    catalog_nodes: dict[str, set[str]] = {}
    for dboid, dbname in dbs:
        cp = _psql(mount, args.port,
                   "SELECT "
                   " CASE WHEN relfilenode=0 "
                   "      THEN pg_relation_filenode(oid) "
                   "      ELSE relfilenode END::text, "
                   " relname "
                   "FROM pg_class "
                   "WHERE relkind IN ('r','i','m','t','S')",
                   db=dbname, pg_bin=pg_bin)
        if cp.returncode != 0:
            return {"ok": False, "err": f"pg_class query failed for {dbname}",
                    "stderr": cp.stderr.decode("utf-8", "replace")[-400:]}
        nodes = set()
        for row in cp.stdout.decode().splitlines():
            parts = row.split("|", 1)
            if parts and parts[0].strip() and parts[0].strip() != "0":
                nodes.add(parts[0].strip())
        catalog_nodes[dboid] = nodes

    # For each relfilenode, at least the base file must exist.
    for dboid, nodes in catalog_nodes.items():
        dbdir = os.path.join(pgdata, "base", dboid)
        for node in nodes:
            main_path = os.path.join(dbdir, node)
            if not os.path.exists(main_path):
                missing.append({"db": dboid, "relfilenode": node,
                                "expected": main_path})

    # For each file under base/<dboid>/, a pg_class entry must reference it
    # (or it must match an ignored pattern).
    base_dir = os.path.join(pgdata, "base")
    if os.path.isdir(base_dir):
        for dboid_entry in os.scandir(base_dir):
            if not dboid_entry.is_dir():
                continue
            dboid = dboid_entry.name
            nodes = catalog_nodes.get(dboid, set())
            for ent in os.scandir(dboid_entry.path):
                if not ent.is_file():
                    continue
                is_main, base_node = _is_base_segment(ent.name)
                if ent.name in _BASE_IGNORE_EXACT:
                    continue
                if base_node and base_node not in nodes:
                    unknown.append({"db": dboid, "file": ent.name,
                                    "path": ent.path})

    ok = not missing and not unknown
    return {"ok": ok, "missing": missing[:20], "unknown": unknown[:20],
            "n_missing": len(missing), "n_unknown": len(unknown)}


def oracle_catalog_fs_crosscheck_fs_only(pgdata: str) -> dict[str, Any]:
    """Degenerate variant: PG not running, just sanity-check the FS tree has
    the files we'd expect by structure (PG_VERSION, pg_control, pg_wal/)."""
    required = ["PG_VERSION", "global/pg_control", "pg_wal"]
    missing = [p for p in required if not os.path.exists(os.path.join(pgdata, p))]
    return {"ok": not missing, "missing_core": missing, "skipped_full": True}


# -- oracle 5: readdir_open_sanity (the headline oracle for P1) --------------

def oracle_readdir_open_sanity(pgdata: str) -> dict[str, Any]:
    """Walk pgdata; for every dirent returned by scandir, attempt an open.

    A file listed by readdir that fails with ENOENT/EIO/EACCES on open is the
    signature bug the storage layer can produce when directory entries persist
    independently of inodes. This oracle is why P1 exists.
    """
    failures: list[dict[str, Any]] = []
    checked = 0

    def walk(root: str) -> None:
        nonlocal checked
        try:
            with os.scandir(root) as it:
                entries = list(it)
        except OSError as e:
            failures.append({"path": root, "op": "scandir", "errno": e.errno,
                             "err": os.strerror(e.errno or 0)})
            return
        for ent in entries:
            checked += 1
            path = ent.path
            try:
                if ent.is_dir(follow_symlinks=False):
                    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
                    os.close(fd)
                    walk(path)
                elif ent.is_file(follow_symlinks=False):
                    fd = os.open(path, os.O_RDONLY)
                    os.close(fd)
                elif ent.is_symlink():
                    # Don't chase symlinks; just confirm lstat works.
                    os.lstat(path)
                # sockets (postmaster.pid sibling) get skipped – not fatal
            except OSError as e:
                if e.errno in (errno.ENOENT, errno.EIO, errno.EACCES):
                    failures.append({
                        "path": path, "op": "open",
                        "errno": e.errno,
                        "err": os.strerror(e.errno or 0),
                        "kind": ("dir" if ent.is_dir(follow_symlinks=False)
                                 else "file")})
                # other errnos (e.g. EPERM on special files) are not the bug
                # class we care about; ignore.

    walk(pgdata)
    return {"ok": not failures, "checked": checked, "failures": failures[:50],
            "n_failures": len(failures)}


# -- oracle 6: committed_xact_visibility -------------------------------------

def oracle_committed_xact_visibility(args: argparse.Namespace, mount: str
                                      ) -> dict[str, Any]:
    pg_bin = args.pg_bin
    marker = os.path.join(mount, "workload_committed_xids.log")
    if not os.path.exists(marker):
        return {"ok": True, "skipped": "no workload_committed_xids.log"}
    missing: list[str] = []
    with open(marker) as f:
        xids = [l.strip() for l in f if l.strip().isdigit()]
    for xid in xids:
        cp = _psql(mount, args.port,
                   f"SELECT pg_xact_status({xid}::xid)", pg_bin=pg_bin)
        status = cp.stdout.decode().strip()
        if status != "committed":
            missing.append(f"{xid}:{status or cp.stderr.decode()[:100]}")
    return {"ok": not missing, "n_checked": len(xids), "missing": missing[:20]}


# -----------------------------------------------------------------------------
# argparse setup
# -----------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="harness.py",
        description="dm-log-writes crash-consistency harness for Postgres")
    p.add_argument("--json", action="store_true",
                   help="emit JSON lines on stdout")
    p.add_argument("--version", action="version",
                   version=f"%(prog)s {HARNESS_VERSION}")
    sub = p.add_subparsers(dest="cmd", required=True)

    # setup
    s = sub.add_parser("setup", help="create loop devices + dm-log-writes")
    s.add_argument("--backing", required=True, help="path to backing file")
    s.add_argument("--log", required=True, help="path to log-writes log file")
    s.add_argument("--backing-size", default="8G")
    s.add_argument("--log-size", default="4G")
    s.add_argument("--fs", default="ext4")
    s.add_argument("--target-name", default=DEFAULT_TARGET)
    s.set_defaults(func=cmd_setup)

    # record
    r = sub.add_parser("record", help="run initdb + workload with marks")
    r.add_argument("--pgdata", dest="pgdata_subdir", default="pgdata",
                   help="subdir of mountpoint for PGDATA")
    r.add_argument("--mount", default=DEFAULT_MOUNT)
    r.add_argument("--target-name", default=DEFAULT_TARGET)
    r.add_argument("--log", required=True,
                   help="log-writes image path (for mark sidecar)")
    r.add_argument("--backing", required=False, default=None,
                   help="kept for CLI symmetry with setup; not used here")
    r.add_argument("--pg-bin", default="/usr/lib/postgresql/16/bin",
                   help="dir containing initdb/pg_ctl/psql/pg_amcheck")
    r.add_argument("--port", type=int, default=DEFAULT_PG_PORT)
    r.add_argument("--workload-script",
                   default=str(Path(__file__).parent / "workloads/default.sh"))
    r.add_argument("--workload-timeout", type=int, default=600)
    r.add_argument("--random-every", type=int, default=0,
                   help="emit random marks every N seconds (0 disables)")
    r.add_argument("--random-jitter", type=float, default=1.0,
                   help="uniform jitter on --random-every")
    r.set_defaults(func=cmd_record)

    # replay
    rp = sub.add_parser("replay", help="replay log to a mark; run oracles")
    rp.add_argument("--log", required=True, help="log-writes image path")
    rp.add_argument("--backing", required=True,
                    help="original backing image (for sizing replay image)")
    rp.add_argument("--replay-image", required=True,
                    help="path to replay image file (will be created)")
    rp.add_argument("--replay-mount", default=DEFAULT_REPLAY_MOUNT)
    rp.add_argument("--replay-log-bin", default="replay-log",
                    help="path to replay-log binary (josefbacik/log-writes)")
    rp.add_argument("--replay-to-mark", dest="end_mark", required=True,
                    help="target mark name, or 'all'")
    rp.add_argument("--pgdata", dest="pgdata_subdir", default="pgdata")
    rp.add_argument("--pg-bin", default="/usr/lib/postgresql/16/bin")
    rp.add_argument("--port", type=int, default=DEFAULT_PG_PORT)
    rp.add_argument("--start-timeout", type=int, default=120)
    rp.add_argument("--verify", action="store_true",
                    help="run oracles after mount (default off)")
    rp.set_defaults(func=cmd_replay)

    # teardown
    t = sub.add_parser("teardown", help="unmount + dmsetup remove + losetup -d")
    t.add_argument("--mount", default=DEFAULT_MOUNT)
    t.add_argument("--backing", default="")
    t.add_argument("--log", default="")
    t.add_argument("--target-name", default=DEFAULT_TARGET)
    t.set_defaults(func=cmd_teardown)

    return p


def main(argv: list[str] | None = None) -> int:
    global JSON_MODE
    parser = build_parser()
    args = parser.parse_args(argv)
    JSON_MODE = bool(getattr(args, "json", False))
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
