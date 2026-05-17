#!/usr/bin/env python3
"""Per-year stacked breakdowns of Bruce Momjian's commits.

Produces three charts:
  1. bruce_by_topdir.png      — top-level directory touched
  2. bruce_by_ext.png         — file extension touched
  3. bruce_by_category.png    — category inferred from commit subject

Regenerate the input data with:
    git log upstream/master --author='Bruce Momjian' --name-only \
        --pretty=format:'COMMIT|%ad|%s' --date=format:'%Y' \
        > analysis/bruce_commits.txt
Then: python3 analysis/generate_bruce_chart.py

For dir and extension charts, each commit is counted once per unique
dir/extension it touches, so a commit touching src/ and doc/ contributes +1
to each. The category chart assigns one category per commit.
"""
from __future__ import annotations

import os
import re
from collections import Counter, defaultdict

import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_PATH = os.path.join(HERE, "bruce_commits.txt")

TOP_N = 10


def parse(path: str) -> list[tuple[int, str, set[str], set[str]]]:
    """Return list of (year, subject, top_dirs, extensions) per commit."""
    commits: list[tuple[int, str, set[str], set[str]]] = []
    year: int | None = None
    subject = ""
    dirs: set[str] = set()
    exts: set[str] = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("COMMIT|"):
                if year is not None:
                    commits.append((year, subject, dirs, exts))
                _, _, rest = line.partition("|")
                y_s, _, subject = rest.partition("|")
                year = int(y_s)
                dirs = set()
                exts = set()
            elif line:
                top = line.split("/", 1)[0] if "/" in line else "(root)"
                dirs.add(top)
                base = line.rsplit("/", 1)[-1]
                if "." in base and not base.startswith("."):
                    ext = base.rsplit(".", 1)[-1].lower()
                    if len(ext) <= 8 and ext.isalnum():
                        exts.add(ext)
                    else:
                        exts.add("(other)")
                else:
                    exts.add(base if base in {"Makefile", "README", "COPYRIGHT"} else "(none)")
        if year is not None:
            commits.append((year, subject, dirs, exts))
    return commits


CATEGORY_RULES: list[tuple[str, re.Pattern[str]]] = [
    # order matters — first match wins
    ("release notes",    re.compile(r"relnotes?|release[-. ]?notes|pre-release|major[-. ]features", re.I)),
    ("pgindent",         re.compile(r"\bpgindent\b|\bre-?indent\b|\breformat\b", re.I)),
    ("copyright",        re.compile(r"copyright|stamp.*copy|update.*(year|date).*(header|source)", re.I)),
    ("translation/nls",  re.compile(r"\btranslat|\bnls\b|\bgettext\b|message[- ]?translation|\bpo/|\b[a-z]{2}\.po\b", re.I)),
    ("TODO list",        re.compile(
        r"^(add|added|done|update|remove|more|another|new|adjust|mention|move|clarify)[: ]\s*$"
        r"|^(add|added|done|update|remove|more|another|new|adjust|not done|patch reverted):"
        r"|\bTODO\s*(list|item|items)?\b"
        r"|^URL for:"
        r"|^Another add",
        re.I,
    )),
    ("pg_upgrade",       re.compile(r"\bpg_upgrade\b|\bpg_migrator\b", re.I)),
    ("win32/port",       re.compile(r"\bwin32\b|\bwindows\b|\bmingw\b|\bcygwin\b|\bmsvc\b|\bport(ability|ing)?\b", re.I)),
    ("autoconf/build",   re.compile(r"\bautoconf\b|\bautomake\b|\bconfigure\b|\bMakefile\b|build[- ]system|\bccache\b", re.I)),
    ("revert/backout",   re.compile(r"^revert\b|\bback ?out\b|\bbackout\b|^reverse\s+(?:out\b|number|prior)", re.I)),
    ("merge",            re.compile(r"^merge ", re.I)),
    ("typo/comment",     re.compile(r"\btypo\b|spelling|grammar|\bcomment(s|ary)?\b|whitespace", re.I)),
    ("docs",             re.compile(
        r"\bdoc(s|ument\w*)?\b|sgml|\bfaq\b|\bmanpage\b|\breadme\b|\bhtml\b"
        r"|\bclarif\w+|\bmention\b|\bwording\b|\brephras\w+|\bdescription\b",
        re.I,
    )),
    ("fix",              re.compile(r"^fix\b|\bbug[- ]?fix\b|\bfix(es|ed)?\b", re.I)),
    ("perf/optimize",    re.compile(r"\bperformance\b|\boptimi[sz]\w+\b|\bfaster\b|\bspeed[- ]?up\b", re.I)),
    ("test",             re.compile(r"^test\b|\bregress(ion)?\b|\bisolation test\b", re.I)),
    ("cleanup/refactor", re.compile(
        r"\bcleanup\b|clean[- ]up|\brefactor\b|\breorganiz\w*|\bconsolidat\w+|\bsimplif\w+|\brenam\w+"
        r"|^move\b|^remove\b|^change\b|^use\b|^mark\b|^adjust\b|^modif\w+",
        re.I,
    )),
    ("feature/change",   re.compile(
        r"^(add|allow|support|implement|enable|introduc\w+|new|extend|improv\w+"
        r"|make|have|update|prevent|increase|decrease|reduce|expand|change)\b",
        re.I,
    )),
    ("patch application", re.compile(
        r"^(attached|here(?:'s)?\b|this\s+(?:patch|change|commit|is)"
        r"|i\s+(?:have|think|added|added|committed|applied)|>\s|more\b|another\b|new\b)",
        re.I,
    )),
]


def classify(subject: str) -> str:
    s = subject.strip()
    for name, rx in CATEGORY_RULES:
        if rx.search(s):
            return name
    return "other"


def stacked_chart(
    years: list[int],
    per_year: dict[int, Counter[str]],
    title: str,
    ylabel: str,
    out_path: str,
    csv_path: str,
) -> None:
    totals: Counter[str] = Counter()
    for c in per_year.values():
        totals.update(c)
    top = [k for k, _ in totals.most_common(TOP_N)]
    overflow_keys = [k for k in totals if k not in top]
    overflow_name = "(misc)" if "other" in top else "other"

    series: dict[str, list[int]] = {k: [] for k in top}
    if overflow_keys:
        series[overflow_name] = []
    for y in years:
        counts = per_year[y]
        for k in top:
            series[k].append(counts.get(k, 0))
        if overflow_keys:
            series[overflow_name].append(sum(counts.get(k, 0) for k in overflow_keys))
    keys = top + ([overflow_name] if overflow_keys else [])

    with open(csv_path, "w", encoding="utf-8") as f:
        f.write("year," + ",".join(keys) + "\n")
        for i, y in enumerate(years):
            f.write(f"{y}," + ",".join(str(series[k][i]) for k in keys) + "\n")

    plt.style.use("dark_background")
    fig, ax = plt.subplots(figsize=(14, 8))
    cmap = plt.get_cmap("tab10")
    colors = [cmap(i % 10) for i in range(len(keys))]
    labels = [f"{k} ({sum(series[k]):,})" for k in keys]
    ax.stackplot(
        years,
        *[series[k] for k in keys],
        labels=labels,
        colors=colors,
        alpha=0.9,
        edgecolor="black",
        linewidth=0.3,
    )
    ax.set_title(title, fontsize=16, pad=16)
    ax.set_xlabel("Year")
    ax.set_ylabel(ylabel)
    ax.set_xlim(min(years), max(years))
    ax.set_ylim(bottom=0)
    ax.grid(True, linestyle="--", alpha=0.3)
    handles, lbls = ax.get_legend_handles_labels()
    ax.legend(handles[::-1], lbls[::-1], loc="upper right", fontsize=10, frameon=False)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    print(f"wrote {out_path}")
    print(f"wrote {csv_path}")


def main() -> None:
    commits = parse(DATA_PATH)
    print(f"commits parsed: {len(commits)}")

    years = sorted({y for y, *_ in commits})

    per_year_dir: dict[int, Counter[str]] = defaultdict(Counter)
    per_year_ext: dict[int, Counter[str]] = defaultdict(Counter)
    per_year_cat: dict[int, Counter[str]] = defaultdict(Counter)
    for year, subject, dirs, exts in commits:
        if dirs:
            for d in dirs:
                per_year_dir[year][d] += 1
        else:
            per_year_dir[year]["(no files)"] += 1
        if exts:
            for e in exts:
                per_year_ext[year][e] += 1
        else:
            per_year_ext[year]["(no files)"] += 1
        per_year_cat[year][classify(subject)] += 1

    stacked_chart(
        years,
        per_year_dir,
        "Bruce Momjian — commits per year by top-level directory",
        "Commits (per unique top-level dir touched)",
        os.path.join(HERE, "bruce_by_topdir.png"),
        os.path.join(HERE, "bruce_by_topdir.csv"),
    )
    stacked_chart(
        years,
        per_year_ext,
        "Bruce Momjian — commits per year by file extension",
        "Commits (per unique extension touched)",
        os.path.join(HERE, "bruce_by_ext.png"),
        os.path.join(HERE, "bruce_by_ext.csv"),
    )
    stacked_chart(
        years,
        per_year_cat,
        "Bruce Momjian — commits per year by subject category",
        "Commits",
        os.path.join(HERE, "bruce_by_category.png"),
        os.path.join(HERE, "bruce_by_category.csv"),
    )


if __name__ == "__main__":
    main()
