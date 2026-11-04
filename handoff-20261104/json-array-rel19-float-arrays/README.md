# JSON_ARRAY() on REL_19_STABLE: arrays of float4, float8, bytea and geometric types

Status: READY to send. A saved Gmail draft dated 2026-11-04 exists in Nik's mailbox. Nik presses Send.

- Thread: https://www.postgresql.org/message-id/flat/179372513496.2500379.6217138376932454060@gmail.com
  (subject "PG19 regression in ecd9288624a: JSON_ARRAY() indexes that go stale"; one message so far, Manu, 2026-11-03 16:58:54 UTC, with v5).
- PG19 Open Items entry: "JSON_ARRAY()/JSON_OBJECT() expression indexes accepted since ecd9288624a can go stale", owner Andrew Dunstan.
- Reply target: Manu's message, Message-ID 179372513496.2500379.6217138376932454060@gmail.com.

## What we found

Manu's v5 makes floats follow float4out/float8out volatility. On master, e75fcc9867fdfe295957ad5c9a98cbe2e1b4c5c3 (Fujii Masao, 2026-10-20, "Do not backpatch") made float4out, float8out, byteaout and the geometric output functions STABLE. On REL_19_STABLE they are still IMMUTABLE. 18 rejects any array in these constructors. 19 recurses into the element type. So on REL_19_STABLE with v5, indexes over float4[], float8[], bytea[], point[] and similar arrays are accepted and go stale when extra_float_digits or bytea_output changes (index scan 0 rows, seq scan 1 row). Scalars were already accepted on 18 and keep that behavior.

## The patch

`nocfbot-v5-REL_19-float-json-immutability.patch` is for REL_19_STABLE only, on top of Manu's v5-0001 and v5-0002. It adds a static helper in jsonfuncs.c: when an array's element base type is one of the types that e75fcc9867fd made STABLE on master, the array is mutable. Scalars are not changed, so 18 schemas still restore. The `nocfbot` prefix keeps cfbot testing Manu's v5. Master does not need it.

Reference copies of Manu's v5 (unchanged) are in `reference/`:

- https://www.postgresql.org/message-id/attachment/208127/v5-0001-Fix-immutability-check-of-SQL-JSON-constructors-f.patch
- https://www.postgresql.org/message-id/attachment/208128/v5-0002-Treat-arrays-of-user-defined-base-types-as-mutabl.patch

## Upstream commits tested

- REL_19_STABLE 4b1abd678223ab22e1fe245547bf5b4a91db56ee
- master 52b41da0be54f5df6708f95dc8bda73b8ae7c563 (statements only, not the suite)
- e75fcc9867fdfe295957ad5c9a98cbe2e1b4c5c3 is on master only.
- ecd9288624a1582a732cf86ac5a01475a1ce7815 is on both branches.
- git am of v5-0001, v5-0002 and the patch on 4b1abd678223 gives tree 90d4a7d6566def35b6c74c87b8e0d3406a5783cd, which equals the tested tree.

## Suites and results

| Tree | Command | Result |
|---|---|---|
| REL_19 4b1abd678223 + v5 + patch, assertions on | meson test --suite setup --suite regress | OK, 239 subtests |
| same, jsonfuncs.c hunk reverted | same | FAIL, only sqljson: the 6 new error cases are accepted |
| REL_19 + v5 | sql/repro.sql | CREATE INDEX accepted; index scan 0, seq scan 1 |
| REL_19 + v5 + patch | sql/repro.sql | CREATE INDEX rejected |
| master 52b41da0be54 + v5 | sql/repro.sql | CREATE INDEX rejected |
| 18.6 | sql/repro.sql | CREATE INDEX rejected |
| all four | sql/variants.sql (17 cases) | sql/variants-table.txt: the patch rejects nothing that 18.6 accepts |

Not run: isolation, TAP, check-world, the master regress suite.

## What remains

1. Nik reviews the Gmail draft dated 2026-11-04 and presses Send. Optionally add Andrew Dunstan to Cc.
2. Optional before send: quote Manu's previous line too, so "stale / stale / stale" has its column labels; indent the SQL.
3. After send: watch for Andrew's view on folding this into v5-0001 for the 19 branch.

## Open questions

- The file name says "float", but the patch also covers bytea and the geometric types. Rename before sending if wanted.
- Scalar float, bytea and point indexes stay stale on 19, as on 18. Out of scope, as Manu says.

`draft.txt` is the exact email. `EVIDENCE.md` has the commands and outputs.

## SHA-256 of the files in this directory (except this README)

```
065e5ea8b62f4e1c443a9549b81c615a2a5b4dc83e1042c552f3d30dfa89c518  draft.txt
a38d8a5151f77682e2cb830550854115ac5a5181b4ef68a7075c19d4f5ad46bb  EVIDENCE.md
f67dfa8e989f01c7ccb9a10def4d235ceeefc7836a5b63b7ab8460d999e878fd  nocfbot-v5-REL_19-float-json-immutability.patch
4899241f4cbe160ca182d263a839b768848d226bb40b067dbc841d0e2fbb9387  reference/v5-0001-Fix-immutability-check-of-SQL-JSON-constructors-f.patch
04c9c847a352bae471dc3bef4d5d82fa092054216058901d1a87347c8954dc7d  reference/v5-0002-Treat-arrays-of-user-defined-base-types-as-mutabl.patch
3286de0f1138e992a2452d2b592545cf400e02cef9d5051e7629fc22d31d1036  sql/repro.sql
ec7145c6bc42cef8a71eeae166a1bded23dcb0691be74a15d52aa434a0ed59e3  sql/variants-table.txt
3596e2c01efee37a878b9ce8049732f37af8553c6616c92908ea25a023cf946a  sql/variants.sql
```
