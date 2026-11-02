"""Shared settings. Override with env vars:
  PG_REPO  path to a PostgreSQL git clone (default: the postgres checkout this directory lives in)
  PG_REF   ref to analyze (default: origin/master)
"""
import os
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DATA = os.path.join(ROOT, 'data')
PG_REPO = os.environ.get('PG_REPO', os.path.dirname(ROOT))
PG_REF = os.environ.get('PG_REF', 'origin/master')
import subprocess
# Data cutoff: date of the newest commit on PG_REF (override with ASOF=YYYY-MM-DD).
ASOF = os.environ.get('ASOF') or subprocess.run(['git', '-C', PG_REPO, 'log', '-1', '--format=%ad', '--date=short', PG_REF],
                                                 capture_output=True, text=True).stdout.strip()
CUT = os.environ.get('YTD_CUT', ASOF[4:])  # month-day cutoff for same-period YoY comparison, e.g. '-10-29'
