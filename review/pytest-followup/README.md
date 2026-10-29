# Pytest follow-up: technical context and test results

This note accompanies two candidate patches for Jelte Fennema-Nio's [Python/pytest framework v2](https://www.postgresql.org/message-id/DMGSKK1XAEBJ.2I8XZ0MXQCXP0%40jeltef.nl). They address test-framework behavior and add a protocol comparison; they do not fix a PostgreSQL server defect.

The [earlier three-test conversion pilot (PR 125)](https://github.com/NikolayS/postgres/pull/125) already noted both the timeout-consumption limitation and the pg_visibility portal adjustment. This follow-up supplies the candidate timeout fix and focused regression/comparison tests on the unmodified v2 base, independently of that pilot. The bulk-conversion observation is source inspection; the protocol comparison below is the executed evidence.

## Patch base and order

Both patches apply incrementally to Jelte's `pytest-minimal-rewrite` branch at base commit [`1d2adb67c551bca8da2b8f2980545c78dc86340b`](https://github.com/JelteF/postgres/commit/1d2adb67c551bca8da2b8f2980545c78dc86340b). They are independent of the earlier three-test conversion pilot. Apply the future-outcome patch first, then the snapshot comparison:

1. [followup-fix-pytest-future-timeout.patch](followup-fix-pytest-future-timeout.patch) (candidate commit `74d33c28b721db9355ad5030ffa3c57c9d062fb2`), SHA-256 `5c6e2670dfa218cc13987b6e51169544d806eacebb15e4edd148625f2ca07133`.
2. [followup-test-pytest-portal-snapshot.patch](followup-test-pytest-portal-snapshot.patch) (candidate commit `467b0809935751c8864bcc6391d5aa1fcfc393d9`), SHA-256 `ed26d189c911cd513d93a11790676d3c682acf638dccc6796d2e4a78f65b11ca`.

The resulting source tree is `07aef5313877602c13b82cceaa0ba885a1255d47`. The patch files are identified by their names and hashes so the exact attachments can be checked independently. This directory adds documentation and copies of the patches after the tested source commit; it does not change the tested implementation.

## What the patches cover

The first patch fixes a consumption-boundary error in the framework's background-query future. In the v2 implementation, `result(timeout=...)` and `exception(timeout=...)` mark the result consumed before waiting. If the wait times out or is interrupted while the query is still running, the connection guard can treat the query as consumed even though no outcome was retrieved. The patch consumes only a completed result or actual cancellation. Its regression cases cover pending waits, completion during timeout unwinding, completed result and exception payloads, cancellation, signal interruption, and a query blocked on an advisory lock. The live test checks the connection guard without issuing a competing libpq call.

The second patch tests documented unnamed-portal behavior and compares the two query protocols. The bulk conversion at [`8a8f008f759615d1b8a575ec28f568f10c606379`](https://github.com/JelteF/postgres/commit/8a8f008f759615d1b8a575ec28f568f10c606379), [`contrib/pg_visibility/pyt/test_001_concurrent_transaction.py`](https://github.com/JelteF/postgres/blob/8a8f008f759615d1b8a575ec28f568f10c606379/contrib/pg_visibility/pyt/test_001_concurrent_transaction.py), uses `sql_batch("BEGIN", "SELECT txid_current()")` and leaves the extended-protocol unnamed portal open. In the paired Perl test, psql completes those statements using the simple query protocol. The comparison observes that the extended-protocol session retains `backend_xmin` until `close_portal("")`, while psql releases the statement snapshot after reaching idle-in-transaction. Closing the portal clears `backend_xmin` while the transaction and assigned XID remain. The patch adds regression coverage for this existing contract; it does not change the portal implementation. See the framework's [`close_portal()` source at the base commit](https://github.com/JelteF/postgres/blob/1d2adb67c551bca8da2b8f2980545c78dc86340b/src/test/pytest/libpq/_core.py) and [Tom Lane's explanation of portal snapshot lifetime](https://www.postgresql.org/message-id/19116.1531425938%40sss.pgh.pa.us).

## Reproduction and executed validation

Use the [framework README at the pinned base](https://github.com/JelteF/postgres/blob/1d2adb67c551bca8da2b8f2980545c78dc86340b/src/test/pytest/README) for build prerequisites. Apply the two linked files in the order above to the exact base, or check out candidate commit `467b0809935751c8864bcc6391d5aa1fcfc393d9` in this fork. The earlier conversion pilot is not required.

The tested source was the clean application of the two patches, built with assertions on macOS arm64 using Apple clang 17.0.0 and PostgreSQL 20devel; tests used Python 3.9.6 and pytest 8.4.2. The exact two-file command, run from the patched source root with the installed build and pytest on `PATH`, was:

```sh
pytest src/test/pytest/pyt/test_future.py \
    src/test/pytest/pyt/test_portal_snapshot.py
```

It passed all 22 cases. Against the unchanged base, the complete future test file had 8 failures and 12 passes; with the patch, all 20 future cases passed. Both snapshot-comparison cases pass on the base and patched trees. For the baseline comparison, the identical final test files were run with framework modules from the unchanged base; the tests are new and do not already exist there. The 22 new cases also passed through Meson and Make installcheck. Core regression passed 239 cases and isolation passed 134.

The wider registered test selection ran 67 entries: 58 passed, 2 failed, and 7 recovery scripts skipped because injection points were unavailable. The two failing entries also fail on the unchanged base: `test_029_stats_restart` and four AIO checksum cases. They share the Python 3.9 `datetime.fromisoformat()` incompatibility with PostgreSQL `+00` timestamp text; neither patch changes timestamp conversion. The corrected AIO run had 28 passing cases, those same 4 failures, and 25 skipped subcases for unavailable io_uring or injection-point support. The corrected wait-for-LSN run passed 5 cases and skipped 1 injection-point case. These 26 Python subcase skips are separate from the seven whole-script skips. No build with those optional capabilities enabled was tested. The psql pipe/select comparison skips on Windows; these results do not establish Windows coverage. These limitations are separate from the 22 passing new cases.

## Source references

- [Framework v2 message and discussion](https://www.postgresql.org/message-id/DMGSKK1XAEBJ.2I8XZ0MXQCXP0%40jeltef.nl)
- [Pinned v2 framework base](https://github.com/JelteF/postgres/commit/1d2adb67c551bca8da2b8f2980545c78dc86340b)
- [Framework libpq implementation at the base](https://github.com/JelteF/postgres/blob/1d2adb67c551bca8da2b8f2980545c78dc86340b/src/test/pytest/libpq/_core.py)
- [Bulk pg_visibility conversion under discussion](https://github.com/JelteF/postgres/blob/8a8f008f759615d1b8a575ec28f568f10c606379/contrib/pg_visibility/pyt/test_001_concurrent_transaction.py)
- [Portal snapshot behavior explained on pgsql-hackers](https://www.postgresql.org/message-id/19116.1531425938%40sss.pgh.pa.us)
