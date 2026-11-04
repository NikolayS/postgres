# Small items: replies and fixes owed (checked 2026-11-04 01:45 to 01:48 UTC)

Status: open. No drafts, no patches from us yet. Master used for apply checks: 35273454065e6b7f07984e70ac131ce710e6f380. REL_19_STABLE head at the time: 0e58f6d737515f6d7f5c910472ffe28dc6fa9f7b.

## 1. xact_rollback spikes when a logical walsender exits (CF 6992, Nik's patch)

- Thread: https://www.postgresql.org/message-id/flat/CAM527d_EbU5Li4a5FdKQjYsdF-4Lqr_i3jXmZOm7Wbb=Q2KzTw@mail.gmail.com
- CF: https://commitfest.postgresql.org/patch/6992/ (PG20-3, Ready for Committer; reviewers Mircea Cadariu, jihyun bahn).
- Latest: v3, 2026-07-08: https://www.postgresql.org/message-id/attachment/199482/v3-0001-xact_rollback-decoding-fix.patch (SHA-256 1c549761942235e6b4c31e5be80f0ffddce9162b7a88c1b92eef34cc72c91a68) and https://www.postgresql.org/message-id/attachment/199481/v3-0002-count-client-xacts-only.patch (SHA-256 e1d3a583e64e0e3b49b3f649476dacd88e3359b616b3b1c4316dd4bcec20d495).
- Rebase: v3-0001 applies to master. v3-0002 after 0001 does not: one rejected hunk in xact.c AbortTransaction(), context drift only (master has no AtEOXact_LogicalCtl() after AtEOXact_LogicalRepWorkers() there). The one-line change itself is trivial.
- Replies owed by Nik: Mircea (2026-09-08, https://www.postgresql.org/message-id/591163e7-7e74-4c30-beb2-45bddcb9a90e@gmail.com) offered to write the 0002 tests; nobody accepted. jihyun bahn (2026-07-09, https://www.postgresql.org/message-id/178357299471.9403.9243858144101333619.pgcf@coridan.postgresql.org) asked whether to add an apply-commit counter to pg_stat_subscription_stats or point the docs at an alternative; unanswered.
- Single action: post v4 with 0002 rebased and a TAP test for 0002 (autovacuum, walsender and apply worker excluded; client backend counted), or accept Mircea's offer with that exact test scope; answer jihyun's question in the same mail.

## 2. Plan cache not invalidated when a cast changes: reply owed to Haibo Yan

- Thread: https://www.postgresql.org/message-id/flat/CABXr29GKyUD2iy15viRNhAb4j4erg6oQ3xHueQi0qAXtTp9Tfw@mail.gmail.com
- Nik v1 (2026-09-15): https://www.postgresql.org/message-id/attachment/203789/v1-0001-Invalidate-cached-plans-when-casts-change.patch
- Haibo Yan (2026-09-16) confirmed the bug and posted a separate patch for the sibling case (pg_proc candidate-set changes): https://www.postgresql.org/message-id/attachment/203890/v2-0001-Invalidate-cached-plans-when-the-pg_proc-candidate.patch
- Master plancache.c still registers no pg_cast callback, so the bug is live. Commit 6aecabcd5ed (RI checks via SPI when a cast is needed) fixes a sibling in RI only, not this generic plan-cache case. No CF entry for either patch.
- Single action: reply to Haibo (7 weeks without an answer): thanks, the two patches are independent; rebase v1 on master, rerun the reproducer, run Haibo's v2 against its new cases, and create a CF entry.

## 3. pg_upgrade: prevent premature startup of the new cluster (CF 7443): reply owed

- Thread: https://www.postgresql.org/message-id/flat/42D6E812-B4C6-4DA1-8428-D58A21E16B05@yesql.se
- CF: https://commitfest.postgresql.org/patch/7443/ (PG20-3, Needs review, author Shubhra Jain, first patch, no reviewers; cfbot: needs rebase since 2026-10-16).
- Shubhra asked Nik two questions on 2026-10-09 (block single-user mode too? marker file name?): https://www.postgresql.org/message-id/CAOh5eDU-fjignwX2x3qtQ7VSOfHJrf-jwzLSyzVLAXxxjwmLFw@mail.gmail.com . v1 on 2026-10-13 answered them itself (single-user blocked, file pg_upgrade_in_progress): https://www.postgresql.org/message-id/CAOh5eDVOtc4m0v19Rqcog+2gH75LbakScD3PC33aiw+SxppiEA@mail.gmail.com
- v1: https://www.postgresql.org/message-id/attachment/206172/v1-0001-pg_upgrade-Prevent-premature-startup-of-the-new-c.patch (SHA-256 43e52572bc8bb2a92783453b0e84e5ac148f856d4ce7b51bf575e6c3ed410f4d). git apply --check on master fails on one declarations hunk in pg_upgrade.c (context drift only).
- Single action: test v1 on a trivial rebase (suspend during copy, start the target, check it refuses; then --check; then a failed-upgrade case) and reply with a review covering Shubhra's three open points (fsync with --no-sync, the #define location, the rsync/standby case).

## 4. Python/pytest test framework (CF 6045): Nik's follow-ups broke cfbot

- Thread: https://www.postgresql.org/message-id/flat/DKSSP47Y857Z.1FUU91WMDZWPZ@jeltef.nl
- CF: https://commitfest.postgresql.org/patch/6045/ (authors Jacob Champion and Jelte Fennema-Nio; PG20-3, Needs review).
- Jelte's v2 series (12 patches, 2026-10-28): https://www.postgresql.org/message-id/DMGSKK1XAEBJ.2I8XZ0MXQCXP0@jeltef.nl
- Nik's 2026-10-29 message with two follow-up patches on top of v2: https://www.postgresql.org/message-id/CAM527d9msnRB+wHTqT-PUzC28bFh1dFyaPyJ0QQ8CD0LzRADHg@mail.gmail.com
  - https://www.postgresql.org/message-id/attachment/207746/followup-fix-pytest-future-timeout.patch (SHA-256 5c6e2670dfa218cc13987b6e51169544d806eacebb15e4edd148625f2ca07133)
  - https://www.postgresql.org/message-id/attachment/207747/followup-test-pytest-portal-snapshot.patch (SHA-256 1627541e700269d6cbae7f0b2e8f03abf8136fcb4530ae07d9ab9b05230fa6be)
- cfbot now picks Nik's message as the latest patch set, applies only the follow-ups to master, and fails (the files exist only after Jelte's v2). The CF entry shows "Rebase needed since 2026-10-29", which hides Jelte's v2 from CI.
- Single action: resend the two follow-ups renamed with a nocfbot- prefix (cfbot then falls back to Jelte's v2), in a short new message on the thread.

## SHA-256 of the files in this directory (except this README)

```
```
