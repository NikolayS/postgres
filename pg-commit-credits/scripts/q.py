import os
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'rank.py')).read().split("print('distinct")[0])
nik='e:samokhvalov@gmail.com'; ab='e:amborodin86@gmail.com'
el=[k for k in c26 if c26[k]>=15]
r=sorted(el,key=lambda k:c26[k]/max(c25[k],3),reverse=True)
print('people>=15 in 26ytd',len(el),'nik ratio rank',r.index(nik)+1,'ab',r.index(ab)+1)
for k in r[:25]: print(' ',nm(k),c25[k],c26[k])
# reporter-only ranking 2026
rep=cnt(2026,2026,True,roles={'report'})
for i,(k,v) in enumerate(rep.most_common(12),1): print('rep',i,nm(k),v)
print('nik rep rank',[k for k,_ in rep.most_common()].index(nik)+1, len(rep))
rv=cnt(2026,2026,True,roles={'review'})
print('ab review rank',[k for k,_ in rv.most_common()].index(ab)+1,len(rv), rv[ab])
for i,(k,v) in enumerate(rv.most_common(20),1): print('rev',i,nm(k),v)
