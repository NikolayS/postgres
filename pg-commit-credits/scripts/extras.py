"""Extra analyses for the brief -> data/extras.json

  ai         commits that mention AI / LLM tools (2019-2026), classified by how AI was involved,
             plus yearly counts for fuzzers, static analysis and sanitizers for comparison
  companies  credited commits per company per year, from corporate email domains
  network    which committers commit which contributors' work (2022-2026)
  codemap    which parts of the source tree Nikolay's and Andrey's credited commits touch
  retention  newcomer cohorts: are first-time contributors credited again later?
  releases   credits per PostgreSQL development cycle on master (PG13-PG20)
"""
import sys, os, re, json, subprocess, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import PG_REPO, PG_REF, DATA, CUT

def git(*a):
    return subprocess.run(['git', '-C', PG_REPO] + list(a), capture_output=True, text=True).stdout

D = json.load(open(os.path.join(DATA, 'all.json')))
disp = D['disp']; rows = D['rows']
NIK, AB = 'e:samokhvalov@gmail.com', 'e:amborodin86@gmail.com'
nm = lambda k: disp.get(k, k)
committers = {k for h, d, m in rows if d[:4] >= '2022' for k, r in m.items() if 'commit' in r}
credited = lambda r: any(x != 'commit' for x in r)
out = {}

# ---------------------------------------------------------------- AI and tools
log = git('log', PG_REF, '--since=2019-01-01', '--format=%x00%h%x01%ad%x01%cn%x01%B', '--date=short')
AI = re.compile(r'\b(claude|chatgpt|gpt-?\d|openai|llms?\b|large language model|copilot|gemini|codex|ai[- ]assisted|'
                r'ai[- ]generated|anthropic|xint|cybernative|antaisecuritylab)', re.I)
TOOLS = {
    'AI / LLM': AI,
    'Fuzzers': re.compile(r'sqlsmith|sqlancer|fuzz|\bafl\b|libfuzzer|squirrel', re.I),
    'Static analysis': re.compile(r'coverity|cppcheck|pvs-studio|svace|clang[- ]tidy|codeql|static analy[sz]', re.I),
    'Sanitizers / valgrind': re.compile(r'valgrind|addresssanitizer|\basan\b|ubsan|undefinedbehaviorsanitizer|sanitizer', re.I),
}
TRAILER = re.compile(r'^\s*(Reported-by|Author|Co-authored-by|Analyzed-by|Diagnosed-by|Reviewed-by|Tested-by|Suggested-by):', re.I)
CATS = ['Tool credited by name', 'Person credited, working with AI', 'AI found or diagnosed the bug',
        'AI helped draft the patch', 'Commit message discusses AI reports']

def classify(b):
    lines = [l.strip() for l in b.split('\n') if AI.search(l)]
    tl = [l for l in lines if TRAILER.match(l)]
    txt = ' '.join(lines)
    if tl and any(re.search(r'collaboration with|\(using|\(openai', l, re.I) is None for l in tl):
        return CATS[0], tl[0]
    if tl or re.search(r'found by [\w ]+? using|using claude|llm-guided review', txt, re.I):
        return CATS[1], (tl or lines)[0]
    if re.search(r'(claude code|claude) (found|diagnosed)', txt, re.I) or re.search(r'found via review by', txt, re.I):
        return CATS[2], lines[0]
    if re.search(r'drafts? of this patch|claude wrote|ai-generated|made with', ' '.join(b.split('\n')), re.I):
        m = re.search(r'[^.\n]*(drafts? of this patch|Claude wrote|AI-generated)[^.]*\.?', b.replace('\n', ' '), re.I)
        return CATS[3], (m.group(0).strip() if m else lines[0])
    return CATS[4], lines[0]

tools_year = collections.defaultdict(collections.Counter)
ai_list = []
for c in log.split('\0')[1:]:
    h, d, cn, b = c.split('\x01', 3)
    for k, p in TOOLS.items():
        if p.search(b): tools_year[k][d[:4]] += 1
    if AI.search(b):
        cat, quote = classify(b)
        ai_list.append(dict(h=h[:10], d=d, cn=cn, s=b.split('\n')[0][:100], cat=cat, q=re.sub(r'<[^>]*>', '', quote)[:160]))
mon = collections.Counter(x['d'][:7] for x in ai_list)
rep26 = [(h, d, m) for h, d, m in rows if d[:4] == '2026' and d[4:] <= CUT]
nrep = sum(1 for h, d, m in rep26 if any('report' in r for r in m.values()))
out['ai'] = dict(
    list=sorted(ai_list, key=lambda x: x['d'], reverse=True),
    months={f'2026-{i:02d}': mon.get(f'2026-{i:02d}', 0) for i in range(1, 11)},
    cats={c: sum(1 for x in ai_list if x['cat'] == c) for c in CATS},
    committers=collections.Counter(x['cn'] for x in ai_list).most_common(),
    first=min(x['d'] for x in ai_list) if ai_list else None,
    tools={k: {str(y): v.get(str(y), 0) for y in range(2019, 2027)} for k, v in tools_year.items()},
    reportCommits26=nrep,
    aiReportCommits26=sum(1 for x in ai_list if x['d'][:4] == '2026' and x['d'][4:] <= CUT and x['cat'] in CATS[:3]),
)

# ---------------------------------------------------------------- companies
COMPANY = {
    'enterprisedb.com': 'EDB', '2ndquadrant.com': 'EDB', '2ndquadrant.fr': 'EDB',
    'fujitsu.com': 'Fujitsu', 'jp.fujitsu.com': 'Fujitsu', 'cn.fujitsu.com': 'Fujitsu',
    'postgrespro.ru': 'Postgres Pro', 'postgrespro.com': 'Postgres Pro',
    'percona.com': 'Percona', 'cybertec.at': 'CYBERTEC', 'highgo.com': 'HighGo', 'highgo.ca': 'HighGo',
    'yandex-team.ru': 'Yandex', 'sraoss.co.jp': 'SRA OSS', 'oss.nttdata.com': 'NTT DATA',
    'nttdata.com': 'NTT DATA', 'lab.ntt.co.jp': 'NTT DATA', 'timescale.com': 'Timescale / TigerData',
    'tigerdata.com': 'Timescale / TigerData', 'datadoghq.com': 'Datadog', 'neon.tech': 'Neon',
    'databricks.com': 'Neon', 'halodbtech.com': 'Halo', 'tantorlabs.com': 'Tantor Labs',
    'tantorlabs.ru': 'Tantor Labs', 'dalibo.com': 'Dalibo', 'amazon.com': 'AWS', 'amazon.de': 'AWS',
    'amazon.co.uk': 'AWS', 'postgres.ai': 'Postgres.ai', 'google.com': 'Google', 'yugabyte.com': 'Yugabyte',
    'hpe.com': 'HPE', 'planetscale.com': 'PlanetScale', 'alibaba-inc.com': 'Alibaba', 'microsoft.com': 'Microsoft',
    'crunchydata.com': 'Crunchy Data', 'supabase.io': 'Supabase', 'supabase.com': 'Supabase', 'aiven.io': 'Aiven',
    'huawei.com': 'Huawei', 'vmware.com': 'VMware', 'pivotal.io': 'VMware', 'intel.com': 'Intel',
    'pgedge.com': 'pgEdge', 'snowflake.com': 'Snowflake', 'clear-code.com': 'ClearCode', 'tomtom.com': 'TomTom',
}
pe = D['pemail']
def company(k, y):
    ys = pe.get(k, {})
    # A person counts for a company in a year only when the company domain is the address
    # they used most that year (nearest year with any address if they gave none).
    for yy in [y] + [str(int(y) + i) for i in (-1, 1, -2, 2)]:
        if ys.get(yy):
            return COMPANY.get(collections.Counter(ys[yy]).most_common(1)[0][0])
    return None
comp = collections.defaultdict(collections.Counter); tot = collections.Counter(); pc = collections.Counter(); pcc = collections.Counter(); cpeople = collections.defaultdict(collections.Counter)
for h, d, m in rows:
    y = d[:4]
    if y < '2019': continue
    tot[y] += 1
    cr = [company(k, y) for k, r in m.items() if credited(r)]
    if y >= '2022':
        for k, r in m.items():
            if credited(r) and company(k, y): cpeople[company(k, y)][k] += 1
    pc[y] += len(cr); pcc[y] += sum(1 for c in cr if c)
    seen = set(cr) - {None}
    for c in seen: comp[c][y] += 1
top = sorted(comp, key=lambda c: -sum(comp[c][y] for y in ('2022', '2023', '2024', '2025', '2026')))[:16]
out['companies'] = dict(order=top, people={c: [nm(k) for k, _ in cpeople[c].most_common(3)] for c in top}, years={c: {str(y): comp[c].get(str(y), 0) for y in range(2019, 2027)} for c in top},
                        totals={str(y): tot[str(y)] for y in range(2019, 2027)},
                        coverage={str(y): round(pcc[str(y)] / pc[str(y)] * 100, 1) for y in range(2019, 2027)})

# ---------------------------------------------------------------- network
pairs = collections.Counter(); bycommitter = {NIK: collections.Counter(), AB: collections.Counter()}
for h, d, m in rows:
    if d[:4] < '2022': continue
    cs = [k for k, r in m.items() if 'commit' in r]
    if not cs: continue
    c = cs[0]
    for k, r in m.items():
        if k == c or not credited(r) or k in committers: continue
        pairs[(k, c)] += 1
        if k in bycommitter: bycommitter[k][c] += 1
out['network'] = dict(
    pairs=[dict(a=nm(a), b=nm(b), n=n, hl=('nik' if a == NIK else 'ab' if a == AB else '')) for (a, b), n in pairs.most_common(40)],
    nik=[dict(name=nm(k), n=n) for k, n in bycommitter[NIK].most_common()],
    ab=[dict(name=nm(k), n=n) for k, n in bycommitter[AB].most_common()],
)

# ---------------------------------------------------------------- code map
def area(p):
    s = p.split('/')
    if s[0] == 'doc': return 'docs'
    if s[0] == 'contrib': return 'contrib/' + s[1] if len(s) > 2 else 'contrib'
    if s[:2] == ['src', 'backend']: return 'backend/' + (s[2] if len(s) > 3 else '')
    if s[:2] == ['src', 'bin']: return 'bin/' + s[2] if len(s) > 3 else 'bin'
    if s[:2] == ['src', 'test']: return 'tests'
    if s[:2] == ['src', 'include']: return 'headers'
    if s[0] == 'src' and len(s) > 2: return s[1]
    return 'other'
cm = {}
for who, f in (('nik', 'Samokhvalov.json'), ('ab', 'Borodin.json')):
    hs = [z['h'] for z in json.load(open(os.path.join(DATA, f)))]
    cnt, lines = collections.Counter(), collections.Counter()
    for h in hs:
        seen = set()
        for l in git('show', '--numstat', '--format=', h).splitlines():
            p = l.split('\t')
            if len(p) < 3: continue
            a = area(p[2])
            if a in ('headers', 'tests', 'other'): continue
            seen.add(a)
            if p[0].isdigit(): lines[a] += int(p[0]) + int(p[1])
        for a in seen: cnt[a] += 1
    cm[who] = [dict(area=a, n=n, lines=lines[a]) for a, n in cnt.most_common(12)]
out['codemap'] = cm

# ---------------------------------------------------------------- retention
years = collections.defaultdict(set)
for h, d, m in rows:
    for k, r in m.items():
        if credited(r): years[k].add(int(d[:4]))
coh = []
for y in range(2020, 2026):
    new = [k for k, ys in years.items() if min(ys) == y]
    nxt = sum(1 for k in new if y + 1 in years[k])
    later = sum(1 for k in new if any(z > y for z in years[k]))
    coh.append(dict(y=y, n=len(new), next=nxt, later=later))
out['retention'] = dict(cohorts=coh, new26=sum(1 for k, ys in years.items() if min(ys) == 2026))

# ---------------------------------------------------------------- releases
stamps = {}
for l in git('log', PG_REF, '--format=%ad\t%s', '--date=short', '--grep=^Stamp HEAD as').splitlines():
    d, s = l.split('\t'); m = re.search(r'as (\d+)devel', s)
    if m: stamps[int(m.group(1))] = d
cycles = []
for v in range(13, max(stamps) + 1):
    start = stamps.get(v); end = stamps.get(v + 1, '9999-99-99')
    if start: cycles.append((v, start, end))
rel = []
for v, s, e in cycles:
    c = collections.Counter(); ppl = set(); n = 0
    for h, d, m in rows:
        if s <= d < e:
            n += 1
            for k, r in m.items():
                if credited(r): c[k] += 1; ppl.add(k)
    nc = [(k, v2) for k, v2 in c.most_common() if k not in committers]
    rank = lambda k: next((i + 1 for i, (x, _) in enumerate(nc) if x == k), None)
    rel.append(dict(v=v, start=s, end=None if e.startswith('9999') else e, commits=n, people=len(ppl),
                    nik=c[NIK], ab=c[AB], nikRank=rank(NIK), abRank=rank(AB),
                    top=[dict(name=nm(k), n=x) for k, x in nc[:5]]))
out['releases'] = rel

json.dump(out, open(os.path.join(DATA, 'extras.json'), 'w'), ensure_ascii=False)
print(json.dumps({k: (v if k in ('releases', 'retention') else '...') for k, v in out.items()}, ensure_ascii=False)[:2500])
print('ai', len(ai_list), out['ai']['cats'], out['ai']['months'])
print('companies', top)
print('codemap', cm)
print('pairs', out['network']['pairs'][:12])
