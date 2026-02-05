# contrib/pg_stat_statements_nsp/Makefile

MODULE_big = pg_stat_statements_nsp
OBJS = \
	$(WIN32RES) \
	pg_stat_statements_nsp.o

EXTENSION = pg_stat_statements_nsp
DATA = pg_stat_statements_nsp--1.0.sql
PGFILEDESC = "pg_stat_statements_nsp - execution statistics without shared_preload_libraries"

REGRESS = pg_stat_statements_nsp

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_stat_statements_nsp
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
