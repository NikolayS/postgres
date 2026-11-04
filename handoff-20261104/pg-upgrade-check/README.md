# pg_upgrade --check gaps, 18 to 19 (dropped for 19)

Status: DROPPED. No email. On 2026-10-30 Masahiko Sawada wrote that these are not v19 bugs that must be fixed before release, and wants a general approach for v20.

- Thread: https://www.postgresql.org/message-id/flat/CAGRkXqT+5+mQhoKZFTiM4yOZtVV=NW506vDwFtVeG+VmL_W5wQ@mail.gmail.com
- Sawada, 2026-10-30 07:14 UTC: https://www.postgresql.org/message-id/CAD21AoBzdxOunP4YONbMuMGuCPJU1NF-iX5wt=kT+Z3-es0vmA@mail.gmail.com
- shihao zhong, 2026-11-01 00:21 UTC, agreed to drop the cast check and offered a v5 with only the standard_conforming_strings check for 19: https://www.postgresql.org/message-id/CAGRkXqRH3_KB6OjKOuXYWwChsOu9AviqXo7o66Ng5on+sbv=0Q@mail.gmail.com . No v5 posted as of 2026-11-04 03:03 UTC.
- Adesh T, 2026-10-30: pg_parameter_acl grants on removed GUCs also pass --check and fail restore (for the generic v20 check).

## What we tested

shihao's latest patch, nocfbot-v4-REL_19 (2026-10-29):
https://www.postgresql.org/message-id/attachment/207696/nocfbot-v4-REL_19-0001-pg_upgrade-Check-for-settings-and-casts-that-19-c.patch
SHA-256 e33ac9651196663e48a6b9ad972109e04a147b8faa92df436248ac4e88a334a3

- Unpatched: REL_19_STABLE 0e58f6d737515f6d7f5c910472ffe28dc6fa9f7b.
- Patched: same + the patch (commit e202632885fe7bfab42b2698201d847832fc2e5d; changed lines identical to the file).
- Old cluster: 18.3. Assertions on. Copy mode only.

| Case (sql/old-cluster-cases.sql) | 19 --check | 19 real upgrade | 19 + patch --check |
|---|---|---|---|
| clean | compatible | ok | compatible |
| standard_conforming_strings = off on role, database, function | compatible | fails: non-standard string literals are not supported | fails, names the role, database or function |
| escape_string_warning on role, database, function | compatible | fails: unrecognized configuration parameter | fails, names the object |
| create cast (uuid as bytea) | compatible | fails: cast from type uuid to type bytea already exists | fails, names the cast |

Patched tree: `meson test --suite setup --suite pg_upgrade`: Ok 11, Fail 0 (002_pg_upgrade 19 subtests including the patch's test).

Not tested: old clusters 17 and older, --link, --clone and --swap modes, pg_parameter_acl, lz4/zstd settings, default_with_oids.

## What remains

Nothing for 19. If shihao posts the scs-only v5, a rerun of the scs cases above against it is a small, useful test report. For v20, the generic stored-settings check (v3 series and Kirill Reshke's value-validation diff) is the place to help.

## SHA-256 of the files in this directory (except this README)

```
1c14036bec07e507a4959718824efa56388f499f971cbc2f5de49d6ddcbbb9bd  EVIDENCE.md
ede8ae8088a96ac29f88c24866f1b9b816abdd1512714b77151071ef1b0e0d6d  sql/old-cluster-cases.sql
```
