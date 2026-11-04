# Evidence: wait events for logging writes, v9

macOS arm64, Apple clang 17.0.0, meson debug builds with assertions (-Dcassert=true), server version 20devel.

## Inputs (SHA-256)

- v9-0001 (attachment 203833): 1526ae99aadc3c75c02831997090b7426065798e62ee97c07d3c16b24c38befa
- v9-0002 (attachment 203834): 62458d6b92cc60f1d73ef371ed4adbf9b9861903f10277f554ac3b1a3204593b
- v8-0001 (attachment 203691): 6c7c88e4ceeb76447a9aa6c52c4e8b26219ca1029df852e7e4c0c915591ad0c4
- v8-0002 (attachment 203692): c9e64a486590a3c647a258320d57bc567c10aba8c6733334d5d51d32437d2dfa

## Trees

```
base 35273454065e6b7f07984e70ac131ce710e6f380 (master)
v8   = base + dc50b2509cf6 + 22e6dc96ab19   (git am v8-0001 v8-0002: clean, 2 files, +54)
v9   = base + b711e344f1b6 + a14dc8a8a48d   (git am v9-0001 v9-0002: clean, 3 files, +109 -1)
meson setup build -Dcassert=true -Ddebug=true; ninja install
```

No warnings in elog.c or wait_event.h.

## Check

The test module sets an extension wait event, calls ereport(LOG), sleeps inside the region, then ends it. A second session samples pg_stat_activity while the first one sleeps. Fresh initdb per destination. Delivery of the log line was confirmed in the destination file for stderr, csvlog and jsonlog. For syslog, `log stream` on macOS captured the line from the backend for both v8 and v9.

Run 1 (sample at 3.3 s; 24 runs, all exit 0):

```
v8: t+0.15s  active | Timeout   | PgSleep
    t+3.3s   active |           |
    t+10.3s  active | Timeout   | PgSleep
v9: t+0.15s  active | Timeout   | PgSleep
    t+3.3s   active | Extension | <outer event>
    t+10.3s  active | Timeout   | PgSleep
```

Run 2 (separate build and module, sample at 2.5 s):

```
v8 | stderr_collector_off | active | NULL      | NULL
v8 | stderr_collector_on  | active | NULL      | NULL
v8 | csvlog               | active | NULL      | NULL
v8 | jsonlog              | active | NULL      | NULL
v8 | all_three            | active | NULL      | NULL
v8 | syslog               | active | NULL      | NULL
v9 | stderr_collector_off | active | Extension | <outer event>
v9 | stderr_collector_on  | active | Extension | <outer event>
v9 | csvlog               | active | Extension | <outer event>
v9 | jsonlog              | active | Extension | <outer event>
v9 | all_three            | active | Extension | <outer event>
v9 | syslog               | active | Extension | <outer event>
```

Unpatched master equals v9 in every case. A control function that raises and catches an ERROR inside the region (no log write) shows the outer event on all three builds; it does not exercise the logging path.

## Regression suite

v9: `meson test -C build --suite setup --suite regress`: Ok 4, Fail 0, 239 subtests.

## Code read (v9)

- pgstat_report_wait_start_nested(info) reads *my_wait_event_info, stores info, returns the old value. pgstat_report_wait_end_nested(outer) stores outer. Both static inline: one extra volatile 32-bit load, no branch, no call, no atomics.
- Wrapped sites (elog.c): write_syslog() openlog() and two syslog() calls (SyslogWrite); write_pipe_chunks() two write() calls (SysloggerWrite); write_console() write() (StderrWrite) and in 0002 WriteConsoleW() (StderrWrite); in 0002 write_eventlog() ReportEventW() and ReportEventA() (EventlogWrite).
- Only leaf OS calls are wrapped. Nothing between start and end can ereport, so no path leaves start without end. quickdie() uses the same pair and then calls _exit().

## Duplicate check (2026-11-04 03:35 to 03:45 UTC)

- Flat thread: newest message Henson Choi 2026-11-03 09:55:49 UTC. No v10.
- CF 6819: PG20-3, Needs review.
- git log master since 2026-11-01 on elog.c, syslogger.c, wait_event_names.txt: no commits.
- Nik's mailbox: no reply from Nik after Henson's message, no earlier draft.

## Not run

Isolation, TAP, Windows, io_uring, other platforms.
