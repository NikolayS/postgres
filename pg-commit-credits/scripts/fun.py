"""Records, rhythms and archaeology -> data/fun.json

  bugs       age of bugs at fix time, for fixes that name the commit that introduced the bug
  trailers   credit-trailer counts per year, and the most-reviewed commit
  backpatch  Backpatch-through targets and the reporters behind backpatched fixes
  streaks    committer daily streaks and active-day share since 2001; Tom Lane's calendar
  clock      night and weekend share per committer, and a weekday x hour heatmap
  ladder     first role -> later roles; one-time contributors; all-five-roles club; credit-to-commit-bit
  busy       busiest single day and longest daily streak for non-committers
  duos       most frequent co-author pairs
  threads    where 2026 Discussion threads start (message-id domain), commits with no thread
  words      commit-message length by committer
  cards      vanity hashes and holiday commits
  people     records for Nikolay Samokhvalov and Andrey Borodin
"""
import sys, os, re, json, subprocess, collections, unicodedata, statistics, datetime, itertools
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import PG_REPO, PG_REF, DATA, CUT, ASOF

def git(*a):
    return subprocess.run(['git', '-C', PG_REPO] + list(a), capture_output=True, text=True).stdout

def fold(n):  # merge "Álvaro Herrera" and "Alvaro Herrera"
    return ''.join(c for c in unicodedata.normalize('NFKD', n) if not unicodedata.combining(c))

D = json.load(open(os.path.join(DATA, 'all.json'))); rows = D['rows']; disp = D['disp']
nm = lambda k: disp.get(k, k)
NIK, AB = 'e:samokhvalov@gmail.com', 'e:amborodin86@gmail.com'
committers = {k for h, d, m in rows for k, r in m.items() if 'commit' in r}
out = {}
Y = [str(y) for y in range(2019, 2027)]

# full log since 2019 with times, plus a light log since 2001
SEP = '\x1e'
log = []
for c in git('log', PG_REF, '--since=2019-01-01', f'--format={SEP}%H%x01%ct%x01%cd%x01%cn%x01%B', '--date=iso').split(SEP)[1:]:
    H, ct, cd, cn, b = c.split('\x01', 4)
    log.append(dict(H=H, h=H[:10], ct=int(ct), cd=cd, d=cd[:10], cn=fold(cn), b=b))
full = [l.split('\x01') for l in git('log', PG_REF, '--format=%H%x01%cd%x01%cn%x01%s', '--date=iso').splitlines()]
full = [dict(H=a, cd=b, d=b[:10], cn=fold(c), s=s) for a, b, c, s in full]

# ---------------------------------------------------------------- bug archaeology
BUG = re.compile(r'\b(oversight|thinko|mistake|bug|regression|broken|breakage)\b[^.;]{0,30}?\b(in|by|since|from|at) commit\s+([0-9a-f]{7,40})', re.I)
ct_of = {}
def ctime(h):
    if h not in ct_of:
        r = git('log', '-1', '--format=%ct%x01%ad%x01%s', '--date=short', h, '--').strip()
        ct_of[h] = r.split('\x01') if r else None
    return ct_of[h]
bugs = []
for c in log:
    m = BUG.search(c['b'].replace('\n', ' '))
    if not m: continue
    r = ctime(m.group(3))
    if not r: continue
    age = (c['ct'] - int(r[0])) / 86400
    if age < 0: continue
    bugs.append(dict(h=c['h'], d=c['d'], cn=c['cn'], s=c['b'].split('\n')[0][:90], age=round(age), introduced=r[1], ih=m.group(3)[:10], is_=r[2][:80]))
ages = [b['age'] for b in bugs]
edges = [(0, 7, '≤ 1 week'), (8, 30, '1 week – 1 month'), (31, 182, '1–6 months'), (183, 365, '6–12 months'),
         (366, 730, '1–2 years'), (731, 1826, '2–5 years'), (1827, 3652, '5–10 years'), (3653, 10**6, '10+ years')]
out['bugs'] = dict(n=len(bugs), median=statistics.median(ages) if ages else 0,
                   hist=[dict(label=l, n=sum(1 for a in ages if lo <= a <= hi)) for lo, hi, l in edges],
                   oldest=sorted(bugs, key=lambda b: -b['age'])[:12], all=bugs)

# ---------------------------------------------------------------- trailer era
TK = {'reviewed-by': 'Reviewed-by', 'reported-by': 'Reported-by', 'co-authored-by': 'Co-authored-by',
      'suggested-by': 'Suggested-by', 'tested-by': 'Tested-by', 'author': 'Author'}
tr = {v: collections.Counter() for v in TK.values()}; maxrev = (0, None)
for c in log:
    nrev = 0
    for l in c['b'].split('\n'):
        m = re.match(r'^([A-Za-z-]+):', l)
        if m and m.group(1).lower() in TK:
            k = TK[m.group(1).lower()]
            n = len([p for p in re.split(r',|\band\b', re.sub(r'<[^>]*>', '', l.split(':', 1)[1])) if p.strip()])
            tr[k][c['d'][:4]] += n
            if k == 'Reviewed-by': nrev += n
    if nrev > maxrev[0]: maxrev = (nrev, dict(h=c['h'], d=c['d'], cn=c['cn'], s=c['b'].split('\n')[0][:90], n=nrev))
out['trailers'] = dict(years={k: {y: v.get(y, 0) for y in Y} for k, v in tr.items()}, maxrev=maxrev[1])

# ---------------------------------------------------------------- backpatch
roles_by_h = {h: m for h, d, m in rows}
bp = collections.Counter(); bprep = collections.Counter(); bpdeep = collections.Counter(); nbp = 0; master_only = 0
for c in log:
    m = re.search(r'^Backpatch-through:\s*([0-9.]+|master)', c['b'], re.M | re.I)
    if not m: continue
    v = m.group(1)
    if v.lower() == 'master': master_only += 1; continue
    nbp += 1; bp[v] += 1
    if c['d'] < '2022': continue
    for k, r in roles_by_h.get(c['h'], {}).items():
        if 'report' in r:
            bprep[k] += 1
            try:
                if float(v) <= 13: bpdeep[k] += 1
            except ValueError: pass
order = sorted(bp, key=lambda v: float(v))
out['backpatch'] = dict(n=nbp, masterOnly=master_only, targets=[dict(v=v, n=bp[v]) for v in order if bp[v] >= 3],
                        reporters=[dict(rank=i + 1, name=nm(k), n=n, deep=bpdeep[k]) for i, (k, n) in enumerate(bprep.most_common()) if i < 15 or k in (NIK, AB)],
                        nik=bprep[NIK], ab=bprep[AB], nikRank=[k for k, _ in bprep.most_common()].index(NIK) + 1 if NIK in bprep else None,
                        abRank=[k for k, _ in bprep.most_common()].index(AB) + 1 if AB in bprep else None, nReporters=len(bprep))

# ---------------------------------------------------------------- streaks (committers, since 2001)
days = collections.defaultdict(set)
for c in full: days[c['cn']].add(c['d'])
def streak(ds):
    ds = sorted(datetime.date.fromisoformat(x) for x in ds); best = (1, ds[0], ds[0]); run = 1
    for a, b in zip(ds, ds[1:]):
        run = run + 1 if (b - a).days == 1 else 1
        if run > best[0]: best = (run, b - datetime.timedelta(days=run - 1), b)
    gap = max(((b - a).days, a, b) for a, b in zip(ds, ds[1:])) if len(ds) > 1 else (0, ds[0], ds[0])
    return best, gap
start = datetime.date(2001, 10, 1); end = datetime.date.fromisoformat(ASOF)
st = []
for cn, ds in days.items():
    if len(ds) < 300: continue
    (n, a, b), g = streak(ds)
    first = min(ds)
    span = (end - datetime.date.fromisoformat(max(first, '2001-10-01'))).days + 1
    st.append(dict(name=cn, streak=n, from_=str(a), to=str(b), days=len(ds), share=round(len(ds) / span * 100, 1), first=first))
st.sort(key=lambda x: -x['streak'])
tom = sorted(days.get('Tom Lane', []))
cal = collections.Counter(d[:4] for d in tom)
out['streaks'] = dict(top=st[:12], tom=dict(days=len(tom), span=(end - start).days + 1, byYear={y: cal[y] for y in sorted(cal)},
                      dates=tom, streak=next((s for s in st if s['name'] == 'Tom Lane'), None)))

# ---------------------------------------------------------------- clock (committers 2022+)
hours = collections.defaultdict(collections.Counter); wk = collections.defaultdict(collections.Counter); heat = collections.Counter()
for c in log:
    if c['d'] < '2022': continue
    dt = datetime.datetime.fromisoformat(c['cd'].replace(' +', '+').replace(' -', '-').replace(' ', 'T', 1))
    hours[c['cn']][dt.hour] += 1; wk[c['cn']][dt.weekday()] += 1; heat[(dt.weekday(), dt.hour)] += 1
cl = []
for cn, hh in hours.items():
    n = sum(hh.values())
    if n < 100: continue
    cl.append(dict(name=cn, n=n, night=round(sum(hh[h] for h in range(0, 6)) / n * 100, 1),
                   weekend=round((wk[cn][5] + wk[cn][6]) / n * 100, 1), peak=hh.most_common(1)[0][0], hours=[hh[h] for h in range(24)]))
tot = sum(heat.values())
out['clock'] = dict(committers=sorted(cl, key=lambda x: -x['n']), heat=[[heat[(d, h)] for h in range(24)] for d in range(7)],
                    weekendShare=round(sum(heat[(d, h)] for d in (5, 6) for h in range(24)) / tot * 100, 1),
                    peakHour=max(range(24), key=lambda h: sum(heat[(d, h)] for d in range(7))))

# ---------------------------------------------------------------- career ladder
first = {}; later = collections.defaultdict(set); ncred = collections.Counter(); allroles = collections.defaultdict(set); firstcommit = {}
for h, d, m in sorted(rows, key=lambda r: r[1]):
    for k, r in m.items():
        rr = set(r) - {'commit'}
        if 'commit' in r and k not in firstcommit: firstcommit[k] = d
        if not rr: continue
        ncred[k] += 1; allroles[k] |= rr
        if k not in first: first[k] = (d, rr)
        else: later[k] |= rr
def frole(rr):
    return 'author' if 'author' in rr else 'review' if 'review' in rr else 'report' if 'report' in rr else 'other'
lad = collections.defaultdict(lambda: collections.Counter())
for k, (d, rr) in first.items():
    if d < '2019-07-01' or k in committers: continue
    f = frole(rr); lad[f]['n'] += 1
    if ncred[k] == 1: lad[f]['once'] += 1
    for x in ('author', 'review', 'report'):
        if x in later[k]: lad[f][x] += 1
club = sorted([k for k, s in allroles.items() if {'author', 'review', 'report', 'test', 'suggest'} <= s], key=lambda k: -ncred[k])
bit = []
for k, d in firstcommit.items():
    if d >= '2020-01-01' and k in first and first[k][0] < d:
        bit.append(dict(name=nm(k), firstCredit=first[k][0], firstCommit=d,
                        days=(datetime.date.fromisoformat(d) - datetime.date.fromisoformat(first[k][0])).days))
pop = [k for k in first if first[k][0] >= '2019-07-01']
out['ladder'] = dict(roles={f: dict(lad[f]) for f in ('report', 'review', 'author')}, people=len(ncred),
                     once=sum(1 for k in ncred if ncred[k] == 1), club=[nm(k) for k in club], newCommitters=sorted(bit, key=lambda x: x['firstCommit']))

# ---------------------------------------------------------------- busiest days / streaks (non-committers)
pd = collections.defaultdict(collections.Counter)
for h, d, m in rows:
    for k, r in m.items():
        if k not in committers and set(r) - {'commit'}: pd[k][d] += 1
busy = sorted(((n, d, k) for k, c in pd.items() for d, n in c.items()), reverse=True)[:8]
nst = []
for k, c in pd.items():
    if len(c) < 3: continue
    (n, a, b), g = streak(c.keys()); nst.append((n, str(a), str(b), k))
nst.sort(reverse=True)
out['busy'] = dict(days=[dict(name=nm(k), d=d, n=n) for n, d, k in busy], streaks=[dict(name=nm(k), n=n, from_=a, to=b) for n, a, b, k in nst[:8]])

# ---------------------------------------------------------------- co-author duos
duo = collections.Counter()
for h, d, m in rows:
    a = sorted(k for k, r in m.items() if 'author' in r)
    if 2 <= len(a) <= 6:
        for p in itertools.combinations(a, 2): duo[p] += 1
ok = lambda k: re.fullmatch(r"[A-Z][\w.'-]*( [\w.'-]+)+", nm(k)) is not None
out['duos'] = [dict(a=nm(a), b=nm(b), n=n) for (a, b), n in duo.most_common(40) if ok(a) and ok(b)][:16]

# ---------------------------------------------------------------- threads (2026)
dom = collections.Counter(); nolink = collections.Counter(); ncom = collections.Counter(); nlinks = 0; multi = 0
for c in log:
    if c['d'][:4] != '2026': continue
    ids = set(re.findall(r'postgr\.es/m/(\S+)', c['b']))
    ncom[c['cn']] += 1
    if not ids: nolink[c['cn']] += 1
    if len(ids) >= 5: multi += 1
    for i in ids:
        i = i.replace('%40', '@').rstrip('>.,)')
        if '@' in i: dom[i.rsplit('@', 1)[1].lower()] += 1; nlinks += 1
GROUP = {'mail.gmail.com': 'Gmail', 'gmail.com': 'Gmail'}
g = collections.Counter()
for k, v in dom.items(): g[GROUP.get(k, k)] += v
out['threads'] = dict(links=nlinks, commits=sum(ncom.values()), nolink=sum(nolink.values()), multi=multi,
                      domains=[dict(d=k, n=v) for k, v in g.most_common(10)],
                      nolinkBy=sorted([dict(name=k, n=ncom[k], none=nolink[k], pct=round(nolink[k] / ncom[k] * 100)) for k in ncom if ncom[k] >= 60], key=lambda x: -x['pct']))

# ---------------------------------------------------------------- words
wc = collections.defaultdict(list); longest = None
for c in log:
    body = '\n'.join(l for l in c['b'].split('\n') if not re.match(r'^\s*[A-Za-z-]+:\s', l))
    n = len(body.split())
    wc[c['cn']].append(n)
    if not longest or n > longest['n']: longest = dict(h=c['h'], d=c['d'], cn=c['cn'], s=c['b'].split('\n')[0][:90], n=n)
allw = [n for v in wc.values() for n in v]
out['words'] = dict(median=statistics.median(allw), longest=longest,
                    by=sorted([dict(name=k, n=len(v), med=statistics.median(v)) for k, v in wc.items() if len(v) >= 150], key=lambda x: -x['med']))

# ---------------------------------------------------------------- cards
VAN = ('dead', 'beef', 'cafe', 'babe', 'face', 'f00d', 'c0de', 'feed', 'bad', 'ace', '0000', '1234', 'abcd')
van = [dict(H=c['H'][:12], d=c['d'], cn=c['cn'], s=c['s'][:80]) for c in full if c['H'].startswith(('dead', 'beef', 'cafe', 'babe', 'face', 'f00d', 'c0de', 'feed', '00000', '12345', 'abcde'))]
hol = collections.defaultdict(collections.Counter)
for c in full:
    if c['d'][5:] in ('12-25', '01-01'): hol[c['d'][5:]][c['cn']] += 1
xmasdays = collections.defaultdict(set)
for c in full:
    if c['d'][5:] == '12-25': xmasdays[c['cn']].add(c['d'][:4])
out['cards'] = dict(vanity=sorted(van, key=lambda x: x['H'])[:14], xmas=sorted([dict(name=k, years=len(v)) for k, v in xmasdays.items()], key=lambda x: -x['years'])[:6],
                    xmasCommits=sum(hol['12-25'].values()), nyCommits=sum(hol['01-01'].values()),
                    ny=[dict(name=k, n=v) for k, v in hol['01-01'].most_common(5)])

# ---------------------------------------------------------------- per-person records
def person(fname, key, label):
    hs = [z['h'] for z in json.load(open(os.path.join(DATA, fname)))]
    info = []
    for h in hs:
        r = git('log', '-1', '--format=%ct%x01%cd%x01%cn%x01%s%x01%B', '--date=short', h).split('\x01', 4)
        info.append(dict(h=h[:10], ct=int(r[0]), d=r[1], cn=fold(r[2]), s=r[3][:90],
                         bp=(re.search(r'^Backpatch-through:\s*([0-9.]+)', r[4], re.M | re.I) or [None, None])[1]))
    info.sort(key=lambda x: x['ct'])
    gaps = [((b['ct'] - a['ct']) / 86400, a, b) for a, b in zip(info, info[1:])]
    g = max(gaps, key=lambda x: x[0])
    win = max(sum(1 for y in info if 0 <= y['ct'] - x['ct'] < 30 * 86400) for x in info)
    winstart = max(info, key=lambda x: sum(1 for y in info if 0 <= y['ct'] - x['ct'] < 30 * 86400))
    wd = collections.Counter(datetime.date.fromisoformat(x['d']).weekday() for x in info)
    bps = [x['bp'] for x in info if x['bp']]
    deep = min(bps, key=float) if bps else None
    co = collections.Counter()
    for h, d, m in rows:
        if key in m and set(m[key]) - {'commit'}:
            for k, r in m.items():
                if k != key and set(r) - {'commit'}: co[k] += 1
    oldest = max((b for b in bugs if b['h'] in {x['h'] for x in info}), key=lambda b: b['age'], default=None)
    return dict(label=label, n=len(info), first=info[0], last=info[-1], gap=dict(days=round(g[0]), from_=g[1]['d'], to=g[2]['d']),
                window=dict(n=win, start=winstart['d']), saturday=wd[5], sunday=wd[6],
                bpCount=len(bps), bpDeep=deep, bpTargets=collections.Counter(bps).most_common(),
                co=[dict(name=nm(k), n=n) for k, n in co.most_common(6)], oldestBug=oldest,
                committers=collections.Counter(x['cn'] for x in info).most_common(3), list=info)
nik = person('Samokhvalov.json', NIK, 'Nikolay'); ab = person('Borodin.json', AB, 'Andrey')
nik['saga'] = [x for x in nik['list'] if x['cn'] == 'Amit Langote']
for p in (nik, ab): p.pop('list')
wkall = collections.Counter(datetime.date.fromisoformat(c['d']).weekday() for c in full)
out['people'] = dict(nik=nik, ab=ab, satShare=round(wkall[5] / sum(wkall.values()) * 100, 1))

json.dump(out, open(os.path.join(DATA, 'fun.json'), 'w'), ensure_ascii=False, default=str)
s = out
print('bugs', s['bugs']['n'], s['bugs']['median'], [ (b['age'], b['d'], b['s'][:50]) for b in s['bugs']['oldest'][:4]])
print('trailers', {k: list(v.values()) for k, v in s['trailers']['years'].items()}, s['trailers']['maxrev'])
print('backpatch', s['backpatch']['n'], s['backpatch']['masterOnly'], s['backpatch']['targets'], s['backpatch']['reporters'][:5], s['backpatch']['nik'], s['backpatch']['ab'])
print('streaks', [(x['name'], x['streak'], x['from_'], x['days'], x['share']) for x in s['streaks']['top'][:8]])
print('clock', s['clock']['weekendShare'], s['clock']['peakHour'], [(x['name'], x['n'], x['night'], x['weekend'], x['peak']) for x in s['clock']['committers'][:30]])
print('ladder', s['ladder']['roles'], s['ladder']['people'], s['ladder']['once'], len(s['ladder']['club']), s['ladder']['club'][:8], s['ladder']['newCommitters'])
print('busy', s['busy'])
print('duos', s['duos'][:8])
print('threads', {k: v for k, v in s['threads'].items() if k != 'nolinkBy'}, s['threads']['nolinkBy'][:5])
print('words', s['words']['median'], s['words']['longest'], [(x['name'], x['med']) for x in s['words']['by'][:5]], [(x['name'], x['med']) for x in s['words']['by'][-3:]])
print('cards', s['cards'])
for p in ('nik', 'ab'):
    q = s['people'][p]; print(p, {k: v for k, v in q.items() if k not in ('saga',)}); print('saga', len(q.get('saga', [])))
print('sat', s['people']['satShare'])
