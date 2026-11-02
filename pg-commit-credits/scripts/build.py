"""Inject data/brief.json into template.html -> docs/index.html"""
import os
from config import HERE, ROOT, DATA
t = open(os.path.join(HERE, 'template.html')).read()
d = open(os.path.join(DATA, 'brief.json')).read().replace('</', '<\\/')
os.makedirs(os.path.join(ROOT, 'docs'), exist_ok=True)
open(os.path.join(ROOT, 'docs', 'index.html'), 'w').write(t.replace('__DATA__', d))
print('wrote docs/index.html')
