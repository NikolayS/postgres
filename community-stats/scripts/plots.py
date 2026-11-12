import csv, sys, datetime as dt
import matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
S=sys.argv[1]
BLUE='#2a6fdb'; ORANGE='#e07b28'; GREY='#c4c9d2'; INK='#30343b'; MUT='#6b7280'
plt.rcParams.update({'font.size':10,'axes.edgecolor':GREY,'axes.labelcolor':INK,'xtick.color':MUT,'ytick.color':MUT,
  'axes.spines.top':False,'axes.spines.right':False,'axes.grid':True,'grid.color':'#eceef2','axes.axisbelow':True,'axes.titleweight':'bold','axes.titlesize':12,'axes.titlelocation':'left'})
cf=[r for r in csv.DictReader(open(f'{S}/out/commitfests.csv')) if r['kind']=='regular' and r['state']!='open']
names=[r['cf'] for r in cf]; x=range(len(cf))
new=[int(r['new']) for r in cf]; car=[int(r['carried']) for r in cf]; com=[int(r['committed']) for r in cf]; fta=[int(r['first_time_authors']) for r in cf]
alpha=[0.45 if r['state']=='in progress' else 1 for r in cf]
fig,ax=plt.subplots(2,1,figsize=(13,9),dpi=150,gridspec_kw={'height_ratios':[3,2]})
a=ax[0]
for i in x:
    a.bar(i,new[i],color=BLUE,alpha=alpha[i],width=.8)
    a.bar(i,car[i],bottom=new[i],color=GREY,alpha=alpha[i],width=.8)
a.plot(list(x),com,color=ORANGE,lw=2,marker='o',ms=3)
a.set_title('Commitfest entries per commitfest: new patches vs carried over, and committed')
from matplotlib.patches import Patch; from matplotlib.lines import Line2D
a.legend(handles=[Patch(color=BLUE,label='New entries (first appearance)'),Patch(color=GREY,label='Carried over from earlier CF'),Line2D([],[],color=ORANGE,lw=2,label='Committed')],loc='upper left',frameon=False)
for i in [names.index(n) for n in ['2024-07','PG19-1','PG20-1','PG20-2','PG20-3']]:
    a.annotate(f'{new[i]}',(i,new[i]),xytext=(0,-12),textcoords='offset points',ha='center',color='white',fontsize=8,fontweight='bold')
a.annotate('PG20-3 still in progress',(len(cf)-1,new[-1]+car[-1]),xytext=(-150,8),textcoords='offset points',fontsize=8,color=MUT,arrowprops=dict(arrowstyle='-',color=MUT))
b=ax[1]
b.bar(list(x)[1:],fta[1:],color=[BLUE]*(len(cf)-1),width=.8)
for i in range(1,len(cf)):
    b.patches[i-1].set_alpha(alpha[i])
b.set_title('First-time commitfest authors per commitfest')
for i in [names.index(n) for n in ['PG20-1','PG20-2','PG20-3']]:
    b.annotate(str(fta[i]),(i,fta[i]),xytext=(0,3),textcoords='offset points',ha='center',fontsize=8,color=INK)
for axx in ax:
    axx.set_xticks(list(x)[::3]); axx.set_xticklabels(names[::3],rotation=45,ha='right',fontsize=8); axx.set_xlim(-.7,len(cf)-.3)
fig.text(0.01,0.005,'Source: commitfest.postgresql.org, all 61 commitfests, read 12 Nov 2026. Regular CFs only (Drafts and still-open PG20-4 excluded).',fontsize=8,color=MUT)
fig.tight_layout(rect=(0,.02,1,1)); fig.savefig(f'{S}/viz_commitfests.png')

m=list(csv.DictReader(open(f'{S}/out/hackers_monthly.csv')))
d=[dt.datetime.strptime(r['month'],'%Y-%m') for r in m]
mpd=[float(r['messages_per_day']) for r in m]; ppd=[int(r['patch_messages'])/int(r['days_covered']) for r in m]
def roll(v): return [None if i<11 else sum(v[i-11:i+1])/12 for i in range(len(v))]
fig,ax=plt.subplots(3,1,figsize=(13,11),dpi=150)
for a,v,t in [(ax[0],mpd,'pgsql-hackers messages per day'),(ax[1],ppd,'pgsql-hackers emails carrying a patch, per day')]:
    a.plot(d,v,color=GREY,lw=1,label='Monthly'); r=roll(v)
    a.plot([d[i] for i in range(len(r)) if r[i]],[x for x in r if x],color=BLUE,lw=2.4,label='12-month average')
    a.set_title(t); a.legend(loc='upper left',frameon=False); a.set_ylim(0)
ai=[r for r in m if r['month']>='2023-01']
a=ax[2]; xs=range(len(ai)); sh=[float(r['ai_share_pct']) for r in ai]
a.bar(list(xs),sh,color=[BLUE if r['partial']=='0' else '#9dbcf0' for r in ai],width=.8)
a.set_xticks(list(xs)[::3]); a.set_xticklabels([dt.datetime.strptime(r['month'],'%Y-%m').strftime('%b %Y') for r in ai][::3],rotation=45,ha='right',fontsize=8)
a.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v,_:f'{v:.1f}%'))
a.set_title('Share of pgsql-hackers messages that mention AI tools (ChatGPT, Claude, Copilot, LLM, "AI-assisted"…)')
for i,r in enumerate(ai):
    if r['month']>='2026-07': a.annotate(f"{sh[i]:.1f}%",(i,sh[i]),xytext=(0,3),textcoords='offset points',ha='center',fontsize=8)
fig.text(0.01,0.005,'Source: pgsql-hackers mbox archive, 465,117 messages, Jan 2010 – 11 Nov 2026. Quoted lines excluded from AI matching; Nov 2026 partial (lighter).',fontsize=8,color=MUT)
fig.tight_layout(rect=(0,.02,1,1)); fig.savefig(f'{S}/viz_hackers.png')
print('ok')
