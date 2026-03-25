#!/bin/bash
# Round 7: Three-way comparison — Stock vs USDT vs wait-event-timing
# VM setup script: installs dependencies, builds all PG variants
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "=== Installing build dependencies ==="
apt-get update -qq
apt-get install -y -qq \
  build-essential git flex bison libreadline-dev zlib1g-dev \
  libssl-dev libxml2-dev libxslt1-dev libsystemd-dev \
  systemtap-sdt-dev \
  linux-tools-common linux-tools-$(uname -r) \
  bpftrace \
  python3 python3-pip \
  numactl sysstat \
  2>&1 | tail -5

# FlameGraph tools
if [ ! -d /opt/FlameGraph ]; then
  git clone --depth=1 https://github.com/brendangregg/FlameGraph /opt/FlameGraph
fi

echo "=== Cloning PostgreSQL repos ==="
cd /opt

# Stock master
if [ ! -d pg-stock ]; then
  git clone --depth=1 https://github.com/postgres/postgres.git pg-stock
fi

# USDT branch (NikolayS)
if [ ! -d pg-usdt ]; then
  git clone --depth=1 -b usdt-wait-event-poc https://github.com/NikolayS/postgres.git pg-usdt
fi

# wait-event-timing branch (DmitryNFomin)
if [ ! -d pg-wet ]; then
  git clone --depth=1 -b wait-event-timing https://github.com/DmitryNFomin/postgres.git pg-wet
fi

echo "=== Building pg-stock (baseline, no dtrace) ==="
cd /opt/pg-stock
./configure --prefix=/opt/pg-stock-install \
  --enable-debug CFLAGS="-g -O2" \
  --without-icu \
  2>&1 | tail -3
make -j$(nproc) 2>&1 | tail -3
make install 2>&1 | tail -3

echo "=== Building pg-usdt (with --enable-dtrace) ==="
cd /opt/pg-usdt
./configure --prefix=/opt/pg-usdt-install \
  --enable-debug --enable-dtrace CFLAGS="-g -O2" \
  --without-icu \
  2>&1 | tail -3
make -j$(nproc) 2>&1 | tail -3
make install 2>&1 | tail -3

echo "=== Building pg-wet-off (--enable-wait-event-timing, GUCs will be OFF) ==="
cd /opt/pg-wet
./configure --prefix=/opt/pg-wet-install \
  --enable-debug --enable-wait-event-timing CFLAGS="-g -O2" \
  --without-icu \
  2>&1 | tail -3
make -j$(nproc) 2>&1 | tail -3
make install 2>&1 | tail -3

echo "=== All builds complete ==="
ls -la /opt/pg-stock-install/bin/postgres
ls -la /opt/pg-usdt-install/bin/postgres
ls -la /opt/pg-wet-install/bin/postgres

echo "=== Verifying USDT probes ==="
readelf -n /opt/pg-usdt-install/bin/postgres 2>/dev/null | grep -c "wait_event" || echo "no probes found"

echo "=== Verifying wait-event-timing configure option ==="
/opt/pg-wet-install/bin/postgres --version

echo "=== Setup complete ==="
