#!/bin/bash
# wal_archive_ceiling.sh — report US-2 slot-creation anchor and MTTI ceiling
# for an existing PostgreSQL WAL archive directory.
#
# For an operator with a dead primary + archived WAL, this answers:
#   1) What is the earliest LSN where snapbuild will hit path (a) and create
#      a logical slot? (first path-(a)-eligible RUNNING_XACTS record)
#   2) What is the latest LSN a logical slot can safely replay to before
#      being invalidated? (first Heap2/PRUNE_ON_ACCESS on a catalog rel)
#
# The difference between (1) and (2), in LSN bytes, is the archive's
# practical US-2 window. Beyond (2), only the paused-recovery GUC proposal
# (see blueprint §7.1 / US-4) can rescue decode.
#
# Usage: wal_archive_ceiling.sh <archive_dir> [pg_waldump_path]

set -e

ARCHIVE_DIR=${1:?usage: $0 <archive_dir> [pg_waldump_path]}
PG_WALDUMP=${2:-/usr/lib/postgresql/18/bin/pg_waldump}

if [ ! -d "$ARCHIVE_DIR" ]; then
    echo "error: $ARCHIVE_DIR is not a directory" >&2
    exit 1
fi
if [ ! -x "$PG_WALDUMP" ]; then
    echo "error: pg_waldump not found at $PG_WALDUMP" >&2
    exit 1
fi

ANCHOR_LSN=""
ANCHOR_SEG=""
ANCHOR_DETAIL=""
CEILING_LSN=""
CEILING_SEG=""
CEILING_DETAIL=""

lsn_to_bytes() {
    local lsn=$1 hi lo
    hi=${lsn%/*}; lo=${lsn#*/}
    echo $(( 16#$hi * (1 << 32) + 16#$lo ))
}

# Segments in LSN order; skip .partial and .backup files.
SEGS=$(find "$ARCHIVE_DIR" -maxdepth 1 -type f \
           \! -name '*.partial' \! -name '*.backup' \
           -printf '%f\n' | sort)

# Pass 1: find first path-(a)-eligible anchor across the archive.
for seg in $SEGS; do
    hit=$("$PG_WALDUMP" -p "$ARCHIVE_DIR" "$seg" 2>/dev/null \
          | awk '
              /RUNNING_XACTS/ {
                  nx=""; ox=""
                  for (i=1;i<=NF;i++) {
                      if ($i == "nextXid")           nx = $(i+1)
                      if ($i == "oldestRunningXid")  ox = $(i+1)
                  }
                  if (nx != "" && nx == ox) { print; exit }
              }' || true)
    if [ -n "$hit" ]; then
        ANCHOR_LSN=$(echo "$hit"  | sed -n 's/.*lsn: \([0-9A-F\/]*\).*/\1/p')
        ANCHOR_SEG=$seg
        ANCHOR_DETAIL=$hit
        break
    fi
done

# Pass 2: first catalog prune at or AFTER the anchor LSN (that's the operative
# ceiling — earlier prunes pre-date the slot and never touch it).
if [ -n "$ANCHOR_LSN" ]; then
    ANCHOR_BYTES=$(lsn_to_bytes "$ANCHOR_LSN")
    for seg in $SEGS; do
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            lsn=$(echo "$line" | sed -n 's/.*lsn: \([0-9A-F\/]*\).*/\1/p')
            [ -z "$lsn" ] && continue
            lsn_bytes=$(lsn_to_bytes "$lsn")
            if [ "$lsn_bytes" -ge "$ANCHOR_BYTES" ]; then
                CEILING_LSN=$lsn
                CEILING_SEG=$seg
                CEILING_DETAIL=$line
                break
            fi
        done < <("$PG_WALDUMP" -p "$ARCHIVE_DIR" -r Heap2 "$seg" 2>/dev/null \
                 | grep 'PRUNE_ON_ACCESS.*isCatalogRel: T' || true)
        [ -n "$CEILING_LSN" ] && break
    done
else
    # No anchor — still report the first catalog prune for completeness.
    for seg in $SEGS; do
        hit=$("$PG_WALDUMP" -p "$ARCHIVE_DIR" -r Heap2 "$seg" 2>/dev/null \
              | grep -m1 'PRUNE_ON_ACCESS.*isCatalogRel: T' || true)
        if [ -n "$hit" ]; then
            CEILING_LSN=$(echo "$hit" | sed -n 's/.*lsn: \([0-9A-F\/]*\).*/\1/p')
            CEILING_SEG=$seg
            CEILING_DETAIL=$hit
            break
        fi
    done
fi

printf 'archive        : %s\n' "$ARCHIVE_DIR"
printf 'segments scanned: %d\n' "$(echo "$SEGS" | wc -l)"
echo

if [ -n "$ANCHOR_LSN" ]; then
    printf 'path-(a) anchor : %s   (segment %s)\n' "$ANCHOR_LSN" "$ANCHOR_SEG"
    printf '  record        : %s\n' "$ANCHOR_DETAIL"
else
    printf 'path-(a) anchor : NONE FOUND\n'
    echo '  — No quiet-moment RUNNING_XACTS record in this archive.'
    echo '  — Slot creation will block until one appears. On a dead primary,'
    echo '    this archive cannot source a logical slot without a patch.'
fi
echo

if [ -n "$CEILING_LSN" ]; then
    printf 'MTTI ceiling    : %s   (segment %s)\n' "$CEILING_LSN" "$CEILING_SEG"
    printf '  record        : %s\n' "$CEILING_DETAIL"
else
    printf 'MTTI ceiling    : none in scanned archive (no catalog prune yet)\n'
    echo '  — Full archive can be replayed without triggering slot invalidation.'
fi
echo

if [ -n "$ANCHOR_LSN" ] && [ -n "$CEILING_LSN" ]; then
    delta=$(( $(lsn_to_bytes "$CEILING_LSN") - $(lsn_to_bytes "$ANCHOR_LSN") ))
    mb=$(awk "BEGIN {printf \"%.1f\", $delta / 1048576}")
    gb=$(awk "BEGIN {printf \"%.2f\", $delta / 1073741824}")
    printf 'usable US-2 window (LSN distance): %s bytes ≈ %s MiB ≈ %s GiB\n' \
           "$delta" "$mb" "$gb"
fi
