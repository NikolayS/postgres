import os; exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'rank.py')).read().split("print('distinct")[0])
import subprocess
out={}
P={'nik':'Samokhvalov','kuk':'Kukushkin','ab':'Borodin','kw':'Wolak'}
G={}
for k,f in P.items():
    r=json.load(open(os.path.join(DATA,f+'.json')));G[k]=r
    out.setdefault('years',{})[k]=dict(collections.Counter(z['y'] for z in r))
    out.setdefault('roles',{})[k]=dict(collections.Counter(x for z in r for x in z['roles']))
    out.setdefault('ncommitters',{})[k]=len(set(z['cn'] for z in r))
# nik & kirk commit lists
def lst(k):
    res=[]
    for z in G[k]:
        s=subprocess.run(['git','-C',PG_REPO,'log','-1','--format=%ad%x01%s','--date=short',z['h']],capture_output=True,text=True).stdout.strip().split('\x01')
        res.append(dict(h=z['h'][:9],d=s[0],cn=z['cn'],roles=z['roles'],s=s[1][:110]))
    return res
out['nikList']=lst('nik'); out['kwList']=lst('kw')
committers=set(k for h,d,m in D['rows'] if d[:4]>='2022' for k,r in m.items() if 'commit' in r)
ids={'nik':'e:samokhvalov@gmail.com','ab':'e:amborodin86@gmail.com','kuk':'e:cyberdemn@gmail.com','kw':'n:kirk wolak'}
def roleset(k,y,ytd=True):
    return dict(collections.Counter(x for h,d,m in D['rows'] if d[:4]==str(y) and (not ytd or d[4:]<=CUT) for x in m.get(k,[]) if x!='commit'))
def top(c,n,excl=False,extra=()):
    l=[(k,v) for k,v in c.most_common() if not(excl and k in committers)]
    res=[dict(rank=i+1,name=nm(k),v=v,c=k in committers,id=k) for i,(k,v) in enumerate(l) if i<n or k in extra]
    return res
ex=[ids['nik'],ids['ab']]
out['top26']=[dict(x,prev=c25[x['id']]) for x in top(c26,20,False,ex)]
out['topNC26']=[dict(x,prev=c25[x['id']]) for x in top(c26,20,True,ex)]
out['topNC5y']=top(c5,20,True,ex)
rep=cnt(2026,2026,True,roles={'report'}); rv=cnt(2026,2026,True,roles={'review'})
out['rep26']=top(rep,20,False,ex); out['rev26']=top(rv,20,False,ex)
g=sorted(c26,key=lambda k:c26[k]-c25[k],reverse=True)
out['growth']=[dict(name=nm(k),a=c25[k],b=c26[k],c=k in committers) for k in g[:15]]
el=[k for k in c26 if c26[k]>=15]; rr=sorted(el,key=lambda k:c26[k]/max(c25[k],3),reverse=True)
out['ratioRank']={'nik':rr.index(ids['nik'])+1,'ab':rr.index(ids['ab'])+1,'n':len(el)}
def rk(c,k,excl): 
    l=[x for x,_ in c.most_common() if not(excl and x in committers)]; return [l.index(k)+1 if k in l else None,len(l)]
out['ranks']={p:dict(y26=rk(c26,ids[p],False),y26nc=rk(c26,ids[p],True),y5=rk(c5,ids[p],False),y5nc=rk(c5,ids[p],True),v26=c26[ids[p]],v25=c25[ids[p]],v5=c5[ids[p]],rep=rk(rep,ids[p],False),rev=rk(rv,ids[p],False),roles26=roleset(ids[p],2026)) for p in ids}
out['people']={y:len(cnt(y,y,True)) for y in (2025,2026)}
out['peopleYear']={y:len(cnt(y,y)) for y in range(2019,2027)}
out['commitsYear']={y:sum(1 for h,d,m in D['rows'] if d[:4]==str(y)) for y in range(2019,2027)}
out['nCommitters']=len(committers)
out['commitsYTD']={y:sum(1 for h,d,m in D['rows'] if d[:4]==str(y) and d[4:]<=CUT) for y in (2025,2026)}
out['rolesYTD']={y:dict(collections.Counter(x for h,d,m in D['rows'] if d[:4]==str(y) and d[4:]<=CUT for r in m.values() for x in r if x!='commit')) for y in (2025,2026)}
out['newcomers26']=sum(1 for k in c26 if not any(k in m for h,d,m in D['rows'] if d[:4]<'2026'))
json.dump(out,open(os.path.join(DATA,'brief.json'),'w'),ensure_ascii=False)
print(json.dumps({k:out[k] for k in ['years','roles','ranks','ratioRank','people','peopleYear']},ensure_ascii=False)[:3000])
print(len(out['nikList']),len(out['kwList']), [x['name'] for x in out['topNC26']][-3:])
