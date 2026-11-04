# CF 7400: [PG19] Wrong results from NOT NULL-based expression simplification

Status: IN PROGRESS. Not ready to send. No Gmail draft. The v4 files here are the latest tested state; a review found one blocking case (partial-index predicate). A v5 (to be posted to the list as "v3") is being prepared.

- Thread: https://www.postgresql.org/message-id/flat/CAGRkXqR7VXacmRP41UBaM5u4aseeCH5ECVmQgn_YS=L7=xdhTw@mail.gmail.com (shihao zhong, 2026-10-06; 14 messages, newest shihao 2026-10-17 04:13 UTC).
- CommitFest: https://commitfest.postgresql.org/patch/7400/
- On the list: Richard Guo's v2 (0001 typmod for CASE/COALESCE/NULLIF, 0002 FULL JOIN RelabelType), and shihao's nocfbot partprune.c patch.
- Manu's ON CONFLICT report: https://www.postgresql.org/message-id/179220962657.1343374.11137544623255312817@gmail.com
- Reply target: shihao's message CAGRkXqSQT4CMmOUXDYBoxyMXdU6DqXMQqb-LPyrPTx-kDtJeYQ@mail.gmail.com.

## What was found

1. Manu's case: `insert ... on conflict (expr)` fails with "no unique or exclusion constraint matching" on REL_19 and with v2, while 18 accepts it. Cause: index expressions are simplified twice (relcache without root, then with root), the arbiter expressions once with root. The Var IS [NOT] NULL fold from e2debb64380 needs root, so the two forms differ (a cast typmod stays in one).
2. With v2-0001, a partition key such as `coalesce(pf(a), b)` on numeric(10) becomes a typmod-only RelabelType. partprune.c, group_by_has_partkey() and match_expr_to_partition_keys() strip RelabelType from the query side only. So pruning (shihao), partitionwise aggregate and partitionwise join are lost with v2. 18.6 and unpatched 19 keep them.
3. The partition-key NOT NULL issue in Robert's thread (../partition-key-simplification/) is a different bug. Its fix does not help here, and both fixes apply in either order.

## v4 series (files here)

- `v4-0001`, `v4-0002`: Richard's v2, unchanged (same git patch-id).
- `v4-0003`: infer_arbiter_indexes() reads index expressions from pg_index and simplifies them once with root. Exact equal() matching kept.
- `v4-0004`: new strip_typmod_relabel() in nodeFuncs.c, used in partprune.c, planner.c group_by_has_partkey() and relnode.c match_expr_to_partition_keys(). Strips only a RelabelType that keeps type and collation. Tests in partition_prune, partition_aggregate, partition_join.

## Upstream commits tested

- REL_19_STABLE 4b1abd678223ab22e1fe245547bf5b4a91db56ee (base-commit of the files)
- master b6178c942ea7a85f72beb6a775d2793062a7ff8e: git am of all four is clean; not built.
- Comparison: 18.6.

## Results so far

| Tree | Command | Result |
|---|---|---|
| REL_19 + v4 | meson test --suite setup --suite regress --suite isolation | OK: regress 239, isolation 134 |
| v4, one site reverted at a time | regress | each fails only in its own test file (insert_conflict, partition_prune, partition_aggregate, partition_join) |
| v4, relnode.c nullable_partexprs hunk alone reverted | regress | no test fails (missing test) |
| 18.6, REL_19 + v2, REL_19 + v4 | sql/manu.sql, shihao.sql, join.sql, draft.sql | v4 plans match 18.6; only the relabel shows in EXPLAIN |
| same | sql/oc.sql (20 ON CONFLICT variants) | v4 equals 18.6 on all 20; v2 fails 13 |
| same | sql/pred.sql | 18.6 accepts; v2 and v4 reject: BLOCKING |

## Blocking finding (from the v4 review)

0003 leaves the partial-index predicate on the twice-simplified relcache copy, and its comment says predicate_implied_by() tolerates the difference. That is false when the folded constant sits inside a non-constant expression (sql/pred.sql). A tested experimental fix reads indpred from pg_index too and simplifies it once with root. With it both pred.sql cases insert, all 20 ON CONFLICT variants still equal 18.6, and regress passes.

## Next steps

1. Implement the predicate fix in 0003, mirroring RelationGetIndexPredicate() (canonicalize_qual), add the pred.sql case to insert_conflict.sql, and drop the false comment and commit-message paragraph.
2. Add a FULL JOIN then JOIN test for the nullable_partexprs hunk in relnode.c, so "each fails without its hunk" is true.
3. Name the series v3 on the list (the list has only v1 and v2).
4. 0004 credits: Author: shihao zhong and Author: Nik Samokhvalov, plus Reported-by: shihao zhong.
5. Optional: measure the planning cost of 0003 per INSERT ... ON CONFLICT.
6. Rebuild, red/green per hunk, regress and isolation, fresh review, duplicate check, update draft.txt, save the Gmail draft. Then Nik sends.
7. Suggested order: send the partition-key reply (Robert's thread) first, then this one.

## Separate lead (not for this series)

Partitionwise aggregate with a text list key and `group by t::bpchar` splits groups that are equal under bpchar comparison: 2 groups instead of 1. Same on 18.6 and v4, so it is pre-existing, from the query-side-only strip in group_by_has_partkey(), which has no opfamily check. `sql/bpchar-grouping.sql` is a hand-off copy of the reviewed probe (not run in this exact form). It needs its own report after checking older branches.

`draft.txt` is the current v4 draft (not final). `EVIDENCE.md` has the commands and outputs.

## SHA-256 of the files in this directory (except this README)

```
ab5d83c2eff1eb1e322fdb42576e8aa99922a4143aa138debb7ca99238069998  draft.txt
ef49cd0d7110cc4bb56ec817580a84576e9b4517b0bf440a57812d2d63b43bba  EVIDENCE.md
ba3241f381e5c5f30b10a6a1dec51cbad16e70f88fd7c1a86b63388ae5cdc603  sql/bpchar-grouping.sql
09fe974961a3b3ce459627a3c588f57e4a0df015f91dc149632f34c6831067dd  sql/draft.sql
6ba42b8a860a61712671eb8a77ad8ce1ff5d482eab1d6323c5a3691ba410dc21  sql/join.sql
855247f98934ab1b2e76a2959ce389679853adb701dcbef6d9f852c439a162e6  sql/manu.sql
6dd88e4e62f2c7aecdf34e26543f8fb361e8de063f81ce434064a5f1430924a0  sql/oc.sql
d5f4d96744346df07e7cd38edb8b58ee4c2618fe1247d664e902fac2f74480eb  sql/p4.sql
f2dc731d622133dcfca83673e1051239b86461d22bf6dd0e93a904d719ed0f18  sql/pred.sql
09fe974961a3b3ce459627a3c588f57e4a0df015f91dc149632f34c6831067dd  sql/shihao.sql
db2de42776705e633e6e27d0858791f729bf534e1c5fd2b88bc91431fe95eb7f  v4-0001-Preserve-typmod-when-reducing-CASE-COALESCE-and-N.patch
ddbbfb460eb4d91e7bd51387c349bfae3b79a9a0803e838aec867591eeb3b32b  v4-0002-Look-through-RelabelType-when-matching-a-FULL-JOI.patch
20aacd3a52eb5238b4c30d94223b29e6a1675da4732a646bc458bb79cfbb0e3a  v4-0003-Simplify-index-expressions-once-in-ON-CONFLICT-in.patch
599466a8b303c5831bb44ed743925fbf4518117d44dcad50889c45c27bb4e400  v4-0004-Look-through-typmod-only-RelabelType-on-partition.patch
```
