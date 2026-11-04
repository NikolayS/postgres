# Evidence: NOT ENFORCED inherited CHECK, v3

macOS arm64, Apple clang 17.0.0, meson debug builds with assertions (-Dcassert=true -Ddebug=true). Own clusters and ports.

## Inputs

| File | SHA-256 |
|---|---|
| v3-0001-Validate-inherited-CHECK-constraints-when-enablin.patch (--base=b6178c942ea7) | bbbf09dec5c4f7eec533bb8babca06ed339111b98abdb427c374f1e34ba4a56c |
| v3-0001-Validate-inherited-CHECK-constraints-when-enablin-REL_18.patch.txt (--base=d6694976c88c) | 463443a42a9e91acfb9f30fa388f34a59f23285f859bec46dfb861c062d98bec |
| v1 0001-validate-inherited-check-promotion.patch (archive attachment 203684) | 084af7b317a0693c6dac6888b6e0ef2e85b3d39d71f4d49279d4c9ed77d52d78 |

## Bases (fetched 2026-11-04 03:32 UTC and again about 03:45 UTC)

| Branch | Head | Patched HEAD after git am |
|---|---|---|
| master | b6178c942ea7a85f72beb6a775d2793062a7ff8e | e59bad6f6b2f28e4b5a5809480c4933b20375d1e |
| REL_19_STABLE | 4b1abd678223ab22e1fe245547bf5b4a91db56ee | 52629218f104f01e7b30c3bd62d07b77d83a3739 |
| REL_18_STABLE | d6694976c88c038039c2b74d0aa4eaa4e083519c | 5e84ea816b08158328b43210175e4d68e355e216 |

0b12a5a7435a is an ancestor of master; 8356d8e4dba6 of REL_19_STABLE. git am is clean on all three. The test hunks of both files are byte-identical.

## Defect and fix (sql/repro.sql)

```
create table p (a int, constraint cc check (a > 0) not enforced);
create table c () inherits (p);
insert into c values (-1);
alter table c add constraint cc check (a > 0);
```

- Unpatched (all three): ALTER TABLE succeeds; c has conenforced t, convalidated t, and one violating row. With NOT VALID, convalidated is also t and VALIDATE CONSTRAINT passes over the bad row.
- Patched (all three): `ERROR: check constraint "cc" of relation "c" is violated by some row`; catalog unchanged. NOT VALID add gives t/f and VALIDATE then fails on the row.

Chao's tree (sql/chao-tree.sql) on all three patched trees:

```
alter table c1 add constraint cc check (a > 0);
ERROR:  constraint "cc" conflicts with NOT VALID constraint on child table "c2"
HINT:  You may need to use ALTER TABLE ... VALIDATE CONSTRAINT on table "c2" first.
alter table c2 validate constraint cc;           -- ok
alter table c1 add constraint cc check (a > 0);  -- ok; c1 t/t, c2 t/t
```

## Suites

`meson test -C build --suite setup --suite regress --suite isolation`

| Tree | regress | isolation |
|---|---|---|
| master + v3 | 239 passed | 134 passed |
| REL_19 + v3 | 239 passed | 134 passed |
| REL_18 + v3-REL_18 | 231 passed | 125 passed |

## Red/green

On each patched tree: `git checkout HEAD~1 -- src/backend/catalog/heap.c src/backend/commands/tablecmds.c`, rebuild, run regress. All three fail only in inherit.out, with identical diffs: convalidated t instead of f after the merge, missing "violated by some row" errors, missing ONLY error, missing "must be owner of table" error, a descendant left NOT ENFORCED under an enforced parent, missing ENFORCED NOT VALID error. Restored afterwards.

For the v3-only change (NOT VALID add over an ENFORCED NOT VALID descendant), reverting only that hunk fails on all three branches with the conflict error and p1_c1 1|f|f|f.

## Style

git diff --check clean on all three. pgindent with each branch's pg_bsd_indent on heap.c and tablecmds.c: no changes. No new warnings in touched files.

## Adversarial cases (master; 18 identical except where noted)

| Case | Patched result |
|---|---|
| NOT VALID add on child, bad row | c t/f; VALIDATE fails on row |
| p, c1, c2 all NOT ENFORCED, bad row in c2, add on c1 | error on c2; after delete: c1 t/t, c2 t/t |
| Chao: c2 ENFORCED NOT VALID, validating add on c1 | conflict error and hint, catalog unchanged |
| same, NOT VALID add on c1 | succeeds; c1 t/f; c2 unchanged t/f |
| multiple inheritance, coninhcount 2 | bad row errors; then c t/t, conislocal t, coninhcount stays 2 |
| diamond inheritance | d scanned, enforced once, coninhcount 2 kept |
| partitions | "already exists" (merge never allowed at partitions) |
| ALTER INHERIT and ATTACH PARTITION with ENFORCED NOT VALID child | state kept |
| savepoint rollback of success and of failure | catalog restored |
| ONLY c1 with children | "constraint must be added to child tables too" |
| owner of c1 is not owner of c2 | "must be owner of table c2" |
| locks during add on c1 | AccessExclusiveLock on c1 and c2, same as an ordinary ADD CHECK |
| stored generated column in the CHECK | row rejected |
| foreign table grandchild | patched marks it t/t; unpatched left it NOT ENFORCED under an ENFORCED parent |
| pg_dump and restore of a merged NOT VALID child (master and 18) | round-trips t/f, t/t, conislocal and coninhcount |
| local NOT ENFORCED constraint, then enforced add | "already exists" |

No remaining path to convalidated = true without a scan was found for heap relations.

## Duplicate check (2026-11-04 04:02 to 04:20 UTC)

- Flat thread: Nik and Chao Li only.
- CF 7426 thread: latest Andrew Dunstan 2026-11-01 ("Done", v5-0001 committed). Its open 0002 and 0003 do not cover the ADD CONSTRAINT merge.
- Archive searches "NOT ENFORCED inherited check validate", "MergeWithExistingConstraint convalidated", "check constraint merge not enforced": no fix of this bug.
- git log since 2026-10-25 on heap.c and tablecmds.c (master, 19, 18): only 0b12a5a7435/8356d8e4dba and unrelated NOT NULL commits.
- Nik's mailbox: no later reply or draft.

## Not run

TAP suites, check-world.
