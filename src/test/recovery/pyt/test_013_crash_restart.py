# Copyright (c) 2021-2026, PostgreSQL Global Development Group

"""Port of src/test/recovery/t/013_crash_restart.pl.

Tests that the postmaster performs a crash-restart cycle when a backend dies
unexpectedly (SIGQUIT and SIGKILL of a backend), that committed data survives
while in-progress transactions do not, that shared_preload_libraries are
re-initialized, and that background workers (the logical replication launcher)
come back.

Two sessions are used as in the Perl test: ``killme`` holds the backend that
gets signalled, and a separate background query plays the "monitor" role: its
failure signals that the crash-restart has begun.
"""

import pytest

from libpq import LibpqError
from pypg import wait_until

# A killed backend may only be able to report loss of the connection.
CONNECTION_LOST = (
    "server closed the connection unexpectedly"
    "|connection to server was lost"
    "|could not send data to server"
    "|no connection to the server"
)
SIGQUIT_OR_LOST = (
    "terminating connection because of unexpected SIGQUIT signal|" + CONNECTION_LOST
)
PEER_CRASH_OR_LOST = (
    "terminating connection because of crash of another server process|"
    + CONNECTION_LOST
)


def wait_for_reconnect(node):
    """Poll, reconnecting each attempt, until the server accepts queries again.

    Uses a fresh one-shot connection each attempt, since the cached sql()
    connection is the one pointing at the crashed backend. Once the server is
    back, also drop that stale cached connection so the caller's subsequent
    node.sql() calls open a fresh one instead of hitting the same dead socket.
    """
    for _ in wait_until("server did not come back after crash"):
        try:
            if node.sql_oneshot("SELECT 1") == 1:
                node.close_default_conn()
                return
        except LibpqError:
            pass


def test_crash_restart(create_pg):
    node = create_pg(
        "primary",
        allows_streaming=True,
        conf={
            "shared_preload_libraries": "pg_stat_statements",
            "pg_stat_statements.max": 50000,
            "compute_query_id": "regress",
        },
    )

    # PostgresServer does not restart after a crash by default.
    node.sql("ALTER SYSTEM SET restart_after_crash = 1")
    node.sql("ALTER SYSTEM SET log_connections = receipt")
    node.sql("SELECT pg_reload_conf()")

    node.sql("CREATE EXTENSION pg_stat_statements")
    # Compare the server text, as the Perl test does.
    stats_reset = node.sql("SELECT stats_reset::text FROM pg_stat_statements_info")

    killme = node.connect()

    # A row that must survive the crash, plus the pid we will signal.
    killme.sql("CREATE TABLE alive(status text)")
    killme.sql("INSERT INTO alive VALUES('committed-before-sigquit')")
    pid = killme.sql("SELECT pg_backend_pid()")

    # A row in an in-progress transaction, which must NOT survive.
    killme.sql("BEGIN")
    assert (
        killme.sql(
            "INSERT INTO alive VALUES('in-progress-before-sigquit') RETURNING status"
        )
        == "in-progress-before-sigquit"
    )

    # Long-running query in the monitor session; its failure signals the crash.
    monitor = node.connect(application_name="crash_monitor")
    monitor_pid = monitor.sql("SELECT pg_backend_pid()")
    monitor_future = monitor.background_sql("SELECT pg_sleep(3600)")
    node.poll_query_until(
        "SELECT wait_event = 'PgSleep' FROM pg_stat_activity WHERE pid = $1",
        monitor_pid,
    )

    node.pg_ctl("kill", "QUIT", str(pid))

    with pytest.raises(LibpqError, match=SIGQUIT_OR_LOST):
        killme.sql("SELECT 1")
    with pytest.raises(LibpqError, match=PEER_CRASH_OR_LOST):
        monitor_future.result()

    wait_for_reconnect(node)

    # The crashed session is gone; open a fresh one for the SIGKILL round.
    killme = node.connect()

    # shared_preload_libraries were re-initialized: pg_stat_statements reset.
    stats_reset_after = node.sql("SELECT stats_reset::text FROM pg_stat_statements_info")
    assert stats_reset != stats_reset_after, "pg_stat_statements was reset by restart"

    pid = killme.sql("SELECT pg_backend_pid()")

    assert (
        killme.sql(
            "INSERT INTO alive VALUES('committed-before-sigkill') RETURNING status"
        )
        == "committed-before-sigkill"
    )
    killme.sql("BEGIN")
    assert (
        killme.sql(
            "INSERT INTO alive VALUES('in-progress-before-sigkill') RETURNING status"
        )
        == "in-progress-before-sigkill"
    )

    monitor = node.connect(application_name="crash_monitor")
    monitor_pid = monitor.sql("SELECT pg_backend_pid()")
    monitor_future = monitor.background_sql("SELECT pg_sleep(3600)")
    node.poll_query_until(
        "SELECT wait_event = 'PgSleep' FROM pg_stat_activity WHERE pid = $1",
        monitor_pid,
    )

    node.pg_ctl("kill", "KILL", str(pid))

    # No WARNING after SIGKILL: signal handlers do not run.
    with pytest.raises(LibpqError, match=CONNECTION_LOST):
        killme.sql("SELECT 1")
    with pytest.raises(LibpqError, match=PEER_CRASH_OR_LOST):
        monitor_future.result()

    wait_for_reconnect(node)

    # Committed rows survived, in-progress ones did not.
    assert node.sql("SELECT * FROM alive") == [
        "committed-before-sigquit",
        "committed-before-sigkill",
    ], "data survived"

    assert (
        node.sql("INSERT INTO alive VALUES('before-orderly-restart') RETURNING status")
        == "before-orderly-restart"
    ), "can still write after crash restart"

    # The logical replication launcher (a restartable background worker) is back.
    node.poll_query_until(
        "SELECT count(*) = 1 FROM pg_stat_activity "
        "WHERE backend_type = 'logical replication launcher'"
    )

    # An orderly restart still works.
    node.pg_ctl("restart")

    assert node.sql("SELECT * FROM alive") == [
        "committed-before-sigquit",
        "committed-before-sigkill",
        "before-orderly-restart",
    ], "data survived"

    assert (
        node.sql("INSERT INTO alive VALUES('after-orderly-restart') RETURNING status")
        == "after-orderly-restart"
    ), "can still write after orderly restart"

    node.stop()
