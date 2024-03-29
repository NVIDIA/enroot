unexport prefix exec_prefix bindir libdir sysconfdir DESTDIR

MAKESELF_VERSION     := 2.4.5
LIBBSD_VERSION       := 0.11.7
MUSL_VERSION         := 1.2.3
LINUX_HEADER_VERSION := 4.19.88-1

.PHONY: all libbsd makeself musl linux-headers clean update
.DEFAULT_GOAL := all

ifdef CROSS_COMPILE
HOST_ARG := --host=$(CROSS_COMPILE:-=)
endif

export CPPFLAGS := -D_FORTIFY_SOURCE=2
export CFLAGS   := -O2 -fdata-sections -ffunction-sections -fstack-protector -fPIE

# Required for Musl on PPC64
ifeq "$(ARCH:power%=p%)" "ppc64le"
CFLAGS   += -mlong-double-64
endif

MAKEOVERRIDES :=

makeself/.stamp:
	install -m 755 -D makeself/makeself.sh dist/makeself/bin/enroot-makeself
	touch $@

libbsd/.stamp:
	echo $(LIBBSD_VERSION) > libbsd/.dist-version
	cd libbsd && ./autogen && ./configure --prefix=$(CURDIR)/dist/libbsd --disable-shared $(HOST_ARG)
	$(MAKE) V=1 -C libbsd install
	touch $@

musl/.stamp:
	# XXX Add static PIE support to the GCC wrapper
	-patch -d musl -N -r - -p1 < musl.patch
	cd musl && ./configure --prefix=$(CURDIR)/dist/musl --disable-shared $(HOST_ARG)
	$(MAKE) -C musl install
	# XXX Workaround for GCC < 5.0
	touch $(CURDIR)/dist/musl/include/sys/cdefs.h
	touch $@

# XXX Quirk for PPC64 directory name
ifeq "$(ARCH:power%=p%)" "ppc64le"
linux-headers/.stamp: export ARCH:=powerpc
endif
linux-headers/.stamp:
	$(MAKE) -C linux-headers install prefix=$(CURDIR)/dist/musl
	touch $@

all: libbsd makeself musl linux-headers
musl: musl/.stamp
linux-headers: linux-headers/.stamp
libbsd: libbsd/.stamp
makeself: makeself/.stamp
clean:
	-cd makeself && { git clean -f -d -x; $(RM) .stamp; }
	-cd libbsd && { git clean -f -d -x; $(MAKE) distclean; $(RM) .stamp; }
	-cd musl && { git clean -f -d -x; $(MAKE) distclean; git checkout .; $(RM) .stamp; }
	-cd linux-headers && { git clean -f -d -x; $(RM) .stamp; }
	rm -rf dist

update: clean
	git submodule sync --recursive
	cd makeself && { git fetch origin; git checkout -f release-$(MAKESELF_VERSION); }
	cd libbsd && { git fetch origin; git checkout -f $(LIBBSD_VERSION); }
	cd musl && { git fetch origin; git checkout -f v$(MUSL_VERSION); }
	cd linux-headers && { git fetch origin; git checkout -f v$(LINUX_HEADER_VERSION); }
