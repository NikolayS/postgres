import sys,os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); from config import *
import json,collections,sys
D=json.load(open(os.path.join(DATA,'all.json')));disp=D['disp']

def cnt(y0,y1,ytd=False,roles=None):
    c=collections.Counter()
    for h,d,m in D['rows']:
        y=int(d[:4])
        if not(y0<=y<=y1): continue
        if ytd and d[4:]>CUT: continue
        for k,r in m.items():
            rr=[x for x in r if x!='commit']
            if roles: rr=[x for x in rr if x in roles]
            if rr: c[k]+=1
    return c
def nm(k): return disp.get(k,k)
c26=cnt(2026,2026,True); c25=cnt(2025,2025,True); c5=cnt(2022,2026)
commit26=collections.Counter(k for h,d,m in D['rows'] if d[:4]=='2026' for k,r in m.items() if 'commit' in r)
print('distinct credited people 2026:',len(c26),' 2025ytd:',len(c25))
print('\nTOP 40 in 2022-2026 (credited commits, any non-commit role)')
for i,(k,v) in enumerate(c5.most_common(40),1): print(i,nm(k),v,'| 25ytd',c25[k],'26ytd',c26[k])
print('\nTOP 30 2026 YTD')
for i,(k,v) in enumerate(c26.most_common(30),1): print(i,nm(k),v,'(25ytd',c25[k],')','committer' if commit26[k] else '')
print('\nGROWTH abs (26ytd-25ytd)')
g=sorted(c26,key=lambda k:c26[k]-c25[k],reverse=True)
for k in g[:30]: print(nm(k),c25[k],'->',c26[k],f'+{c26[k]-c25[k]}','committer' if commit26[k] else '')
committers=set(k for h,d,m in D['rows'] if d[:4]>='2022' for k,r in m.items() if 'commit' in r)
print('\nn committers',len(committers))
def rankof(c,k,excl=False):
    l=[x for x,_ in c.most_common() if not(excl and x in committers)]
    return (l.index(k)+1 if k in l else None, len(l))
full25=cnt(2025,2025)
for who in ['samokhvalov','borodin','wolak']:
    ks=[k for k in disp if who in disp[k].lower() or who in k]
    for k in ks:
        print(who,k,nm(k),'5y',c5[k],rankof(c5,k),rankof(c5,k,True),'| 26ytd',c26[k],rankof(c26,k),rankof(c26,k,True),'| 25ytd',c25[k],rankof(c25,k),'| full2025',full25[k])
        for y in range(2019,2027): print('   ',y,cnt(y,y)[k], dict(collections.Counter(x for h,d,m in D['rows'] if d[:4]==str(y) for x in m.get(k,[]))))
print('\nTOP 25 non-committers 2026 YTD')
l=[(k,v) for k,v in c26.most_common() if k not in committers]
for i,(k,v) in enumerate(l[:25],1): print(i,nm(k),v,'(25ytd',c25[k],')', dict(collections.Counter(x for h,d,m in D['rows'] if d[:4]=='2026' for x in m.get(k,[]))))
print('\nTOP 25 non-committers 2022-2026')
l=[(k,v) for k,v in c5.most_common() if k not in committers]
for i,(k,v) in enumerate(l[:25],1): print(i,nm(k),v)
# growth among people with >=10 in 2026, ratio
print('\nratio growth, >=20 in 2026ytd')
for k in sorted([k for k in c26 if c26[k]>=20],key=lambda k:c26[k]/max(c25[k],3),reverse=True)[:15]: print(nm(k),c25[k],c26[k], 'C' if k in committers else '')
