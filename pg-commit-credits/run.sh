#!/usr/bin/env bash
# Rebuild all data and the HTML brief from a PostgreSQL clone.
#   PG_REPO=/path/to/postgres ./run.sh
# The clone needs master history back to 2001 (a full clone, or
#   git fetch --shallow-since=2001-10-01 origin master).
set -euo pipefail
cd "$(dirname "$0")"
S=scripts; D=data
# 1. Per-person timelines (grep of commit messages, prose credits included)
python3 $S/roles.py 'Samokhvalov'               > $D/Samokhvalov.json
python3 $S/roles.py 'Kukushkin'                 > $D/Kukushkin.json
python3 $S/roles.py 'Andre[wy] (M\. )?Borodin'  > $D/Borodin.json
python3 $S/roles.py 'Wolak|wolakk@'             > $D/Wolak.json
# 2. All contributors since 2019, parsed from credit trailers
python3 $S/all.py
# 3. Rankings printout (stdout) and brief data
python3 $S/rank.py > $D/rankings.txt
python3 $S/q.py   >> $D/rankings.txt
python3 $S/gen.py > /dev/null
python3 $S/extras.py > /dev/null
python3 $S/fun.py > /dev/null
# 4. HTML brief
python3 $S/export_csv.py
python3 $S/build.py
