# Copyright (c) 2022-2025, PostgreSQL Global Development Group

pg_query_json_sources = files(
  'pg_query_json.c',
)

if host_system == 'windows'
  pg_query_json_sources += rc_lib_gen.process(win32ver_rc, extra_args: [
    '--NAME', 'pg_query_json',
    '--FILEDESC', 'pg_query_json - parse SQL statements and return parse tree',])
endif

pg_query_json = shared_module('pg_query_json',
  pg_query_json_sources,
  kwargs: contrib_mod_args,
)
contrib_targets += pg_query_json

install_data(
  'pg_query_json.control',
  'pg_query_json--1.0.sql',
  kwargs: contrib_data_args,
)

tests += {
  'name': 'pg_query_json',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'regress': {
    'sql': [
      'pg_query_json',
    ],
  },
}
