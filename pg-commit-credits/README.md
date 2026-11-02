# pg-commit-credits

Who gets credited in PostgreSQL commit messages, and how that changes over time. It covers 25 years of `master` (2001–2026) and focuses on **Nikolay Samokhvalov** and **Andrey Borodin**, with Alexander Kukushkin and Kirk Wolak for reference.

**The brief:** [`docs/index.html`](docs/index.html) is a self-contained page with charts. Open it in a browser after downloading it, or view the published version at https://claude.ai/artifact/MkumSYN4JuYfqYXxXkWcRg (shared on request).

Data runs through **2026-10-29**, the latest commit on master at the time of the analysis.

## Key findings

| | Nikolay Samokhvalov | Andrey Borodin |
|---|---|---|
| Commits credited, 2001–2026 | 33 (2007–2026) | 193 (2016–2026) |
| Commits in 2026, Jan 1–Oct 29 | 15 (same period of 2025: 4) | 55–56 (same period of 2025: 32) |
| Main role | Reporter (16) | Reviewer (118) |
| 2026 rank, non-committers | #57 of 549 | #16 of 549 |
| 2026 rank, `Reported-by` | **#8 of 312** | #54 |
| 2026 rank, `Reviewed-by` | #140 | **#17 of 251** |
| 2022–2026 rank, non-committers | #86 of 1,280 | #18 of 1,280 |

- **Largest gain in 2026:** Chao Li went from 74 to 366 credited commits. He is #2 overall, behind Tom Lane, and #1 among reviewers. Zsolt Parragi (1 → 118) and Ayush Tiwari (0 → 114) went from almost nothing to more than 100.
- **More people credited:** 580 distinct people were credited from Jan 1 to Oct 29, 2026, up from 451 in the same period of 2025.
- **Kirk Wolak:** credited on 6 commits, all from 2022–2024.
- **Alexander Kukushkin:** credited on 15 commits from 2013 to 2025, mostly as author, nearly all on HA and replication.
- **AI in the commit log:** 49 commits name AI tools (Claude, GPT/Codex, Xint Code and others), all of them in 2026 and none before February. That's 5.7% of 2026 commits that credit a bug reporter.
- **Companies:** only about 9% of credits can be tied to a company email domain. Among those, Fujitsu, Postgres Pro and EDB are steady, and Percona jumped in 2026.
- **Newcomers:** only about 1 in 5 first-time contributors is credited again the following year. 2026 has 318 newcomers, the most since at least 2019.
- **Release cycles:** PG19 credited 572 people, about twice as many as PG16 (282).
- **Bug archaeology:** 411 fixes since 2019 name the commit that caused the bug. The typical bug was 141 days old, and 10 were more than 10 years old (the oldest, 13.5 years).
- **Streaks:** Tom Lane has committed on 6,023 days since Oct 2001, 66% of all days, including a 58-day run in 2016.
- **Career ladder:** 59% of the 1,762 people credited since 2019 appear only once. People who start by reviewing go on to author a patch far more often than people who start by reporting a bug (29% vs 9%).

## Layout

```
run.sh                  rebuild everything
scripts/config.py       PG_REPO / PG_REF / YTD_CUT settings
scripts/roles.py        per-person timeline: grep commit messages, classify role
scripts/all.py          all contributors since 2019, parsed from credit trailers
scripts/rank.py         rankings, 2026 vs 2025 comparison, growth (prints a report)
scripts/q.py            extra cuts: growth rate, reporter and reviewer rankings
scripts/gen.py          builds data/brief.json for the page
scripts/extras.py       AI mentions, companies, committer network, code areas,
                        newcomer retention, release cycles -> data/extras.json
scripts/fun.py          records and rhythms: bug age, credit-line trends, backpatching, streaks,
                        commit clock, career ladder, big days, co-author duos, thread hosts,
                        message length, trivia, records for Nikolay and Andrey -> data/fun.json
scripts/export_csv.py   data/contributors_by_year.csv
scripts/build.py        puts brief.json and extras.json into template.html, writes docs/index.html
scripts/template.html   the page (inline SVG and HTML charts, no dependencies)
scripts/shot.js         optional Playwright screenshots
data/                   all generated outputs (JSON, CSV, rankings.txt)
```

## Reproduce

You need Python 3 (standard library only) and a PostgreSQL clone with `master` history back to 2001.

This directory sits inside a PostgreSQL checkout (`NikolayS/postgres`, branch `claude/great-lovelace-gf5t4g`), so by default the scripts analyze the repository it's in:

```bash
cd pg-commit-credits
./run.sh                                   # uses the enclosing repo, ref origin/master
PG_REPO=/path/to/postgres PG_REF=master ./run.sh   # or point at another clone
```

If you're working from a shallow clone, deepen it first with `git fetch --shallow-since=2001-10-01 origin master`.

## Method

- **Per-person timelines** (`roles.py`) find every commit whose message matches the name. That catches free-text credits ("Patch by X, reviewed by Y") as well as trailers. Roles come from the trailer key, or from the nearest role word before the name. A line containing only a name counts as authorship, which was the convention before about 2015. Vladimir Borodin is excluded. Kirk Wolak's email-only credits (`wolakk@gmail.com`) are included.
- **Rankings** (`all.py`) parse the `Author`, `Co-authored-by`, `Reviewed-by`, `Reported-by`, `Tested-by` and `Suggested-by` trailers, including continuation lines. When a commit has no `Author:` trailer, the git author (the committer) is counted as the author. Name variants are merged by shared email address and by ignoring middle initials. The merging isn't perfect. Free-text credits are not counted, so totals here can be a little lower than the per-person timelines.
- **Growth** compares Jan 1 to `YTD_CUT` (Oct 29) of 2026 with the same dates in 2025. The share of commits that use credit trailers rose from 82% to 88% over that time, which slightly inflates 2026 growth for everyone.
- **Data cutoff** is the date of the newest commit on `PG_REF` (override with `ASOF=YYYY-MM-DD`). The page's dates and the same-period comparison follow it automatically. The headline sentences in `scripts/template.html` are written by hand and need a review after each refresh.
- **AI mentions** match tool names (Claude, GPT, Codex, OpenAI, Anthropic, LLM, Xint Code and others) anywhere in a commit message. Each commit goes into the first group that fits: tool credited by name, person credited working with AI, AI found the bug, AI helped draft the patch, or the message discusses AI reports.
- **Companies** come from email domains. A person counts for a company in a year only when its domain is the address they used most that year. Only 6–10% of credits can be matched, and a domain doesn't prove employment.
- **Bug age** counts only fixes whose message names the culprit commit with a bug word (oversight, thinko, bug, regression, broken) right before "in/by/since commit <hash>". The age is the time between the two commits.
- **Streaks and the commit clock** use committer dates and each committer's own timezone. Committer names that differ only in accents are merged.
- **Career ladder** counts people first credited after mid-2019 who aren't committers. "From first credit to committer" is a lower bound for anyone already credited before 2019.
- **Newcomers** are people credited for the first time since 2019.
- **Release cycles** run from one `Stamp HEAD as N devel` commit to the next.
- **"Committer"** means anyone who committed to master in 2022–2026 (32 people). Committers get credit for their own commits, so the brief also ranks non-committers separately.
- **`data/all.json`** holds every commit since 2019 as `[hash, date, {person_id: [roles]}]`, plus `disp`, which maps each person_id to a display name.
