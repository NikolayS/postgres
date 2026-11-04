#!/bin/bash
# Usage: repro.sh <bindir> <port> <log_destination> <logging_collector on|off>
# Fresh cluster, run outer_wait_log(6) in one session, sample it from another
# 2.5 s later (after ereport returned, still inside the region).
set -eu
BIN=$1; PORT=$2; DEST=$3; COLL=$4
D=$(mktemp -d)/data
"$BIN/initdb" -D "$D" -U postgres >/dev/null
cat >> "$D/postgresql.conf" <<CONF
port = $PORT
log_destination = '$DEST'
logging_collector = $COLL
log_min_messages = log
unix_socket_directories = '/tmp'
CONF
"$BIN/pg_ctl" -D "$D" -l "$D/../server.log" -w start >/dev/null
P="$BIN/psql -X -h /tmp -p $PORT -U postgres -d postgres"
$P -c 'create extension outer_wait' >/dev/null
PGAPPNAME=caller $P -c 'select outer_wait_log(6)' >/dev/null &
sleep 2.5
$P -At -c "select state, wait_event_type, wait_event from pg_stat_activity where application_name = 'caller'"
wait
"$BIN/pg_ctl" -D "$D" -m fast -w stop >/dev/null
