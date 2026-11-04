# PG19: partition key and partition constraint not simplified with NOT NULL knowledge

Status: READY to send. A saved Gmail draft dated 2026-11-04 exists in Nik's mailbox. Nik presses Send.

- Thread: https://www.postgresql.org/message-id/flat/CA+TgmoZy22d8Mz3z_Sjj+cb6tJQyfe=fJT-XkWmFX2eGD067iw@mail.gmail.com
  (Robert Haas, 2026-10-06 15:53 UTC, reply to the commit mail for e2debb64380; no replies so far).
- No CommitFest entry. Not on the PG19 Open Items page.

## What we found

Since e2debb64380ebcf0979708a0fa88d9c8d924005b ("Reduce Var IS [NOT] NULL quals during constant folding") and 10c4fe074a92eccf9fa6f7a39fe4d3f97b9b87e2 ("Simplify COALESCE expressions using non-nullable arguments"), quals are simplified with NOT NULL knowledge, but the partition key and the partition constraint are not. So `coalesce(a, b) = 1` becomes `a = 1` and no longer matches the key `coalesce(a, b)` when `a` is NOT NULL. Plan-time pruning, run-time pruning and partitionwise join are lost. Constraint exclusion on the partition constraint is lost too (Robert's finding8.sql). Results are correct; only plans regress. 18 is not affected.

Bisect: CASE WHEN a IS NULL THEN b ELSE a END breaks at e2debb64380 (parent 904f6a593a06 prunes). COALESCE breaks at 10c4fe074a9 (parent b947dd5c75b1 prunes).

## The patch

`v1-0001-Fix-const-simplification-of-partition-keys-and-co.patch` (same file for REL_19_STABLE and master). In plancat.c, set_baserel_partition_key_exprs() runs each expression key through eval_const_expressions() with root after ChangeVarNodes(), like c925ad30b047ec1388247539e86729d584c34b8d does for index expressions. set_baserel_partition_constraint() fixes varnos first and then simplifies once with root instead of expression_planner(). New tests in partition_prune.sql. Backpatch-through: 19.

## Upstream commits tested

- REL_19_STABLE 4b1abd678223ab22e1fe245547bf5b4a91db56ee
- master 52b41da0be54f5df6708f95dc8bda73b8ae7c563 and b6178c942ea7a85f72beb6a775d2793062a7ff8e
- Bisect points 904f6a593a06649f77597ab9a72ef97c21e39a93, e2debb64380ebcf0979708a0fa88d9c8d924005b, 10c4fe074a92eccf9fa6f7a39fe4d3f97b9b87e2 and its parent.

## Suites and results

| Tree | Command | Result |
|---|---|---|
| REL_19 + v1 | meson test --suite setup --suite regress --suite isolation | OK: regress 239, isolation 134 |
| master 52b41da0be54 + v1, and b6178c942ea7 + v1 | same | OK: regress 239, isolation 134 |
| REL_19 + v1 tests only | --suite setup --suite regress | FAIL, only partition_prune, 4 hunks |
| plancat.c key line only removed | regress | FAIL for the COALESCE, run-time and CASE blocks |
| constraint hunk only reverted | regress | FAIL only for the One-Time Filter block |
| 18.6, REL_19, REL_19 + v1, master + v1 | sql/repro.sql, finding6.sql, finding8.sql | 18 and patched prune; unpatched 19 scans all partitions |
| same four | sql/v01 to v12 | same rows everywhere; plans restored |

Not run: check-world, TAP suites.

## What remains

1. Nik reviews the Gmail draft dated 2026-11-04 and presses Send. Optionally add Richard Guo to Cc.
2. Fix before send: the draft says "18.3 scans only pt1"; the final check ran 18.6. Change to "18" or "18.6".
3. Optional: update "master 52b41da0be54" to b6178c942ea7 (also tested), and add one line that other root-less eval_const_expressions() callers were not audited (Robert's second paragraph).
4. Optional: register a CommitFest entry for cfbot coverage.

## Open questions

- With the patch, `where a = 1` also prunes on a `coalesce(a, b)` key when `a` is NOT NULL. 18 does not prune that. It is correct; mention it in the commit message?
- The email says partitionwise join comes back, but the patch has no regression test for it. Add a small case (sql/v01_pwj_both_notnull.sql)?
- Relation to CF 7400: independent fixes; see ../cf7400-notnull-simplification/README.md.

`draft.txt` is the exact email. `EVIDENCE.md` has the commands and outputs.

## SHA-256 of the files in this directory (except this README)

```
8e1cdbefa1ca05cb1dcbc1bbc9ebdcf95914e9bb1a71c919e0ce675e5682f9cd  draft.txt
5aad873343c6f97414660c7285837aa14aafd67e12fdff1524805458f3e7edbd  EVIDENCE.md
51ac96ca40227bf2d78a98aafbda4751fc153f5772209ee5eca52fa63a497434  sql/bisect.sql
99f3c0083417cde2805eb76d0770d9e2aa374f58909dba10ecc1a635a0d50eac  sql/repro.sql
d71ebbf1e0c91195dd48a469a186681c3b336e97e94cf1d47bbbf5d2672f64f7  sql/v01_pwj_both_notnull.sql
1bf72a9232e1951c0a1e52b60f70b4ce8ced687d3c64c0521b449b1f5df7359a  sql/v02_pwj_one_nullable.sql
74334d2e0468e5884b1ed2cf04d504d707b71d8e4a852103f07da3175e491ac4  sql/v03_pwj_left_full.sql
9ff58b401a349d3e295d19413621147daadf3c2132f4ca0eb05c6c215d3edc79  sql/v04_pwagg.sql
25cf8f60a23ffb218ff3b6246a7feb7fcdf5f65315e7acac581b434dbce707a6  sql/v05_varchar_key.sql
d3ffb1a8bd8cbd3c2372e5fc47ed18db23722d5b01fe5020d0647cdeb10945a6  sql/v06_relabel_text_key.sql
f8f510dbd3ff147a509cc1d5b9af392577cf6fd2ac639768f1cea551c1492567  sql/v07_generic_drop_notnull.sql
786a13a0c06295b34efef448607b0073011869ca192e9c3e40bdcf8c31bd8494  sql/v08_notnull_not_valid.sql
d8f86e367c7a1626ca3bf641ad8279215010bbccf5bcb3d1286b28ec0e5634ff  sql/v09_multilevel_child_notnull.sql
51e2c9ab0f9124b4db75d7785d2d851469bde1291fe9a2563f27f69baff5b3fb  sql/v10_outer_join_nullable_side.sql
ef9b922a8edcf1f8bfa9878c0bc13e09ba024914635001dd8b8205584504a3e9  sql/v11_dml_update_delete.sql
a15773078231d63c05862f46a4146558a2b98de2fd8c533fc3d5c5518c0e106a  sql/v12_runtime_param_join.sql
fc9687abf5a5cbcf5235aacc455033f69804f89b9a60861ecd9bbcbb6173c9df  v1-0001-Fix-const-simplification-of-partition-keys-and-co.patch
```
