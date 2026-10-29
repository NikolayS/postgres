# Proposed patterns for Perl test conversions

This is a proposal for reviewing conversions against the Python framework. It
is not an agreed PostgreSQL migration policy. Keep the original test runnable
while comparing the two versions, and separate changes to test coverage from
changes in implementation language.

## Preserve the scenario before shortening the code

For each original test, list its setup, sessions, transaction boundaries,
synchronization points, expected failures, assertions, and cleanup. Map each
item to the proposed Python version. An assertion count alone is insufficient:
one Python assertion may replace several TAP assertions, or accidentally omit
part of their purpose.

| Original behavior | Python pattern | What needs review |
| --- | --- | --- |
| Initialize a stopped node | `create_pg(name, start=False)` | Do not start it early if the test examines its initial state. |
| Ordinary queries | `pg.sql(...)` | This reuses a connection and uses the extended query protocol. |
| Fresh session per call | `pg.sql_oneshot(...)` | Preserve session lifetime, identity, and disconnect effects. |
| Persistent background psql | `pg.connect(...)`, then session methods | Keep transactions and synchronization explicit; retain psql when its behavior is tested. |
| Command exit status or output | `pypg.bins` helpers | Invoke the actual program and preserve the intended output checks. |
| Streaming standby | Backup plus `create_pg(..., from_backup=..., streaming_primary=...)` | Preserve configuration, startup order, and the replay position checked. |
| Wait for replay or another process | Query/event/log polling | Wait for an observable condition, with a bounded deadline. |
| Error expected from SQL | `pytest.raises(LibpqError)` | Check SQLSTATE and any diagnostic fields relevant to the original assertion. |

## Choose ownership and fixture scope deliberately

The `pg` fixture shares a server within a test file. Connections and tracked
configuration changes have per-test cleanup, but SQL-created tables, databases,
roles, replication slots, and other catalog state persist. Clean them up or
choose separate servers when tests must be independent.

Use `create_pg` for a test-owned server, custom startup configuration, or a
multi-server scenario. Use `create_pg_module` only when sharing the setup is
intentional. Give factory-created servers names that are unique within the
file, including across parametrized invocations. Avoid turning an ordered
scenario into apparently independent tests that depend on each other's state.

Put required startup settings in `conf`. Use `start=False` for filesystem
preparation or startup failure tests, then start the server at the intended
point. For subsequent configuration edits, use the documented reload/restart
helpers so configuration restoration can track which action is needed.

## Preserve protocol and transaction boundaries

`sql()` sends one statement with bound parameters through libpq's extended
query protocol. Repeated calls reuse a cached session. `sql_batch()` is a
sequence of such calls; it is not a multi-statement simple-query message and
does not create a transaction around the sequence.

Inspect how the original psql invocation sends its SQL. A script on standard
input, a `-c` string, and an explicit transaction can have different transaction
boundaries. Do not mechanically replace all three with `sql_batch()`. Keep psql
for tests of its parsing, formatting, exit behavior, or protocol choices.

An extended-protocol statement can also leave its unnamed portal's snapshot
registered inside an explicit transaction. When the original test requires an
idle transaction with an assigned XID but no statement snapshot, finish the
statement with `conn.close_portal("")`. The concurrent pg_visibility example
needs this after `SELECT txid_current()`. Do not add it where retaining a portal
or snapshot is part of the test.

Use `simplify_result=False` when row count or row shape matters. This gives a
list of row tuples for both empty and nonempty results. If the original checks
text rendering, preserve that through psql or an explicit SQL cast rather than
silently comparing a different Python type.

## Coordinate background work explicitly

A background query and an observer need distinct connections. A synchronous
`connect()` establishes a session; dispatching background work does not by
itself prove that the server reached a particular statement or wait event.
Poll the relevant PID or other unique identifier when that distinction matters.

Consume every background future, including expected errors. Retain the original
distinction between errors on a directly killed backend and on a peer affected
by the crash. After a crash, reconnect through a fresh session and discard stale
cached connections before ordinary queries resume.

`PG_TEST_TIMEOUT_DEFAULT` controls connection and polling defaults. Avoid
hardcoding its current numeric value in a port. A polling deadline or a future
wait timeout does not cancel the underlying query. A server-side
`statement_timeout` cancels a statement but also changes its behavior, so use it
only where appropriate. Provide a release path for deliberately blocked work
and retain an outer test-process timeout.

The current framework needs further failure-path review before relying on a
caught future timeout followed by connection reuse. Do not treat a timed-out
wait as a completed query.

For asynchronous log output, capture the log position before the triggering
operation and use `wait_for_log()` or `log_contains(..., wait=True)`. An immediate
absence check proves absence only within the observed interval; waiting for a
positive synchronization event is usually necessary before checking absence.

## Preserve cleanup and build integration

End transactions and release intentional blockers on the normal path. Fixtures
own connection and server cleanup, but review what happens if setup, an
assertion, or a background query fails. In particular, a cleanup exception must
not be mistaken for proof that all servers stopped. Keep failed data directories
and useful logs available for diagnosis.

Register new files in the directory's Meson `pytest` test list. Wire the Make
`check` and `installcheck` paths too: standalone directories use `pytest_check`
and `pytest_installcheck`, while PGXS extensions use `PYTEST_TESTS = 1`. Retain
the original TAP registration during the comparison stage.

## Validate the behavior, including failure

Run both versions against the same compiled server revision and configuration.
Record interpreter versions, platform, optional features, skips, and the exact
commands. Run Meson's setup suite before a selected test invocation that needs
its temporary installation. Passing against a different installed PostgreSQL
is not a valid comparison.

Repeat timing-sensitive scenarios and use a small number of named fault
controls: for example, commit a row that should roll back, or introduce a known
visibility error. Both versions should reject the same violated invariant.
Coverage differences can direct investigation, but neither matching coverage
nor two green runs proves equivalence. Document remaining protocol, platform,
and failure-path differences for the reviewer.
