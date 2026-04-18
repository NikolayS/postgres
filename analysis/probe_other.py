#!/usr/bin/env python3
import os, sys
from collections import Counter
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from generate_bruce_chart import CATEGORY_RULES, parse  # noqa

def classify(s):
    for name, rx in CATEGORY_RULES:
        if rx.search(s):
            return name
    return "other"

commits = parse(os.path.join(HERE, "bruce_commits.txt"))
others = [s for _, s, *_ in commits if classify(s) == "other"]
print(f"total other: {len(others)}\n")
prefix = Counter()
for s in others:
    w = s.strip().lower().split()
    if w:
        prefix[w[0]] += 1
for w, n in prefix.most_common(25):
    print(f"{n:5d} {w}")
    examples = [s.strip()[:100] for s in others if s.strip().lower().startswith(w)][:3]
    for ex in examples:
        print(f"      - {ex}")
