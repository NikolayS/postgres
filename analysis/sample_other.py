#!/usr/bin/env python3
"""Sample and count subject-line patterns in the currently-unclassified commits."""
import os
import re
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from generate_bruce_chart import CATEGORY_RULES, parse  # noqa: E402

DATA_PATH = os.path.join(HERE, "bruce_commits.txt")


def classify(subject: str) -> str:
    for name, rx in CATEGORY_RULES:
        if rx.search(subject):
            return name
    return "other"


def main() -> None:
    commits = parse(DATA_PATH)
    others = [s for _, s, *_ in commits if classify(s) == "other"]
    print(f"total other: {len(others)}")

    firsts = Counter(s.strip().split()[0].lower() if s.strip() else "" for s in others)
    print("\ntop 40 first-words in 'other':")
    for w, n in firsts.most_common(40):
        print(f"  {n:5d}  {w}")

    print("\n30 random-ish samples (spread):")
    for s in others[::max(1, len(others) // 30)][:30]:
        print(f"  {s.strip()[:110]}")


if __name__ == "__main__":
    main()
