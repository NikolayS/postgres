# Evidence: CF 7400 follow-up series (v4 state)

macOS arm64, Apple clang 17.0.0, meson debug builds with assertions (-Dcassert=true -Ddebug=true -Dicu=enabled). Own clusters. 18.6 is the Homebrew build.

## Inputs (SHA-256)

| File | SHA-256 |
|---|---|
| v4-0001-Preserve-typmod-when-reducing-CASE-COALESCE-and-N.patch | db2de42776705e633e6e27d0858791f729bf534e1c5fd2b88bc91431fe95eb7f |
| v4-0002-Look-through-RelabelType-when-matching-a-FULL-JOI.patch | ddbbfb460eb4d91e7bd51387c349bfae3b79a9a0803e838aec867591eeb3b32b |
| v4-0003-Simplify-index-expressions-once-in-ON-CONFLICT-in.patch | 20aacd3a52eb5238b4c30d94223b29e6a1675da4732a646bc458bb79cfbb0e3a |
| v4-0004-Look-through-typmod-only-RelabelType-on-partition.patch | 599466a8b303c5831bb44ed743925fbf4518117d44dcad50889c45c27bb4e400 |
| Richard v2-0001 (archive attachment 206459) | 4f3093136463b00d5e639ec0797c2b50b20cde706075a74b6e8f6bf51c8059c6 |
| Richard v2-0002 (archive attachment 206460) | f757884a923bf68e8813b0e1b44a9121cd1e1c7400624e5abe2244eb48d0ab84 |
| shihao nocfbot-0001 | 2370d7a30de4963add081ca8daabb47259621526f3a76f96651b12ef8520790d |

git patch-id --stable: v2-0001 equals v4-0001 (40cdbed39c2c...), v2-0002 equals v4-0002 (9b595ed7df89...).

## Trees

```
base = REL_19_STABLE 4b1abd678223ab22e1fe245547bf5b4a91db56ee
v2   = base + 0001 + 0002     -> f1e8c9e35632
full = base + 0001..0004      -> fdab999c29bc (also c19afe491e5b88d4d16108412e8f267ed6f9131d, same tree)
master b6178c942ea7a85f72beb6a775d2793062a7ff8e: git apply --check of all four in sequence OK
```

## Reproductions

| Case | 18.6 | REL_19 + v2 | REL_19 + v4 |
|---|---|---|---|
| Manu ON CONFLICT | INSERT 0 1 | ERROR no unique or exclusion constraint | INSERT 0 1 |
| shihao pruning | pc1 only | pc1 + pc2 | pc1 only |
| partitionwise aggregate, coalesce(pf(a), b) | Append -> HashAggregate per partition | Finalize HashAggregate -> Append -> Partial HashAggregate | Append -> HashAggregate per partition |
| partitionwise join, varchar(3), COALESCE key | Append -> Merge Join per partition | single Merge Join over Appends | Append -> Merge Join per partition |
| same with CASE key | per partition | single | per partition |
| run-time pruning, generic plan | Subplans Removed | none | removed |
| InitPlan pruning | never executed | executed | never executed |

## Red/green per site

Revert one file's hunk, rebuild, `meson test -C build --suite setup --suite regress`:

- plancat.c (0003): only insert_conflict fails (both new arbiter tests error).
- partprune.c: only partition_prune fails (=, IN, IS NULL, Subplans Removed).
- planner.c: only partition_aggregate fails.
- relnode.c: only partition_join fails.
- relnode.c nullable_partexprs hunk alone: no test fails; a FULL JOIN then JOIN probe loses partitionwise join without it.

Restored: `meson test -C build --suite setup --suite regress --suite isolation`: Ok 5, Fail 0 (regress 239, isolation 134). git diff --check clean. pgindent on all touched C and H files: no change. No new warnings.

## ON CONFLICT variants (sql/oc.sql)

20 variants: Manu's case, constant plus plain column, numeric, two partial indexes, COLLATE, opclass, partitioned table, DO UPDATE WHERE with RETURNING, Fujii's COALESCE NULL and NULLIF cases, shihao's coalesce(b, ''), OpExpr, ScalarArrayOpExpr, DISTINCT and NULLIF index expressions, ICU nondeterministic collation, domain, an expected mismatch that must fail, ON CONSTRAINT, (a, a+0), target alias, updatable view. v4 output is byte-identical to 18.6. v2 fails 13.

## Blocking case (sql/pred.sql)

```
create function f(varchar) returns varchar language sql immutable as 'select $1';
create function g(varchar, varchar) returns bool language plpgsql immutable as 'begin return $1 <> $2; end';
create table t (a varchar(20) not null, b varchar(20));
create unique index on t (b) where g(b, f((case when a is null then b else 'abcdef' end)::varchar(3)));
insert into t values ('x','y') on conflict (b) where g(b, f((case when a is null then b else 'abcdef' end)::varchar(3))) do nothing;
```

18.6: INSERT 0 1. v2 and v4: ERROR: there is no unique or exclusion constraint matching the ON CONFLICT specification. With the experimental predicate change (read indpred from pg_index, simplify once with root): INSERT 0 1 for both pred.sql cases, oc.sql still equals 18.6, regress passes.

## 0004 probes (sql/p4.sql)

Hash key (pruning and aggregate), two-column range key (=, <, aggregate), exec-time pruning through a nested-loop parameter, COLLATE "C" key, domain over varchar(3), CASE key, NULLIF key, FULL JOIN then JOIN. All plan shapes equal 18.6 apart from the relabel shown in EXPLAIN.

strip_typmod_relabel() removes a RelabelType only while resulttype and resultcollid equal the argument's. A relabel that changes type or collation stops it; CoerceToDomain is never stripped. So matches are never wider than on 18.6.

## Earlier v3 state

The earlier v3 files fixed Manu's case and shihao's pruning, but a review found that partitionwise aggregate still regressed (group_by_has_partkey()). v4 fixed that in all three places.

## Not run

check-world, TAP suites, a master build. The planning cost of 0003 was not measured.
