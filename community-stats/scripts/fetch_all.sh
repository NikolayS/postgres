#!/bin/bash
S=${S:-$(cd "$(dirname "$0")/.." && pwd)/work}
one() {
  m=$1; out=$S/mbox/$m.tsv
  [ -s $out.done ] && return
  for try in 1 2 3 4; do
    if curl -sSf --retry 3 -u archives:antispam https://www.postgresql.org/list/pgsql-hackers/mbox/pgsql-hackers.$m | python3 -I $S/scripts/parse_mbox.py > $out.tmp; then
      mv $out.tmp $out; wc -l < $out > $out.done; echo "$m $(cat $out.done)"; return
    fi
    sleep $((try*5))
  done
  echo "$m FAILED"
}
export -f one; export S
for y in $(seq 2010 2026); do for mo in 01 02 03 04 05 06 07 08 09 10 11 12; do
  [ "$y$mo" -gt 202611 ] && continue; echo $y$mo; done; done | xargs -P 6 -I{} bash -c 'one {}'
echo ALLDONE
