# Evidence: pg_upgrade --check, 18 to 19

## Builds

meson debug, -Dcassert=true -Dtap_tests=enabled -Dicu=enabled, Apple clang 17.0.0, macOS arm64, version 19rc1. Old cluster: Homebrew 18.3, own data directory, ports 50432 (old) and 50433 (new).

## Command per case

```
pg_upgrade -b <18 bindir> -B <19 bindir> -d old -D new -U postgres -s /tmp -p 50432 -P 50433 --check
pg_upgrade -b <18 bindir> -B <19 bindir> -d old -D new -U postgres -s /tmp -p 50432 -P 50433
```

Fresh old and new clusters for every case and every build.

## Outputs

| Case | Unpatched --check | Unpatched upgrade | Patched --check |
|---|---|---|---|
| clean | `*Clusters are compatible*`, exit 0 | exit 0 | compatible, both new checks ok |
| scs_role | exit 0 | exit 1: `pg_upgrade_dump_globals.sql:36: ERROR:  non-standard string literals are not supported` | exit 1, list: `role app: standard_conforming_strings=off` |
| scs_db | exit 0 | exit 1, same error in the database restore | exit 1, `database appdb: standard_conforming_strings=off` |
| scs_func | exit 0 | exit 1, same error | exit 1, `function public.f(): standard_conforming_strings=off` |
| esw_role | exit 0 | exit 1: `ERROR:  unrecognized configuration parameter "escape_string_warning"` | exit 1, `role app: escape_string_warning=off` |
| esw_db | exit 0 | exit 1, same | exit 1, `database appdb: escape_string_warning=on` |
| esw_func | exit 0 | exit 1, same | exit 1, `function public.f(): escape_string_warning=off` |
| cast | exit 0 | exit 1: `ERROR:  cast from type uuid to type bytea already exists` | exit 1, `cast from uuid to bytea` |

The patched real upgrade runs the same checks first, so it stops before any copy.

## Patched --check message (settings)

```
Your installation contains roles, databases, or functions that set
standard_conforming_strings to off or set escape_string_warning.
These settings are no longer supported, so the upgrade would fail.
Remove them with ALTER ... RESET and restart the upgrade.
```

## Suite

`meson test -C build --suite setup --suite pg_upgrade` on the patched tree: Ok 11, Fail 0.

## Upstream check

git log on master and REL_19_STABLE since 2026-10-25 for src/bin/pg_upgrade: only 6cda9dfc4f9 (tests, initdb template for older installations), unrelated.

## Not run

regress, isolation, check-world; an unpatched TAP baseline.
