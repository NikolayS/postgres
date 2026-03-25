#!/bin/bash
# Round 7: Parse benchmark results and produce summary tables
set -euo pipefail

RESULTS_DIR="/opt/results"

echo "## Round 7: Three-Way Comparison — Stock vs USDT vs wait-event-timing"
echo ""
echo "**VM:** Hetzner cx43 (8 vCPU, 16GB RAM, Ubuntu 24.04, Helsinki)"
echo "**PostgreSQL:** 19devel (current master)"
echo "**pgbench:** scale 100, shared_buffers=2GB, 3 runs per config (median reported)"
echo "**Builds:** \`--enable-debug CFLAGS=\"-g -O2\"\` (debug symbols, production optimization)"
echo ""
echo "### Configurations tested"
echo ""
echo "| # | Config | Branch | Build flags | Runtime |"
echo "|---|--------|--------|-------------|---------|"
echo "| 1 | pg-stock | master | no dtrace | baseline |"
echo "| 2 | pg-usdt-idle | usdt-wait-event-poc | \`--enable-dtrace\` | no tracer |"
echo "| 3 | pg-usdt-bpftrace | usdt-wait-event-poc | \`--enable-dtrace\` | bpftrace attached |"
echo "| 4 | pg-wet-off | wait-event-timing | \`--enable-wait-event-timing\` | GUCs OFF |"
echo "| 5 | pg-wet-timing | wait-event-timing | \`--enable-wait-event-timing\` | \`wait_event_timing=on\` |"
echo "| 6 | pg-wet-all | wait-event-timing | \`--enable-wait-event-timing\` | timing + trace ON |"
echo ""

CONFIG_NAMES=(
  "pg-stock"
  "pg-usdt-idle"
  "pg-usdt-bpftrace"
  "pg-wet-off"
  "pg-wet-timing"
  "pg-wet-all"
)

WORKLOAD_NAMES=(
  "tpcb-c8"
  "tpcb-c64"
  "select1-c1"
  "select1-c8"
)

WORKLOAD_LABELS=(
  "TPC-B, c8/j8"
  "TPC-B, c64/j8"
  "SELECT 1, c1/j1"
  "SELECT 1, c8/j8"
)

get_tps() {
  local file="$1"
  if [ -f "$file" ]; then
    grep "tps = " "$file" | grep -v "including" | awk '{printf "%.0f", $3}'
  else
    echo "N/A"
  fi
}

get_latency() {
  local file="$1"
  if [ -f "$file" ]; then
    grep "latency average" "$file" | awk '{printf "%.3f", $4}'
  else
    echo "N/A"
  fi
}

median_of_three() {
  echo "$1 $2 $3" | tr ' ' '\n' | sort -n | sed -n '2p'
}

for w_idx in "${!WORKLOAD_NAMES[@]}"; do
  wname="${WORKLOAD_NAMES[$w_idx]}"
  wlabel="${WORKLOAD_LABELS[$w_idx]}"

  echo "### $wlabel"
  echo ""
  echo "| Configuration | Run 1 | Run 2 | Run 3 | Median TPS | Avg Lat (ms) | vs Stock |"
  echo "|---|---|---|---|---|---|---|"

  stock_median=""
  for config_name in "${CONFIG_NAMES[@]}"; do
    tps1=$(get_tps "$RESULTS_DIR/${config_name}_${wname}_run1.txt")
    tps2=$(get_tps "$RESULTS_DIR/${config_name}_${wname}_run2.txt")
    tps3=$(get_tps "$RESULTS_DIR/${config_name}_${wname}_run3.txt")
    lat=$(get_latency "$RESULTS_DIR/${config_name}_${wname}_run2.txt")

    if [ "$tps1" != "N/A" ] && [ "$tps2" != "N/A" ] && [ "$tps3" != "N/A" ]; then
      median=$(median_of_three "$tps1" "$tps2" "$tps3")
    else
      median="N/A"
    fi

    if [ "$config_name" = "pg-stock" ]; then
      stock_median="$median"
      echo "| **$config_name** (baseline) | $tps1 | $tps2 | $tps3 | **$median** | $lat | — |"
    else
      if [ "$median" != "N/A" ] && [ "$stock_median" != "N/A" ] && [ "$stock_median" != "0" ]; then
        pct=$(echo "scale=1; ($median - $stock_median) * 100 / $stock_median" | bc)
        echo "| $config_name | $tps1 | $tps2 | $tps3 | **$median** | $lat | **${pct}%** |"
      else
        echo "| $config_name | $tps1 | $tps2 | $tps3 | **$median** | $lat | N/A |"
      fi
    fi
  done
  echo ""
done

echo "### Summary: Overhead comparison"
echo ""
echo "| Scenario | USDT (idle) | USDT (bpftrace) | WET (GUC off) | WET (timing on) | WET (all on) |"
echo "|---|---|---|---|---|---|"

for w_idx in "${!WORKLOAD_NAMES[@]}"; do
  wname="${WORKLOAD_NAMES[$w_idx]}"
  wlabel="${WORKLOAD_LABELS[$w_idx]}"

  stock_tps1=$(get_tps "$RESULTS_DIR/pg-stock_${wname}_run1.txt")
  stock_tps2=$(get_tps "$RESULTS_DIR/pg-stock_${wname}_run2.txt")
  stock_tps3=$(get_tps "$RESULTS_DIR/pg-stock_${wname}_run3.txt")
  stock_median=$(median_of_three "$stock_tps1" "$stock_tps2" "$stock_tps3")

  row="| $wlabel |"
  for config_name in "pg-usdt-idle" "pg-usdt-bpftrace" "pg-wet-off" "pg-wet-timing" "pg-wet-all"; do
    tps1=$(get_tps "$RESULTS_DIR/${config_name}_${wname}_run1.txt")
    tps2=$(get_tps "$RESULTS_DIR/${config_name}_${wname}_run2.txt")
    tps3=$(get_tps "$RESULTS_DIR/${config_name}_${wname}_run3.txt")
    median=$(median_of_three "$tps1" "$tps2" "$tps3")

    if [ "$median" != "N/A" ] && [ "$stock_median" != "N/A" ] && [ "$stock_median" != "0" ]; then
      pct=$(echo "scale=1; ($median - $stock_median) * 100 / $stock_median" | bc)
      row="$row ${pct}% |"
    else
      row="$row N/A |"
    fi
  done
  echo "$row"
done
echo ""
