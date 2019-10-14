unexport prefix exec_prefix bindir libdir sysconfdir

MAKESELF_VERSION := 2.4.0
LIBBSD_VERSION   := 0.9.1

.PHONY: all libbsd makeself clean
.DEFAULT_GOAL := all

ifdef CROSS_COMPILE
HOST_ARG := --host=$(CROSS_COMPILE)
endif

makeself/.stamp:
	install -m 755 -D makeself/makeself.sh dist/usr/bin/enroot-makeself
	touch $@

libbsd/.stamp: export CPPFLAGS := -D_FORTIFY_SOURCE=2
libbsd/.stamp: export CFLAGS   := -O2 -fdata-sections -ffunction-sections -fstack-protector -fPIE
libbsd/.stamp:
	echo $(LIBBSD_VERSION) > libbsd/.dist-version
	cd libbsd && ./autogen && ./configure --prefix=$(CURDIR)/dist --disable-shared $(HOST_ARG)
	$(MAKE) MAKEFLAGS= -C libbsd install
	touch $@

all: makeself libbsd
libbsd: libbsd/.stamp
makeself: makeself/.stamp
clean:
	-cd makeself && { git clean -f -d -x; $(RM) .stamp; }
	-cd libbsd && { git clean -f -d -x; $(MAKE) MAKEFLAGS= distclean; $(RM) .stamp; }
	rm -rf dist
