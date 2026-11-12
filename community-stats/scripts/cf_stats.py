import json, csv, sys, re, os
S=sys.argv[1]
cfs={c['id']:c for c in json.load(open(f'{S}/cf.json'))}
rows=list(csv.DictReader(open(f'{S}/cf_patches.tsv'),delimiter='\t'))
order=sorted(cfs, key=lambda i:(cfs[i]['start'], i))
seen_p=set(); seen_a=set(); out=[]
by={}
for r in rows: by.setdefault(int(r['cf_id']),[]).append(r)
def authors(s):
    return set(re.findall(r'\(([^)]+)\)', s)) or ({s} if s else set())
for i in order:
    c=cfs[i]; rs=by.get(i,[])
    pids={int(r['patch_id']) for r in rs}
    new=pids-seen_p
    au=set().union(*[authors(r['authors']) for r in rs]) if rs else set()
    newau=set().union(*[authors(r['authors']) for r in rs if int(r['patch_id']) in new]) if rs else set()
    first_time=au-seen_a
    st=c['summary']
    committed=st.get('Committed',0)
    moved=st.get('Moved to next CF',0)+st.get('Moved to different CF',0)
    out.append(dict(id=i,name=c['name'],start=c['start'],end=c['end'],draft='Draft' in c['name'],
        total=c['total'],new=len(new),carried=len(pids&seen_p),committed=committed,moved=moved,
        withdrawn=st.get('Withdrawn',0),rejected=st.get('Rejected',0),rwf=st.get('Returned with Feedback',0),
        open_now=st.get('Needs review',0)+st.get('Waiting on Author',0)+st.get('Ready for Committer',0),
        authors=len(au),first_time_authors=len(first_time),max_patch_id=max(pids) if pids else 0))
    seen_p|=pids; seen_a|=au
json.dump(out,open(f'{S}/cf_stats.json','w'),indent=1)
print(f"{'cf':12} {'start':10} {'total':>5} {'new':>4} {'carr':>4} {'cmt':>4} {'auth':>4} {'1st':>4}")
for o in out: print(f"{o['name']:12} {o['start']} {o['total']:5} {o['new']:4} {o['carried']:4} {o['committed']:4} {o['authors']:4} {o['first_time_authors']:4}")
