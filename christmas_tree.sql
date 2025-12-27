-- 🎄 Happy Christmas - SQL version of MongoDB aggregation tree
-- Original: db.aggregate([{$documents:[{}]}, ...])

SELECT repeat(' ', 9 - i) || repeat('*', 1 + i * 2) AS tree
FROM generate_series(0, 9) AS i;
