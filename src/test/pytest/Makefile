# src/test/pytest/Makefile

subdir = src/test/pytest
top_builddir = ../../..
include $(top_builddir)/src/Makefile.global

check:
	$(pytest_check)

installcheck:
	$(pytest_installcheck)

clean distclean maintainer-clean:
	rm -rf tmp_check
