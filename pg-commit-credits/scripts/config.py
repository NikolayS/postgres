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
CUT = os.environ.get('YTD_CUT', '-10-29')  # month-day cutoff for same-period YoY comparison
