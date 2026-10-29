# Copyright (c) 2026, PostgreSQL Global Development Group

"""Compare idle transaction snapshots in extended and simple query protocols."""

import os
from pathlib import Path
import select
import subprocess

import pytest

from pypg.paths import BINDIR


def has_snapshot(pg, pid):
    return pg.sql(
        "SELECT backend_xmin IS NOT NULL FROM pg_stat_activity WHERE pid = $1",
        pid,
    )


def test_extended_query_portal_snapshot(pg):
    conn = pg.connect()
    pid = conn.sql("SELECT pg_backend_pid()")
    conn.sql_batch("BEGIN", "SELECT txid_current()")
    try:
        assert has_snapshot(pg, pid)
        conn.close_portal("")
        assert not has_snapshot(pg, pid)
        assert pg.sql(
            "SELECT backend_xid IS NOT NULL AND state = 'idle in transaction' "
            "FROM pg_stat_activity WHERE pid = $1", pid,
        )
    finally:
        conn.sql("ROLLBACK")


@pytest.mark.skipif(os.name == "nt", reason="select() on a pipe requires POSIX")
def test_psql_releases_statement_snapshot(pg):
    proc = subprocess.Popen(
        [str(Path(BINDIR) / "psql"), "-X", "-qAt", "-v", "ON_ERROR_STOP=1",
         "-f", "-", "-d", pg.connstr()],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True,
    )
    try:
        proc.stdin.write("BEGIN;\nSELECT pg_backend_pid(), txid_current();\n")
        proc.stdin.flush()
        ready, _, _ = select.select([proc.stdout], [], [], 10)
        assert ready, "psql did not complete the statement"
        pid, xid = map(int, proc.stdout.readline().strip().split("|"))
        assert xid > 0
        # Query output can arrive before ReadyForQuery. Wait until the server
        # is idle in the transaction before inspecting its released snapshot.
        pg.poll_query_until(
            "SELECT state = 'idle in transaction' "
            "FROM pg_stat_activity WHERE pid = $1", pid,
        )
        assert not has_snapshot(pg, pid)
        assert pg.sql(
            "SELECT backend_xid IS NOT NULL FROM pg_stat_activity WHERE pid = $1",
            pid,
        )
    finally:
        try:
            proc.communicate("ROLLBACK;\n\\q\n", timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
    assert proc.returncode == 0
