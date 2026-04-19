# PostgreSQL contribution review — static dashboards

Two self-contained HTML pages about 2016–2025 PostgreSQL contributor activity.

- `index.html` — **Part I: The Postgres Decade** — nine sections built on
  [Robert Haas's](https://sites.google.com/site/robertmhaas/contributions)
  `contributions2025.dmp` + Andrey Borodin's 2025 `Reviewed-by:` parse.
- `part2.html` — **Part II: Beyond the Commit Log** — five additional lenses
  (inferred employer, per-subdirectory churn, back-branch activity, commitfest
  outcomes, posts-without-commits).

Both pages are self-contained: inline JSON, custom SVG, Google Fonts only,
no build step. Open either file in a browser. Theme toggle (ink / paper)
top-right. Add `?noanim=1` to suppress scroll-reveal animations.

- JSON source: `data/part1.json`, `data/part2.json`
- Branch: [`contrib-review`](..)
- Issues: [#1](../-/issues/1) (Part I) · [#2](../-/issues/2) (Part II)

## GitLab Pages

If the project's Pages is enabled, this branch publishes to
`https://<namespace>.gitlab.io/<project>/` via `.gitlab-ci.yml` at the repo root.
