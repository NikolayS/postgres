"""data/all.json -> data/contributors_by_year.csv (one row per person per year, 2019-2026)."""
import sys, os, csv, json, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import DATA
D = json.load(open(os.path.join(DATA, 'all.json'))); disp = D['disp']
agg = collections.defaultdict(lambda: collections.Counter())
for h, d, m in D['rows']:
    y = d[:4]
    if y < '2019':  # --since filters by commit date; a few commits have older author dates
        continue
    for k, roles in m.items():
        c = agg[(k, y)]
        nc = [r for r in roles if r != 'commit']
        if nc: c['credited_commits'] += 1
        for r in roles: c[r] += 1
cols = ['credited_commits', 'author', 'review', 'report', 'test', 'suggest', 'commit']
with open(os.path.join(DATA, 'contributors_by_year.csv'), 'w', newline='') as f:
    w = csv.writer(f); w.writerow(['person', 'id', 'year'] + cols)
    for (k, y), c in sorted(agg.items(), key=lambda kv: (kv[0][1], -kv[1]['credited_commits'])):
        w.writerow([disp.get(k, k), k, y] + [c[x] for x in cols])
print('wrote data/contributors_by_year.csv')
