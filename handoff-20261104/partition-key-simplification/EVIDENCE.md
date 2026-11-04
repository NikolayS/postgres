# Evidence: partition key and constraint const-simplification

macOS arm64, Apple clang 17.0.0, meson debug builds with assertions (-Dcassert=true -Ddebug=true -Dicu=enabled). Own clusters and ports. 18.3 and 18.6 are Homebrew builds.

## Inputs

- v1-0001-Fix-const-simplification-of-partition-keys-and-co.patch: fc9687abf5a5cbcf5235aacc455033f69804f89b9a60861ecd9bbcbb6173c9df, base-commit 4b1abd678223ab22e1fe245547bf5b4a91db56ee. Subject 58 characters. Trailers: Discussion, Backpatch-through: 19.
- Robert's attachments: finding6.sql 8ff7e8b5be9674d61e39525d5a00b0650918868fbc21013d8b1a6594defc18ef, finding8.sql b38dd81a9db14cd7c14213e32875f2fd4c76f4021164ba4c922507818f8512ad.

## Root cause (source at 4b1abd678223)

- Quals: eval_const_expressions(root, ...) reduces a NullTest on a NOT NULL Var and drops COALESCE arguments after a non-nullable one.
- Partition key: RelationBuildPartitionKey() (partcache.c) simplifies without root. set_baserel_partition_key_exprs() (plancat.c) only renumbers varnos.
- match_clause_to_partition_key() (partprune.c) then compares `a` with `COALESCE(a, b)`: no match. have_partkey_equi_join() uses the same rel->partexprs.
- set_baserel_partition_constraint() uses expression_planner() with no root.
- The same pattern was already fixed for constraints/statistics (317c117d6d2) and index expressions (c925ad30b04).

## Minimal reproducer (sql/repro.sql)

```
create table pt (a int not null, b int) partition by list (coalesce(a, b));
create table pt1 partition of pt for values in (1);
create table pt2 partition of pt for values in (2);
explain (costs off) select * from pt where coalesce(a, b) = 1;
```

| Build | Plan |
|---|---|
| 18.3 and 18.6 | Seq Scan on pt1, Filter: (COALESCE(a, b) = 1) |
| REL_19 4b1abd678223 | Append over pt1 and pt2, Filter: (a = 1) |
| REL_19 + v1, master + v1 | Seq Scan on pt1, Filter: (a = 1) |

Robert's files: finding6 scans p1 only on 18 and patched, p1 and p2 on unpatched 19. finding8 gives One-Time Filter: false on 18 and patched; unpatched 19 scans p1_1 and p1_def.

## Bisect (sql/bisect.sql)

| Commit | COALESCE key | CASE key |
|---|---|---|
| 904f6a593a06 (parent of e2debb64380) | prunes | prunes |
| e2debb64380 | prunes | lost |
| b947dd5c75b1 (parent of 10c4fe074a9) | prunes | lost |
| 10c4fe074a9 | lost | lost |

## Red/green and suites

```
meson test -C build --suite setup --suite regress --suite isolation
```

- REL_19 + v1: 5/5 OK, regress 239, isolation 134.
- master + v1 (52b41da0be54 and b6178c942ea7): same.
- Tests only, plancat.c unchanged: partition_prune fails with 4 hunks (COALESCE plan-time, run-time Subplans Removed, CASE, constraint One-Time Filter).
- Only the key line removed: COALESCE, run-time and CASE blocks fail. Only the constraint hunk reverted: only the One-Time Filter block fails.
- git diff --check clean; pgindent: no diff; warning set unchanged.
- A clean git am of the file on both bases applies without fuzz. C and test hunks are identical on both branches.

## Adversarial variants (sql/v01 to v12)

Rows are identical on 18.6, unpatched 19, patched 19 and patched master in all 12. Covered: partitionwise join with both sides NOT NULL and one side nullable; left and full joins; partitionwise aggregate; varchar keys with RelabelType; text-cast keys; a generic plan followed by ALTER ... DROP NOT NULL (plan invalidated, both rows returned); NOT NULL NOT VALID with an existing null (not used for reduction); multi-level partitions with a child-only NOT NULL; outer join with the partitioned table on the nullable side; UPDATE with row movement and DELETE; parameterized join.

## Code review notes

- ChangeVarNodes runs before eval_const_expressions in both functions. Partition keys and constraints contain no PlaceHolderVars, SubLinks or Params.
- NOT NULL information for partitions is collected in expand_single_inheritance_child() before build_simple_rel(), so root has it.
- RelationGetPartitionQual() returns a copy, so in-place ChangeVarNodes is safe.
- Cost: one extra eval_const_expressions per expression key per partitioned rel. The constraint is still simplified once.

## Duplicate check (2026-11-04 03:46 to 03:55 UTC)

- Flat thread: only the commit mail and Robert's message.
- Archive searches "set_baserel_partition_key_exprs", "partition pruning NOT NULL 19", "partition key eval_const_expressions": no overlap.
- git log since 2026-10-01 on plancat.c and partitioning/: no commit touches either function.
- CF 7400's partition patch is a different mechanism (RelabelType). No CF entry linked to Robert's message.
- Nik's mailbox: no earlier reply or draft.

## Not run

check-world, TAP suites, a partitionwise-join regression test.
