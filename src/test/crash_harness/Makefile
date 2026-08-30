# src/test/crash_harness/Makefile
#
# Convenience targets for the dm-log-writes crash-consistency harness.
# Linux-only; the `guard-linux` target aborts cleanly on macOS/Windows.
#
# Usage:
#   sudo make install-deps     # clones josefbacik/log-writes and builds replay-log
#   sudo make check            # setup + record + replay-all + teardown
#   make clean                 # remove images + working state
#
# Not wired into the top-level Postgres build — this is orchestration, not a
# build artifact. Invoke directly from this directory.

PYTHON      ?= python3
HARNESS     := ./harness.py
WORKDIR     ?= /var/tmp/crash-harness
BACKING     ?= $(WORKDIR)/backing.img
LOG         ?= $(WORKDIR)/log.img
REPLAY      ?= $(WORKDIR)/replay.img
MOUNT       ?= /mnt/crash-harness
REPLAY_MT   ?= /mnt/crash-harness-replay
TARGET      ?= crash-harness
PG_BIN      ?= /usr/lib/postgresql/16/bin
PORT        ?= 55432
BACKING_SZ  ?= 8G
LOG_SZ      ?= 4G
REPLAY_LOG  ?= $(WORKDIR)/log-writes/replay-log

.PHONY: guard-linux install-deps setup record replay-all check teardown clean help

help:
	@echo "crash_harness: dm-log-writes crash-consistency driver for Postgres"
	@echo "Targets: install-deps, setup, record, replay-all, check, teardown, clean"
	@echo "Run as root (sudo make check) — dmsetup/losetup need CAP_SYS_ADMIN."

guard-linux:
	@if [ "$$(uname -s)" != "Linux" ]; then \
	    echo "error: crash_harness is Linux-only (dm-log-writes is a kernel"; \
	    echo "       device-mapper target). Detected: $$(uname -s)."; \
	    exit 1; \
	fi

# Clone + build the upstream replay-log tool. Creates $(WORKDIR)/log-writes/.
install-deps: guard-linux
	@mkdir -p $(WORKDIR)
	@if [ ! -d $(WORKDIR)/log-writes ]; then \
	    git clone https://github.com/josefbacik/log-writes.git $(WORKDIR)/log-writes; \
	fi
	$(MAKE) -C $(WORKDIR)/log-writes
	@echo "replay-log built at $(REPLAY_LOG)"
	@echo "Optionally: sudo cp $(REPLAY_LOG) /usr/local/bin/"

setup: guard-linux
	@mkdir -p $(WORKDIR)
	$(PYTHON) $(HARNESS) setup \
	    --backing $(BACKING) --log $(LOG) \
	    --backing-size $(BACKING_SZ) --log-size $(LOG_SZ) \
	    --target-name $(TARGET)

record: guard-linux
	$(PYTHON) $(HARNESS) record \
	    --log $(LOG) --target-name $(TARGET) --mount $(MOUNT) \
	    --pg-bin $(PG_BIN) --port $(PORT) \
	    --random-every 3

replay-all: guard-linux
	$(PYTHON) $(HARNESS) replay \
	    --log $(LOG) --backing $(BACKING) \
	    --replay-image $(REPLAY) --replay-mount $(REPLAY_MT) \
	    --replay-log-bin $(REPLAY_LOG) \
	    --pg-bin $(PG_BIN) --port $(PORT) \
	    --replay-to-mark all --verify

teardown: guard-linux
	$(PYTHON) $(HARNESS) teardown \
	    --backing $(BACKING) --log $(LOG) \
	    --mount $(MOUNT) --target-name $(TARGET)

check: guard-linux setup record replay-all teardown
	@echo "crash_harness: check complete"

clean: guard-linux
	$(MAKE) teardown || true
	rm -f $(BACKING) $(LOG) $(REPLAY) $(LOG).marks
	@echo "cleaned $(WORKDIR) image files (kept log-writes sources)"
