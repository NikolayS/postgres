# PostgreSQL hackers hand-off, 2026-11-04 (PG19 first)

PG19 dates: wrap 2026-11-09, RC2 2026-11-12, GA 2026-11-19.

Nothing in this directory has been sent to the list. Each `draft.txt` starts with a header block (To, Cc, Subject, In-Reply-To, attachments) followed by the exact body.

| Directory | Thread | State |
|---|---|---|
| json-array-rel19-float-arrays | JSON_ARRAY() REL_19 float/bytea/geometric arrays | READY to send |
| partition-key-simplification | Partition key and constraint simplification (Robert Haas) | READY to send |
| not-enforced-inherited-check | NOT ENFORCED inherited CHECK, v3 | READY to send |
| wait-events-logging-v9 | Wait events for logging writes, v9 test report (CF 6819) | READY to send |
| cf7400-notnull-simplification | CF 7400 follow-up series | in progress |
| pg-upgrade-check | pg_upgrade --check gaps 18 to 19 | dropped for 19 |
| small-items | CF 6992, cast plan cache, CF 7443, CF 6045 | replies and fixes owed |

Earlier hand-offs: https://github.com/NikolayS/postgres/issues/129 and https://github.com/NikolayS/postgres/issues/130
