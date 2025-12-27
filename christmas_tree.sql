-- 🎄 Happy Christmas - SQL version of MongoDB aggregation tree
-- Original: db.aggregate([{$documents:[{}]}, ...])
-- Credit: Franck Pachot's MongoDB version

-- Simple version (matches MongoDB output exactly)
SELECT repeat(' ', 9 - i) || repeat('*', 1 + i * 2) AS tree
FROM generate_series(0, 9) AS i;

-- 🎄 Emoji version with star, ornaments, trunk and presents!
SELECT tree FROM (
    -- Star on top
    SELECT 0 AS ord, repeat(' ', 10) || '⭐' AS tree
    UNION ALL
    -- Tree with random ornaments (🔴 red balls, 🌲 green branches)
    SELECT i + 1,
           repeat(' ', 9 - i) ||
           string_agg(CASE WHEN random() < 0.3 THEN '🔴' ELSE '🌲' END, '' ORDER BY g) AS tree
    FROM generate_series(0, 9) AS i
    CROSS JOIN generate_series(1, 1 + i * 2) AS g
    GROUP BY i
    UNION ALL
    -- Trunk
    SELECT 11, repeat(' ', 8) || '🪵🪵🪵' AS tree
    UNION ALL
    SELECT 12, repeat(' ', 8) || '🪵🪵🪵' AS tree
    UNION ALL
    -- Presents
    SELECT 13, repeat(' ', 4) || '🎁 🎀 🎁 🎀 🎁' AS tree
) t ORDER BY ord;

-- 🌈 Colorful version with multiple ornament colors
SELECT tree FROM (
    SELECT 0 AS ord, '  ❄️  ❄️    ⭐    ❄️  ❄️' AS tree
    UNION ALL
    SELECT i + 1,
           repeat(' ', 9 - i) ||
           string_agg(
               CASE (random() * 10)::int
                   WHEN 0 THEN '🔴'  -- red ornament
                   WHEN 1 THEN '🔵'  -- blue ornament
                   WHEN 2 THEN '🟡'  -- gold ornament
                   WHEN 3 THEN '✨'  -- sparkle
                   ELSE '🟢'         -- green tree
               END, '' ORDER BY g
           ) AS tree
    FROM generate_series(0, 9) AS i
    CROSS JOIN generate_series(1, 1 + i * 2) AS g
    GROUP BY i
    UNION ALL
    SELECT 11, repeat(' ', 8) || '🟫🟫🟫' AS tree
    UNION ALL
    SELECT 12, '  🎁  🎄  🎅  🦌  🎁  🎄' AS tree
    UNION ALL
    SELECT 13, '  ⛄  🎶  🔔  🎵  ⛄  🎉' AS tree
) t ORDER BY ord;
