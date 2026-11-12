#!/usr/bin/env python3
"""Aggregate per-message TSVs into monthly / yearly CSVs."""
import sys, os, glob, csv, calendar, collections

S = sys.argv[1]
asof = sys.argv[2]  # YYYY-MM-DD, last day covered for the current month
files = sorted(glob.glob(os.path.join(S, 'mbox', '??????.tsv')))
seen_ids = set()
first_seen = {}
first_patch = {}
M = collections.OrderedDict()
ai_terms = collections.Counter()
YS = collections.defaultdict(set)
for f in files:
    mon = os.path.basename(f)[:6]
    key = f'{mon[:4]}-{mon[4:]}'
    m = M.setdefault(key, collections.Counter())
    senders = set(); patch_senders = set(); ai_senders = set()
    for line in open(f, encoding='utf-8', errors='replace'):
        p = line.rstrip('\n').split('\t')
        if len(p) < 7:
            continue
        d, frm, mid, start, patch, ai, terms = p[:7]
        if mid and mid in seen_ids:
            m['dupes'] += 1
            continue
        if mid:
            seen_ids.add(mid)
        m['messages'] += 1
        m['thread_starts'] += int(start)
        m['patch_messages'] += int(patch)
        m['patch_thread_starts'] += int(start) & int(patch)
        senders.add(frm); YS[key[:4]].add(frm)
        if frm not in first_seen:
            first_seen[frm] = key
            m['first_time_senders'] += 1
            if patch == '1':
                m['first_time_senders_with_patch'] += 1
        if patch == '1':
            patch_senders.add(frm)
            if frm not in first_patch:
                first_patch[frm] = key
                m['first_time_patch_senders'] += 1
        if ai == '1':
            m['ai_messages'] += 1
            m['ai_patch_messages'] += int(patch)
            m['ai_thread_starts'] += int(start)
            ai_senders.add(frm)
            for t in terms.split(','):
                if t:
                    ai_terms[(key[:4], t)] += 1
            if 'ai-trailer' in terms:
                m['ai_trailer_messages'] += 1
    m['senders'] = len(senders)
    m['patch_senders'] = len(patch_senders)
    m['ai_senders'] = len(ai_senders)

cols = ['month', 'days_covered', 'partial', 'messages', 'messages_per_day', 'thread_starts', 'patch_messages',
        'patch_thread_starts', 'senders', 'patch_senders', 'first_time_senders', 'first_time_patch_senders',
        'first_time_senders_with_patch', 'ai_messages', 'ai_share_pct', 'ai_patch_messages', 'ai_thread_starts',
        'ai_senders', 'ai_trailer_messages']
y, mo, dd = map(int, asof.split('-'))
with open(os.path.join(S, 'hackers_monthly.csv'), 'w', newline='') as o:
    w = csv.writer(o); w.writerow(cols)
    for k, m in M.items():
        yy, mm = map(int, k.split('-'))
        days = calendar.monthrange(yy, mm)[1]
        partial = 0
        if (yy, mm) == (y, mo):
            days, partial = dd, 1
        row = dict(m); row['month'] = k; row['days_covered'] = days; row['partial'] = partial
        row['messages_per_day'] = round(m['messages'] / days, 1)
        row['ai_share_pct'] = round(100 * m['ai_messages'] / m['messages'], 2) if m['messages'] else 0
        w.writerow([row.get(c, 0) for c in cols])

# yearly
Y = collections.OrderedDict()
for k, m in M.items():
    Y.setdefault(k[:4], collections.Counter()).update({a: b for a, b in m.items() if a not in ('senders', 'patch_senders', 'ai_senders')})
fy = collections.Counter(k[:4] for k in first_seen.values())
with open(os.path.join(S, 'hackers_yearly.csv'), 'w', newline='') as o:
    w = csv.writer(o); w.writerow(['year', 'messages', 'thread_starts', 'patch_messages', 'senders', 'first_time_senders', 'ai_messages'])
    for yy, c in Y.items():
        w.writerow([yy, c['messages'], c['thread_starts'], c['patch_messages'], len(YS[yy]), fy[yy], c['ai_messages']])
with open(os.path.join(S, 'hackers_ai_terms.csv'), 'w', newline='') as o:
    w = csv.writer(o); w.writerow(['year', 'term', 'messages'])
    for (yy, t), n in sorted(ai_terms.items()):
        w.writerow([yy, t, n])
print(len(M), 'months', sum(m['messages'] for m in M.values()), 'messages', sum(m['dupes'] for m in M.values()), 'dupes')
