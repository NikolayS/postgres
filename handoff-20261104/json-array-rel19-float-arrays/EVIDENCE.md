# Evidence: JSON_ARRAY() REL_19 float/bytea/geometric arrays

All runs on macOS arm64, Apple clang 17.0.0, meson debug builds with assertions (-Dcassert=true), ICU on. Each cluster had its own data directory and port. 18.6 is the Homebrew build.

## Inputs (SHA-256)

- v5-0001 (archive attachment 208127): 4899241f4cbe160ca182d263a839b768848d226bb40b067dbc841d0e2fbb9387
- v5-0002 (archive attachment 208128): 04c9c847a352bae471dc3bef4d5d82fa092054216058901d1a87347c8954dc7d
- nocfbot-v5-REL_19-float-json-immutability.patch: f67dfa8e989f01c7ccb9a10def4d235ceeefc7836a5b63b7ab8460d999e878fd
- The patch's prerequisite-patch-id lines match `git patch-id --stable` of v5-0001 and v5-0002.

## Bases (fetched 2026-11-04 about 03:07 to 03:19 UTC)

- upstream/REL_19_STABLE 4b1abd678223ab22e1fe245547bf5b4a91db56ee
- upstream/master 52b41da0be54f5df6708f95dc8bda73b8ae7c563
- e75fcc9867fdfe295957ad5c9a98cbe2e1b4c5c3: `git merge-base --is-ancestor` says not in REL_19_STABLE. It changes provolatile from i to s for byteaout, point_out, lseg_out, path_out, box_out, float4out, float8out, poly_out, circle_out, line_out, pg_mcv_list_out and brin_minmax_multi_summary_out. The last two have no array type (typarray = 0), so the patch's list covers every array-reachable type.

## Trees

```
r19v5  = 4b1abd678223 + v5        (git am) -> fab3f2f633287a2d9b911f96b3f03c4c2be4b96a
r19fix = 4b1abd678223 + v5 + patch (git am) -> 67e046df27f7325186e0ea8087a2c40ca737b7ed
mv5    = 52b41da0be54 + v5        (git am) -> 888713e469a4fdb7506232c36e79452af4a92d02
meson setup build -Dcassert=true -Ddebug=true -Dicu=enabled && ninja -C build
```

No new warnings (only the usual macOS LDAP deprecations in libpq).

## The email's statements, run as written

| Tree | CREATE INDEX | index scan count | seq scan count |
|---|---|---|---|
| 19 + v5 | accepted | 0 (stale) | 1 |
| 19 + v5 + patch | ERROR: functions in index expression must be marked IMMUTABLE | n/a | 1 |
| master + v5 | same ERROR | n/a | 1 |
| 18.6 | same ERROR | n/a | 1 |

Extra cases: bytea[] with bytea_output = escape and point[] with extra_float_digits = 0 are stale on 19 + v5 and rejected on the other three. A domain over float8 inside an array, and a domain over float8[], are accepted on 19 + v5 and rejected elsewhere.

provolatile of float4out, float8out, byteaout, point_out: i on 19 + v5, 19 + patch and 18.6; s on master + v5.

## Red/green

```
git checkout HEAD~1 -- src/backend/utils/adt/jsonfuncs.c
meson test -C build --suite setup --suite regress    # Fail 1: sqljson, the 6 new "-- error" cases accepted
git checkout HEAD -- src/backend/utils/adt/jsonfuncs.c
meson test -C build --suite setup --suite regress    # Ok 4, Fail 0, 239 subtests
```

`git diff --check HEAD~1`: clean. pgindent with the tree's pg_bsd_indent: no diff.

## Variant matrix (sql/variants.sql, result in sql/variants-table.txt)

The patch only changes rows 14, 16 and 17 (nested json_array of float8[], a generated column over float8[], a partition key over float8[]), from accepted to rejected. 18.6 rejects all three. No case that 18.6 accepts is rejected by the patch.

## Earlier full matrix on the v5 series

Before the patch, we ran a wider matrix on REL_19_STABLE 0e58f6d737515f6d7f5c910472ffe28dc6fa9f7b with and without v5 and on 18.3: composites (ADD, RENAME, DROP ATTRIBUTE), user ranges with a new cast to json, multiranges, arrays and domains of them, enums, records, generated columns. v5 fixes every composite and user-defined case that went stale. v5 still accepts built-in int4range, int4multirange and int[], as designed. Two cases stay open on all versions: a scalar user-defined base type after CREATE CAST to json (18 has the same behavior), and scalar floats.

## Duplicate check (2026-11-04 03:28 to 03:35 UTC)

- Flat thread: only Manu's message.
- Archive searches "json_array immutable array", "to_json_is_immutable", "float8out STABLE", "float8[] json_array stale": nothing newer than Manu's message reports the array gap.
- `git log` on master and REL_19_STABLE since 2026-11-01 for json.c, jsonfuncs.c, clauses.c: no commits.
- Nik's mailbox: no earlier reply or draft.

## Not run

Isolation, TAP and check-world suites. The master regress suite with v5.
