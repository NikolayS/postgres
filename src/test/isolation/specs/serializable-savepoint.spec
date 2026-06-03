# Test that a serialization failure raised while *checking* a read (the
# "conflict out to pivot, during read" cancellation) cannot be discarded by
# rolling back to a SAVEPOINT.
#
# s1 and s2 form the classic write-skew dangerous structure under SERIALIZABLE:
#   s1 reads row 2 and writes row 1
#   s2 writes row 2 and reads row 1
# s1 commits first.  When s2 then reads row 1 it is correctly identified as the
# pivot of a dangerous structure and PostgreSQL raises
#   ERROR:  could not serialize access ...
#   (Canceled on conflict out to pivot ..., during read).
#
# Crucially, s2's *write* to row 2 happened BEFORE the savepoint, so it is not
# undone.  s2 only wraps the offending READ in a SAVEPOINT, rolls back to it
# (swallowing the error) and commits.  That COMMIT must fail: allowing it
# leaves both s1's and s2's writes committed, which is the write-skew anomaly
# SSI is supposed to prevent (no serial order exists).

setup
{
  CREATE TABLE t (id int PRIMARY KEY, v int);
  INSERT INTO t VALUES (1, 0), (2, 0);
}

teardown
{
  DROP TABLE t;
}

session s1
setup { BEGIN ISOLATION LEVEL SERIALIZABLE; }
step r1  { SELECT v FROM t WHERE id = 2; }
step w1  { UPDATE t SET v = 1 WHERE id = 1; }
step c1  { COMMIT; }

session s2
setup { BEGIN ISOLATION LEVEL SERIALIZABLE; }
step w2   { UPDATE t SET v = 1 WHERE id = 2; }
step sp2  { SAVEPOINT f; }
step r2   { SELECT v FROM t WHERE id = 1; }
step rb2  { ROLLBACK TO SAVEPOINT f; }
step c2   { COMMIT; }

# Used to observe the final committed state.
session s3
step rall { SELECT id, v FROM t ORDER BY id; }

# s2 takes its snapshot at w2 (before s1 commits), writes row 2, then after s1
# commits it reads row 1 inside a savepoint and is cancelled.  After rolling
# back to the savepoint it must not be able to commit.  If it does (the bug),
# rall shows both rows updated -- the non-serializable write-skew outcome.
permutation r1 w2 w1 c1 sp2 r2 rb2 c2 rall
