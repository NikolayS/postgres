#!/bin/bash
# Round 7: Three-way comparison benchmarks
# Runs pgbench across all configurations, collects results + flamegraphs
set -euo pipefail

RESULTS_DIR="/opt/results"
mkdir -p "$RESULTS_DIR"

SCALE=100
DURATION=60
RUNS=3

# Configs: name, pg_install_dir, extra_conf, pre_bench_cmd, post_bench_cmd
declare -A CONFIGS
# We define configs as ordered arrays for sequencing
CONFIG_NAMES=(
  "pg-stock"
  "pg-usdt-idle"
  "pg-usdt-bpftrace"
  "pg-wet-off"
  "pg-wet-timing"
  "pg-wet-all"
)

declare -A CONFIG_INSTALL
CONFIG_INSTALL[pg-stock]="/opt/pg-stock-install"
CONFIG_INSTALL[pg-usdt-idle]="/opt/pg-usdt-install"
CONFIG_INSTALL[pg-usdt-bpftrace]="/opt/pg-usdt-install"
CONFIG_INSTALL[pg-wet-off]="/opt/pg-wet-install"
CONFIG_INSTALL[pg-wet-timing]="/opt/pg-wet-install"
CONFIG_INSTALL[pg-wet-all]="/opt/pg-wet-install"

declare -A CONFIG_EXTRA_CONF
CONFIG_EXTRA_CONF[pg-stock]=""
CONFIG_EXTRA_CONF[pg-usdt-idle]=""
CONFIG_EXTRA_CONF[pg-usdt-bpftrace]=""
CONFIG_EXTRA_CONF[pg-wet-off]=""
CONFIG_EXTRA_CONF[pg-wet-timing]="wait_event_timing = on"
CONFIG_EXTRA_CONF[pg-wet-all]="wait_event_timing = on
wait_event_trace = on"

# Workloads: name, pgbench_args
WORKLOAD_NAMES=(
  "tpcb-c8"
  "tpcb-c64"
  "select1-c1"
  "select1-c8"
)

declare -A WORKLOAD_ARGS
WORKLOAD_ARGS[tpcb-c8]="-c 8 -j 8 -T $DURATION"
WORKLOAD_ARGS[tpcb-c64]="-c 64 -j 8 -T $DURATION"
WORKLOAD_ARGS[select1-c1]="-c 1 -j 1 -T $DURATION -f /opt/select1.sql"
WORKLOAD_ARGS[select1-c8]="-c 8 -j 8 -T $DURATION -f /opt/select1.sql"

# Create SELECT 1 script
echo "SELECT 1;" > /opt/select1.sql

init_db() {
  local install_dir=$1
  local datadir="/opt/pgdata"
  local name=$2

  # Stop any running postgres
  pkill -9 postgres 2>/dev/null || true
  sleep 2

  rm -rf "$datadir"
  "$install_dir/bin/initdb" -D "$datadir" 2>&1 | tail -1

  # Configure
  cat >> "$datadir/postgresql.conf" <<EOF
shared_buffers = '2GB'
max_connections = 200
work_mem = '64MB'
maintenance_work_mem = '512MB'
effective_cache_size = '8GB'
checkpoint_timeout = '30min'
max_wal_size = '8GB'
wal_level = 'minimal'
max_wal_senders = 0
fsync = off
synchronous_commit = off
full_page_writes = off
log_min_duration_statement = -1
logging_collector = off
listen_addresses = 'localhost'
port = 5432
EOF

  # Add extra config if any
  if [ -n "${CONFIG_EXTRA_CONF[$name]:-}" ]; then
    echo "${CONFIG_EXTRA_CONF[$name]}" >> "$datadir/postgresql.conf"
  fi

  "$install_dir/bin/pg_ctl" -D "$datadir" -l "$datadir/logfile" start
  sleep 2

  # Create bench db and init pgbench
  "$install_dir/bin/createdb" -p 5432 benchdb 2>/dev/null || true
  "$install_dir/bin/pgbench" -i -s "$SCALE" -p 5432 benchdb 2>&1 | tail -3

  # Checkpoint and let settle
  "$install_dir/bin/psql" -p 5432 benchdb -c "CHECKPOINT;" 2>/dev/null
  sleep 3
}

stop_db() {
  local install_dir=$1
  "$install_dir/bin/pg_ctl" -D /opt/pgdata stop -m fast 2>/dev/null || true
  sleep 2
}

run_single_benchmark() {
  local config_name=$1
  local workload_name=$2
  local run_num=$3
  local install_dir="${CONFIG_INSTALL[$config_name]}"
  local pgbench_args="${WORKLOAD_ARGS[$workload_name]}"

  local outfile="$RESULTS_DIR/${config_name}_${workload_name}_run${run_num}.txt"

  echo "  Run $run_num: $install_dir/bin/pgbench $pgbench_args benchdb"

  # For bpftrace config, start bpftrace in background
  local bpf_pid=""
  if [ "$config_name" = "pg-usdt-bpftrace" ]; then
    local pg_pid=$(head -1 /opt/pgdata/postmaster.pid)
    bpftrace -p "$pg_pid" -e '
      usdt:*:postgresql:wait__event__start { @starts = count(); }
      usdt:*:postgresql:wait__event__end { @ends = count(); }
    ' > "$RESULTS_DIR/${config_name}_${workload_name}_run${run_num}_bpf.txt" 2>&1 &
    bpf_pid=$!
    sleep 2  # let bpftrace attach
  fi

  "$install_dir/bin/pgbench" $pgbench_args -p 5432 benchdb > "$outfile" 2>&1

  # Stop bpftrace if running
  if [ -n "$bpf_pid" ]; then
    kill "$bpf_pid" 2>/dev/null || true
    wait "$bpf_pid" 2>/dev/null || true
  fi

  # Extract TPS
  local tps=$(grep "tps = " "$outfile" | grep -v "including" | awk '{print $3}')
  local lat=$(grep "latency average" "$outfile" | awk '{print $4}')
  echo "    TPS: $tps, Latency: ${lat}ms"
}

collect_flamegraph() {
  local config_name=$1
  local workload_name=$2
  local install_dir="${CONFIG_INSTALL[$config_name]}"
  local pgbench_args="${WORKLOAD_ARGS[$workload_name]}"

  echo "  Collecting flamegraph for $config_name / $workload_name"

  # For bpftrace config, start bpftrace
  local bpf_pid=""
  if [ "$config_name" = "pg-usdt-bpftrace" ]; then
    local pg_pid=$(head -1 /opt/pgdata/postmaster.pid)
    bpftrace -p "$pg_pid" -e '
      usdt:*:postgresql:wait__event__start { @starts = count(); }
      usdt:*:postgresql:wait__event__end { @ends = count(); }
    ' > /dev/null 2>&1 &
    bpf_pid=$!
    sleep 2
  fi

  # Start perf record
  perf record -F 99 -ag --call-graph dwarf -o "$RESULTS_DIR/perf-${config_name}-${workload_name}.data" -- \
    "$install_dir/bin/pgbench" $pgbench_args -p 5432 benchdb > /dev/null 2>&1

  # Stop bpftrace
  if [ -n "$bpf_pid" ]; then
    kill "$bpf_pid" 2>/dev/null || true
    wait "$bpf_pid" 2>/dev/null || true
  fi

  # Generate flamegraph
  perf script -i "$RESULTS_DIR/perf-${config_name}-${workload_name}.data" 2>/dev/null | \
    /opt/FlameGraph/stackcollapse-perf.pl | \
    /opt/FlameGraph/flamegraph.pl --title "$config_name ($workload_name)" \
    > "$RESULTS_DIR/flamegraph-${config_name}-${workload_name}.svg" 2>/dev/null

  # Also generate a PNG for embedding
  # (SVG is the primary artifact)

  rm -f "$RESULTS_DIR/perf-${config_name}-${workload_name}.data"
  echo "    -> flamegraph-${config_name}-${workload_name}.svg"
}

echo "============================================="
echo "Round 7: Three-Way Comparison Benchmarks"
echo "Stock vs USDT vs wait-event-timing"
echo "============================================="
echo "VM: $(nproc) vCPUs, $(free -h | awk '/Mem:/{print $2}') RAM"
echo "Kernel: $(uname -r)"
echo "Scale: $SCALE, Duration: ${DURATION}s, Runs: $RUNS"
echo ""

# Flamegraph workload (pick the most interesting: select1-c8)
FLAMEGRAPH_WORKLOAD="select1-c8"

for config_name in "${CONFIG_NAMES[@]}"; do
  install_dir="${CONFIG_INSTALL[$config_name]}"

  echo ""
  echo "===== Config: $config_name ====="
  echo "Install: $install_dir"

  init_db "$install_dir" "$config_name"

  for workload_name in "${WORKLOAD_NAMES[@]}"; do
    echo ""
    echo "--- Workload: $workload_name ---"
    for run in $(seq 1 $RUNS); do
      run_single_benchmark "$config_name" "$workload_name" "$run"
    done
  done

  # Collect flamegraph for key workload
  echo ""
  echo "--- Flamegraph: $FLAMEGRAPH_WORKLOAD ---"
  collect_flamegraph "$config_name" "$FLAMEGRAPH_WORKLOAD"

  stop_db "$install_dir"
done

echo ""
echo "============================================="
echo "All benchmarks complete!"
echo "Results in: $RESULTS_DIR/"
echo "============================================="
ls -la "$RESULTS_DIR/"
