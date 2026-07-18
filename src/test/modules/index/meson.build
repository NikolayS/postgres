# Copyright (c) 2025-2026, PostgreSQL Global Development Group

tests += {
  'name': 'index',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'isolation': {
    'specs': [
      'killtuples',
    ],
  },
  'tap': {
    'tests': [
      't/001_unlogged_lsn_stress.pl',
    ],
  },
}
