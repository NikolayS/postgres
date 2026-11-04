# NOT ENFORCED inherited CHECK: ADD CONSTRAINT merge skips validation (v3)

Status: READY to send. A saved Gmail draft dated 2026-11-04 exists in Nik's mailbox. Nik presses Send.

- Thread (Nik's own): https://www.postgresql.org/message-id/flat/CAM527d8qCH4q1xV-TftDmm3eBcBie9AxfdTtThPUoGWnYT08gw@mail.gmail.com
- Reply target: Chao Li, 2026-09-14 06:24:51 UTC, Message-ID 3CDC7AF1-CEDC-4FC1-AA2F-053BF59D00E6@gmail.com. No reply from Nik yet.
- v1 (2026-09-13): https://www.postgresql.org/message-id/attachment/203684/0001-validate-inherited-check-promotion.patch
- Related, not overlapping: CF 7426 https://commitfest.postgresql.org/patch/7426/ (its v5-0001 was committed as 0b12a5a7435a on master and 8356d8e4dba6 on REL_19_STABLE).
- No CommitFest entry for this thread.

## What was found (the bug)

A child that inherits a NOT ENFORCED CHECK constraint can run `alter table c add constraint cc check (...)`. The merge in MergeWithExistingConstraint() sets convalidated = true without scanning the child, so a violating row stays under an enforced, valid constraint. With NOT VALID the merge also sets convalidated = true. Confirmed on master, REL_19_STABLE and REL_18_STABLE (sql/repro.sql).

## v3 changes vs v1

- Rebased on 0b12a5a7435a. Enforcing a parent over an ENFORCED NOT VALID descendant now raises that commit's error, so Chao's tree errors until c2 is validated.
- force_validation removed (dead after the rebase).
- A NOT VALID add over an ENFORCED NOT VALID descendant succeeds and leaves the descendant unchanged (new test).
- Commit message with Backpatch-through: 18, Author, Reviewed-by: Chao Li.
- Separate REL_18_STABLE version: REL_18 has no ALTER CONSTRAINT [NOT] ENFORCED for CHECK, so the descendant handling is inline in ATAddCheckNNConstraint(). Same tests and expected output as master.

## Files

- `v3-0001-Validate-inherited-CHECK-constraints-when-enablin.patch`: master and REL_19_STABLE as-is.
- `v3-0001-Validate-inherited-CHECK-constraints-when-enablin-REL_18.patch.txt`: REL_18_STABLE.
- `sql/repro.sql`: the original reproducer. `sql/chao-tree.sql`: Chao's tree.

## Upstream commits tested

- master b6178c942ea7a85f72beb6a775d2793062a7ff8e
- REL_19_STABLE 4b1abd678223ab22e1fe245547bf5b4a91db56ee
- REL_18_STABLE d6694976c88c038039c2b74d0aa4eaa4e083519c

## Suites and results

| Tree | Command | Result |
|---|---|---|
| master + v3 | meson test --suite setup --suite regress --suite isolation | OK: regress 239, isolation 134 |
| REL_19 + v3 | same | OK: regress 239, isolation 134 |
| REL_18 + v3-REL_18 | same | OK: regress 231, isolation 125 |
| each, heap.c and tablecmds.c reverted | regress | FAIL, only inherit, the intended cases |
| each patched tree | sql/repro.sql | "violated by some row"; NOT VALID add leaves convalidated f |
| each patched tree | 19 adversarial cases plus pg_dump round trip | see EVIDENCE.md |

Not run: TAP suites, check-world.

## What remains

1. Nik reviews the Gmail draft dated 2026-11-04 and presses Send.
2. Optional before send: the draft says red/green was shown on master and REL_18_STABLE. It also holds on REL_19_STABLE.
3. After send: consider a CommitFest entry (none exists) for cfbot coverage.

## Open questions

- REL_18 adds a new translatable error string to a back branch (same text as master and 19). Committer's call.
- The REL_18 version is new AI-written code, not manually reviewed yet. The draft says so.

`draft.txt` is the exact email. `EVIDENCE.md` has the commands and outputs.

## SHA-256 of the files in this directory (except this README)

```
50933279e5bc21fc63f4ab562d74266e6acd2f64600fef19e082d15707f8ae8b  draft.txt
e20911cbceca7a882c1fa2a643a7e1d7d7145a009c947972f68949a7c5d3dc6f  EVIDENCE.md
1aae9fa4e0a37cdd0f155bd1a8d65632923b9a806d6cb2e99befaecb6bb261c0  sql/chao-tree.sql
91b0317503176bea4f1f47f6945ac6316b8dd32c0026baa46481e3de7305c0ed  sql/repro.sql
463443a42a9e91acfb9f30fa388f34a59f23285f859bec46dfb861c062d98bec  v3-0001-Validate-inherited-CHECK-constraints-when-enablin-REL_18.patch.txt
bbbf09dec5c4f7eec533bb8babca06ed339111b98abdb427c374f1e34ba4a56c  v3-0001-Validate-inherited-CHECK-constraints-when-enablin.patch
```
