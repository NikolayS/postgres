# oracles/

Reserved for per-oracle modules. For the P1 seed, all oracle implementations
live inline in `../harness.py` (see `oracle_recovery_completed`,
`oracle_amcheck_clean`, `oracle_checksum_scan`, `oracle_catalog_fs_crosscheck`,
`oracle_readdir_open_sanity`, `oracle_committed_xact_visibility`).

When the set grows (new fault-injection modes, per-subsystem deep checks,
etc.), split them into files here:

    oracles/
    ├── recovery_completed.py
    ├── amcheck_clean.py
    ├── checksum_scan.py
    ├── catalog_fs_crosscheck.py
    ├── readdir_open_sanity.py
    └── committed_xact_visibility.py

Each should expose a `run(args, *, mount, pgdata) -> dict[str, Any]` callable
returning `{"ok": bool, ...}`. `run_all_oracles()` in `harness.py` is the
seam — update it to iterate over a plugin list rather than calling each
function by name.

See `../README.md` for the oracle catalogue and rationale.
