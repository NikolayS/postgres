# Copyright (c) 2026, PostgreSQL Global Development Group

"""Retrieving a background outcome, rather than attempting to wait, consumes it."""

from concurrent.futures import CancelledError, Future, TimeoutError
import signal

import pytest

from libpq import UnconsumedResultError
from libpq._core import PGconn, _MustConsumeFuture


@pytest.mark.parametrize("method", ["result", "exception"])
def test_pending_timeout(method):
    future = _MustConsumeFuture(["pending query"])
    with pytest.raises(TimeoutError):
        getattr(future, method)(timeout=0)
    assert not future.consumed

    # Finishing after a timeout must not silently discard a later query error.
    future.set_exception(ValueError("query failed later"))
    conn = object.__new__(PGconn)
    conn._pending = future
    with pytest.raises(UnconsumedResultError, match="never consumed"):
        conn._check_pending()
    assert isinstance(future.exception(), ValueError)
    conn._check_pending()
    assert conn._pending is None


@pytest.mark.parametrize("method", ["result", "exception"])
def test_completion_during_timeout_unwind(method, monkeypatch):
    future = _MustConsumeFuture(["query completing after timeout"])

    # Force completion after the stdlib wait times out, before our wrapper
    # handles the timeout. Checking done() in a finally block loses the error.
    def wrap(wait):
        def timed_wait(self, timeout=None):
            try:
                return wait(self, timeout)
            except TimeoutError:
                self.set_exception(ValueError("query failed after wait"))
                raise
        return timed_wait

    monkeypatch.setattr(Future, "result", wrap(Future.result))
    monkeypatch.setattr(Future, "exception", wrap(Future.exception))
    with pytest.raises(TimeoutError):
        getattr(future, method)(timeout=0)
    assert future.done()
    assert not future.consumed


@pytest.mark.parametrize("method", ["result", "exception"])
@pytest.mark.parametrize("error", [None, ValueError, TimeoutError, CancelledError, KeyboardInterrupt])
def test_completed_outcome(method, error):
    future = _MustConsumeFuture(["finished query"])
    if error is None:
        future.set_result(42)
        assert getattr(future, method)() == (42 if method == "result" else None)
    else:
        payload = error("query outcome")
        future.set_exception(payload)
        if method == "result":
            with pytest.raises(error) as caught:
                future.result()
            assert caught.value is payload
        else:
            assert future.exception() is payload
    assert future.consumed


@pytest.mark.parametrize("method", ["result", "exception"])
def test_cancelled_outcome(method):
    future = _MustConsumeFuture(["cancelled query"])
    assert future.cancel()
    with pytest.raises(CancelledError):
        getattr(future, method)()
    assert future.consumed


@pytest.mark.skipif(not hasattr(signal, "setitimer"), reason="requires interval timers")
@pytest.mark.parametrize("method", ["result", "exception"])
def test_interrupted_wait(method):
    future = _MustConsumeFuture(["interrupted wait"])

    def interrupt(signum, frame):
        raise KeyboardInterrupt

    old_handler = signal.signal(signal.SIGALRM, interrupt)
    old_timer = signal.getitimer(signal.ITIMER_REAL)
    try:
        signal.setitimer(signal.ITIMER_REAL, 0.02)
        with pytest.raises(KeyboardInterrupt):
            getattr(future, method)(timeout=2)
    finally:
        signal.setitimer(signal.ITIMER_REAL, *old_timer)
        signal.signal(signal.SIGALRM, old_handler)
    assert not future.consumed


@pytest.mark.parametrize("method", ["result", "exception"])
def test_connection_stays_guarded_after_timeout(pg, method):
    blocker = pg.connect()
    waiter = pg.connect()
    pid = waiter.sql("SELECT pg_backend_pid()")
    # Limit cleanup time if the test itself fails to release its lock.
    waiter.sql("SET statement_timeout = '30s'")
    blocker.sql("SELECT pg_advisory_lock(12345)")
    future = waiter.background_sql("SELECT pg_advisory_lock(12345)")
    try:
        pg.poll_query_until(
            "SELECT wait_event = 'advisory' FROM pg_stat_activity WHERE pid = $1",
            pid,
        )
        with pytest.raises(TimeoutError):
            getattr(future, method)(timeout=0)
        # Exercise the real connection guard without issuing a second libpq
        # command if the guard is broken on the unfixed framework.
        with pytest.raises(UnconsumedResultError, match="still busy"):
            waiter._check_pending()
    finally:
        blocker.sql("SELECT pg_advisory_unlock(12345)")
        future.result(timeout=30)
    assert waiter.sql("SELECT 42") == 42
    assert waiter.sql("SELECT pg_advisory_unlock(12345)")
