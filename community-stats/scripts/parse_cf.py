#!/usr/bin/env python3
"""Parse saved commitfest pages -> cf.json (per CF summary) and cf_patches.tsv (per patch row)."""
import re, sys, json, html, os, glob

D = sys.argv[1]
cfs = []
rows = []
for f in sorted(glob.glob(os.path.join(D, 'cfpages', '*.html')), key=lambda p: int(os.path.basename(p)[:-5])):
    cid = int(os.path.basename(f)[:-5])
    t = open(f, encoding='utf-8').read()
    m = re.search(r'<title>Commitfest (\S+) \((\d{4}-\d\d-\d\d) – (\d{4}-\d\d-\d\d)\)', t)
    name, start, end = m.group(1), m.group(2), m.group(3)
    flat = re.sub(r'\s+', ' ', re.sub(r'<[^>]*>', ' ', t))
    sm = re.search(r'Status summary: (.*?)Total : (\d+)', flat)
    summary = {k.strip(): int(v) for k, v in re.findall(r'([A-Za-z ]+?) : (\d+)\.', sm.group(1))}
    total = int(sm.group(2))
    n = 0
    for tr in re.findall(r'<tr>(.*?)</tr>', t, re.S):
        pm = re.search(r'href="/patch/(\d+)/"', tr)
        if not pm:
            continue
        tds = re.findall(r'<td[^>]*>(.*?)</td>', tr, re.S)
        status = re.sub(r'<[^>]*>', '', re.search(r'class="badge[^"]*">([^<]*)<', tr).group(1)).strip()
        wraps = re.findall(r'<td class="wrap-text">(.*?)</td>', tr, re.S)
        authors = html.unescape(re.sub(r'<[^>]*>', '', wraps[0])).strip() if wraps else ''
        reviewers = html.unescape(re.sub(r'<[^>]*>', '', wraps[1])).strip() if len(wraps) > 1 else ''
        la = re.search(r'title="(\d{4}-\d\d-\d\d) \d\d:\d\d:\d\d"', tr)
        rows.append([cid, name, int(pm.group(1)), status, authors, reviewers, la.group(1) if la else ''])
        n += 1
    cfs.append(dict(id=cid, name=name, start=start, end=end, total=total, parsed=n, summary=summary))
    assert n == total, (cid, n, total)

json.dump(cfs, open(os.path.join(D, 'cf.json'), 'w'), indent=1)
with open(os.path.join(D, 'cf_patches.tsv'), 'w') as o:
    o.write('cf_id\tcf_name\tpatch_id\tstatus\tauthors\treviewers\tlast_activity\n')
    for r in rows:
        o.write('\t'.join(str(x).replace('\t', ' ') for x in r) + '\n')
print(len(cfs), 'CFs', len(rows), 'rows')
