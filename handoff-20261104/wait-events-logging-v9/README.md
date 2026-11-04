# Wait events for server logging destination writes: v9 test report (CF 6819)

Status: READY to send. A saved Gmail draft dated 2026-11-04 exists in Nik's mailbox. Nik presses Send. No attachment.

- Thread: https://www.postgresql.org/message-id/flat/CACdN0M78U+GvpqA7oey-GA7fFSYM636aDp6H9FVvCztv9zXxSA@mail.gmail.com
- CommitFest: https://commitfest.postgresql.org/patch/6819/ (PG20-3, Needs review, author SeongJun Shin, Nik is a reviewer).
- Reply target: SeongJun Shin, 2026-10-29 05:00:29 UTC, Message-ID CACdN0M6QfkDmMYXQ5as4+dnZEg8tBExEAcedz8dEhH7vomX4aA@mail.gmail.com, which asks Nik for a rerun against v9.
- Latest series: v9, SeongJun Shin, 2026-09-15 (archive attachments 203833 and 203834). Copies in `reference/`.
- Henson Choi, 2026-11-03 09:55 UTC: a macro-based alternative, "not a blocker". Not tested.

## What we found

In September Nik reported that v8 loses an outer wait event: an extension sets its own wait event, calls ereport(LOG), and keeps waiting, but pg_stat_activity then shows an empty wait_event_type and wait_event. v9 adds pgstat_report_wait_start_nested() and pgstat_report_wait_end_nested(), which save and restore the outer value. v9 fixes it on every tested log destination. No new findings.

## Upstream commits tested

- master 35273454065e6b7f07984e70ac131ce710e6f380 (v9 was posted on 1a3e782e762; it applies and builds on the newer master).
- v9 tree: b711e344f1b6 + a14dc8a8a48d on 35273454065e. v8 tree: dc50b2509cf6 + 22e6dc96ab19 on 35273454065e. git patch-id of each commit equals the patch-id of the posted file.
- master head at the last check, 52b41da0be54f5df6708f95dc8bda73b8ae7c563, does not touch elog.c or wait_event.h after 35273454065e.

## Suites and results

Sample taken after ereport(LOG) returned, inside the extension's wait region:

| Log destination | master | v8 | v9 |
|---|---|---|---|
| stderr, logging_collector off | Extension / outer event | empty / empty | Extension / outer event |
| stderr, logging_collector on | same | empty | same |
| csvlog | same | empty | same |
| jsonlog | same | empty | same |
| stderr,csvlog,jsonlog | same | empty | same |
| syslog (macOS unified log) | same | empty | same |

- v9: `meson test --suite setup --suite regress` OK, 239 subtests.
- Two independent runs of the check agree (different sample times, 2.5 s and 3.3 s after the call).
- Not run: isolation, TAP, Windows (SeongJun reported a Windows CI run), the 0002 Windows sites at runtime, Henson's macro alternative.

## Files

- `reference/v9-0001-...patch`, `reference/v9-0002-...patch`: SeongJun's v9, unchanged.
- `outer_wait/`: the test module (PGXS) and `repro.sh`. This copy was renamed for the hand-off and was not compiled in this exact form; the module we ran differs only in names.

## What remains

1. Nik reviews the Gmail draft dated 2026-11-04 and presses Send.
2. Optional: write "syslog (macOS)" in the draft. Also optional: "From the tester's side I consider v9 ready" is based on one platform (macOS arm64); soften if wanted.
3. After send: the CF entry can go back to Ready for Committer if SeongJun or a reviewer sets it. We do not touch the CF app.

`draft.txt` is the exact email. `EVIDENCE.md` has the commands and outputs.

## SHA-256 of the files in this directory (except this README)

```
c23d6090d92f733209c6ced387c1165f1630fb6f7b98ab2adf49f14e8b3d5bc8  draft.txt
5252eab6c40a608a944541dc13263474631f077d08572de604836ccce72c2fca  EVIDENCE.md
7865eb674d2624142392ace30b5156d33c2569e54c324ed7a240e3014b9cb595  outer_wait/Makefile
996941c79933909e5b95b63b3edbefc7b319a9ec61192b230ab0d31e833617cb  outer_wait/outer_wait--1.0.sql
458d7a2f0e6cc7a3221ba02e2b9207072f6be9d0d4f8de94d2827f38c8d7f3b6  outer_wait/outer_wait.c
b689f4ebb0e9dce92865c41e34635d0a9df0e013c6cfabcfc589b39812b48cea  outer_wait/outer_wait.control
2804b245b5e409dd0bd61c040f2e13a9a321a2d007b00b44a95129031d8e4f08  outer_wait/repro.sh
1526ae99aadc3c75c02831997090b7426065798e62ee97c07d3c16b24c38befa  reference/v9-0001-Add-wait-events-for-server-logging-destination-wr.patch
62458d6b92cc60f1d73ef371ed4adbf9b9861903f10277f554ac3b1a3204593b  reference/v9-0002-Add-wait-events-for-Windows-specific-logging-outp.patch
```
