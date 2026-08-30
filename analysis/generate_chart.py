#!/usr/bin/env python3
"""Generate a chart of commit activity over time for the top-10 PostgreSQL committers.

Regenerate the input data (gitignored, ~1.2 MB) with:
    git log upstream/master --pretty=format:'%ad|%an' --date=format:'%Y' \
        > analysis/commits_by_year_author.txt
Then: python3 analysis/generate_chart.py
"""
from __future__ import annotations

import os
from collections import Counter, defaultdict

import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_PATH = os.path.join(HERE, "commits_by_year_author.txt")
OUT_PATH = os.path.join(HERE, "top10_activity.png")
OUT_STACKED_PATH = os.path.join(HERE, "top10_activity_stacked.png")
CSV_PATH = os.path.join(HERE, "top10_activity.csv")


def load_rows(path: str) -> list[tuple[int, str]]:
    rows: list[tuple[int, str]] = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            year_s, _, author = line.partition("|")
            if not year_s.isdigit() or not author:
                continue
            rows.append((int(year_s), author))
    return rows


def main() -> None:
    rows = load_rows(DATA_PATH)

    author_totals = Counter(a for _, a in rows)
    top10 = [a for a, _ in author_totals.most_common(10)]

    years = sorted({y for y, _ in rows})
    per_author_year: dict[str, dict[int, int]] = {
        a: defaultdict(int) for a in top10
    }
    for y, a in rows:
        if a in per_author_year:
            per_author_year[a][y] += 1

    with open(CSV_PATH, "w", encoding="utf-8") as f:
        f.write("year," + ",".join(top10) + "\n")
        for y in years:
            f.write(
                f"{y},"
                + ",".join(str(per_author_year[a].get(y, 0)) for a in top10)
                + "\n"
            )

    plt.style.use("dark_background")
    fig, ax = plt.subplots(figsize=(14, 8))

    cmap = plt.get_cmap("tab10")
    for idx, author in enumerate(top10):
        counts = [per_author_year[author].get(y, 0) for y in years]
        color = cmap(idx)
        lw = 3.0 if author == "Bruce Momjian" else 1.8
        alpha = 1.0 if author == "Bruce Momjian" else 0.85
        ax.plot(
            years,
            counts,
            label=f"{author} ({author_totals[author]:,})",
            color=color,
            linewidth=lw,
            alpha=alpha,
            marker="o",
            markersize=3,
        )

    ax.set_title(
        "PostgreSQL top-10 committers — commits per year",
        fontsize=16,
        pad=16,
    )
    ax.set_xlabel("Year")
    ax.set_ylabel("Commits")
    ax.grid(True, linestyle="--", alpha=0.3)
    ax.legend(loc="upper right", fontsize=9, frameon=False)

    fig.tight_layout()
    fig.savefig(OUT_PATH, dpi=150)

    fig2, ax2 = plt.subplots(figsize=(14, 8))
    series = [
        [per_author_year[a].get(y, 0) for y in years] for a in top10
    ]
    labels = [f"{a} ({author_totals[a]:,})" for a in top10]
    colors = [cmap(i) for i in range(len(top10))]
    ax2.stackplot(
        years,
        *series,
        labels=labels,
        colors=colors,
        alpha=0.9,
        edgecolor="black",
        linewidth=0.3,
    )
    ax2.set_title(
        "PostgreSQL top-10 committers — commits per year (stacked)",
        fontsize=16,
        pad=16,
    )
    ax2.set_xlabel("Year")
    ax2.set_ylabel("Commits")
    ax2.set_xlim(min(years), max(years))
    ax2.set_ylim(bottom=0)
    ax2.grid(True, linestyle="--", alpha=0.3)
    handles, lbls = ax2.get_legend_handles_labels()
    ax2.legend(
        handles[::-1],
        lbls[::-1],
        loc="upper right",
        fontsize=9,
        frameon=False,
    )
    fig2.tight_layout()
    fig2.savefig(OUT_STACKED_PATH, dpi=150)

    print(f"wrote {OUT_PATH}")
    print(f"wrote {OUT_STACKED_PATH}")
    print(f"wrote {CSV_PATH}")


if __name__ == "__main__":
    main()
