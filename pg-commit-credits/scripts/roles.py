import sys,os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); from config import *
import subprocess, re, sys, collections, json
name = sys.argv[1]
out = subprocess.run(['git','-C',PG_REPO,'log',PG_REF,'--since=2001-11-02','-i','-E',f'--grep={name}',
  '--format=%x00%h%x01%ad%x01%cn%x01%B','--date=short'],capture_output=True,text=True).stdout
ROLE = [('author',r'author|patch by|^by\b|written by|from\b'),('review',r'review'),('report',r'report|bug|complain'),
        ('test',r'test'),('suggest',r'suggest|idea|discuss|analysis|diagnos|investigat|help|insight|input|feedback|thank')]
def classify(text):
    t=text.lower()
    best=None;pos=-1
    for r,pat in ROLE:
        for m in re.finditer(pat,t):
            if m.start()>pos: pos=m.start();best=r
    return best
rows=[]
for c in out.split('\0')[1:]:
    h,d,cn,body=c.split('\x01',3)
    lines=body.split('\n'); roles=set()
    for i,l in enumerate(lines):
        if not re.search(name,l,re.I): continue
        m=re.match(r'\s*([A-Za-z-]+):',l)
        if m and not re.search(name,m.group(1),re.I):
            roles.add(classify(m.group(1)) or 'other'); continue
        # prose: text from paragraph start up to the name
        j=i
        while j>0 and lines[j-1].strip(): j-=1
        para='\n'.join(lines[j:i])+'\n'+l[:re.search(name,l,re.I).start()]
        # restrict to current sentence-ish
        seg=re.split(r'[.;]\s',para)[-1]
        r=classify(seg)
        roles.add(r or 'author')
    rows.append(dict(h=h,y=int(d[:4]),cn=cn,roles=sorted(roles)))
json.dump(rows,sys.stdout)
