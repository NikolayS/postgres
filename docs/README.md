# The Postgres Decade — contribution review dashboards

Two single-page infographics summarising 2016–2025 PostgreSQL contributor activity.

- `index.html` — **Part I: The Postgres Decade** — nine sections built on
  [Robert Haas's](https://sites.google.com/site/robertmhaas/contributions)
  annual `contributions2025.dmp` + Andrey Borodin's 2025 `Reviewed-by:` data.
- `part2.html` — **Part II: Beyond the Commit Log** — five additional lenses
  (affiliation, subsystem churn, backports, commitfest, list vs log).

Both pages are self-contained (inline JSON, custom SVG, Google Fonts only).
Open either file in a browser to view. A theme toggle (ink / paper) is in the
top-right corner of each page.

- source data: `data/part1.json`, `data/part2.json`
- see also: [issue #1](../-/issues/1)
