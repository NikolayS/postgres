# contrib/pg_query_json/Makefile

MODULES = pg_query_json

EXTENSION = pg_query_json
DATA = pg_query_json--1.0.sql
PGFILEDESC = "pg_query_json - parse SQL statements and return parse tree"

REGRESS = pg_query_json

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_query_json
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
