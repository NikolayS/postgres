# Round 7: Three-Way Comparison Benchmarks

Comparing three approaches to PostgreSQL wait event observability:

1. **Stock PostgreSQL** (baseline)
2. **USDT probes** (`usdt-wait-event-poc` branch) — external eBPF tracing
3. **wait-event-timing** (`wait-event-timing` branch, DmitryNFomin) — internal Oracle-style instrumentation

## Key questions

- Do both approaches achieve the same goal?
- Overhead when compiled in but not actively used?
- Overhead when actively used?

## Scripts

- `setup-vm.sh` — installs deps, clones repos, builds all 3 PG variants
- `run-benchmarks.sh` — runs pgbench across all configs, collects flamegraphs
- `analyze-results.sh` — parses results into markdown tables

## Configurations

| # | Config | Branch | Build flags | Runtime |
|---|--------|--------|-------------|---------|
| 1 | pg-stock | master | no dtrace | baseline |
| 2 | pg-usdt-idle | usdt-wait-event-poc | `--enable-dtrace` | no tracer |
| 3 | pg-usdt-bpftrace | usdt-wait-event-poc | `--enable-dtrace` | bpftrace attached |
| 4 | pg-wet-off | wait-event-timing | `--enable-wait-event-timing` | GUCs OFF |
| 5 | pg-wet-timing | wait-event-timing | `--enable-wait-event-timing` | `wait_event_timing=on` |
| 6 | pg-wet-all | wait-event-timing | `--enable-wait-event-timing` | timing + trace ON |

## Workloads

- TPC-B (pgbench default): c8/j8, c64/j8
- SELECT 1 (ultra-lightweight): c1/j1, c8/j8
- 3 runs per config, 60s each, median reported

## VM

Hetzner cx43 (8 vCPU, 16GB RAM), Ubuntu 24.04, Helsinki
