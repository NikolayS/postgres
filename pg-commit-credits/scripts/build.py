"""Inject data/brief.json into template.html -> docs/index.html"""
import os
from config import HERE, ROOT, DATA, ASOF
import datetime
t = open(os.path.join(HERE, 'template.html')).read()
import json
b = json.load(open(os.path.join(DATA, 'brief.json')))
b['X'] = json.load(open(os.path.join(DATA, 'extras.json')))
d = json.dumps(b, ensure_ascii=False).replace('</', '<\\/')
os.makedirs(os.path.join(ROOT, 'docs'), exist_ok=True)
a = datetime.date.fromisoformat(ASOF)
t = t.replace('__ASOF_LONG__', f'{a:%B} {a.day}').replace('__ASOF_SHORT__', f'{a:%b} {a.day}').replace('__ASOF__', ASOF)
open(os.path.join(ROOT, 'docs', 'index.html'), 'w').write(t.replace('__DATA__', d))
print('wrote docs/index.html')
