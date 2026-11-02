import sys,os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); from config import *
import subprocess,re,json,unicodedata,collections
out=subprocess.run(['git','-C',PG_REPO,'log',PG_REF,'--since=2019-01-01',
 '--format=%x00%h%x01%ad%x01%an%x01%ae%x01%B','--date=short'],capture_output=True,text=True).stdout
KEYS={'author':'author','co-authored-by':'author','co-author':'author','authors':'author','patch-by':'author',
 'reviewed-by':'review','reviewer':'review','reviewers':'review','reviewed-by-by':'review',
 'reported-by':'report','bug-reported-by':'report','tested-by':'test','suggested-by':'suggest','analyzed-by':'suggest','diagnosed-by':'suggest','investigated-by':'suggest','discussed-by':'suggest','backpatch-by':None}
TR=re.compile(r'^\s*([A-Za-z][A-Za-z-]*):\s*(.*)$')
def norm(n):
    n=unicodedata.normalize('NFKD',n); n=''.join(c for c in n if not unicodedata.combining(c))
    n=re.sub(r'\([^)]*\)','',n); n=re.sub(r'\b[A-Z]\.\s*',' ',n)
    n=re.sub(r'[^A-Za-z\'\- ]',' ',n); n=re.sub(r'\s+',' ',n).strip().lower()
    return n
def split(v):
    v=re.sub(r'\([^)]*\)','',v)
    parts=re.split(r',|;|\band\b|&|\bwith\b|/(?! )',v)
    res=[]
    for p in parts:
        p=p.strip()
        if not p: continue
        m=re.search(r'<([^>]+@[^>]+)>',p); em=m.group(1).lower() if m else None
        name=re.sub(r'<[^>]*>','',p).strip()
        if not name and re.fullmatch(r'\S+@\S+',p): em=p.lower(); name=''
        elif re.fullmatch(r'\S+@\S+',name): em=name.lower(); name=''
        res.append((name,em))
    return res
commits=[]
for c in out.split('\0')[1:]:
    h,d,an,ae,b=c.split('\x01',4)
    cred=[]; last=None; has_author=False
    for l in b.split('\n'):
        m=TR.match(l)
        if m and m.group(1).lower() in KEYS:
            role=KEYS[m.group(1).lower()]; last=role
            if role: cred+= [(role,)+x for x in split(m.group(2))]
            if role=='author': has_author=True
            continue
        if last and l.startswith((' ','\t')) and l.strip() and role:
            cred+=[(last,)+x for x in split(l)]; continue
        last=None
    if not has_author: cred.append(('author',an,ae.lower()))
    cred.append(('commit',an,ae.lower()))
    commits.append((h,d,cred))
# identity resolution via union-find on names & emails
par={}
def f(x):
    par.setdefault(x,x)
    while par[x]!=x: par[x]=par[par[x]]; x=par[x]
    return x
def u(a,b): par[f(a)]=f(b)
GENERIC={'gmail.com'}
for h,d,cr in commits:
    for r,n,e in cr:
        nn=norm(n) if n else None
        if nn and len(nn.split())<2: nn=None  # avoid merging single tokens
        if nn: f('n:'+nn)
        if e: f('e:'+e)
        if nn and e: u('n:'+nn,'e:'+e)
names=collections.defaultdict(collections.Counter)
rows=[]
for h,d,cr in commits:
    seen={}
    for r,n,e in cr:
        nn=norm(n) if n else None
        if nn and len(nn.split())<2 and not e: key='n1:'+nn
        elif nn and len(nn.split())>=2: key=f('n:'+nn)
        elif e: key=f('e:'+e)
        else: continue
        if n: names[key][n.strip()]+=1
        seen.setdefault(key,set()).add(r)
    rows.append((h,d,{k:sorted(v) for k,v in seen.items()}))
disp={k:c.most_common(1)[0][0] for k,c in names.items()}
json.dump(dict(rows=rows,disp=disp),open(os.path.join(DATA,'all.json'),'w'))
print(len(rows))
