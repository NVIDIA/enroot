unexport prefix exec_prefix bindir libdir sysconfdir DESTDIR

LOCKFILE := Makefile.lock
AR := flock $(LOCKFILE) $(AR)
ARFLAGS := crU

MAKESELF_VERSION     := 2.4.5
MUSL_VERSION         := 1.2.5
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

LIBBSD_SRC := libbsd/src/closefrom.c \
              libbsd/src/strtoi.c    \
              libbsd/src/strtonum.c  \
              libbsd/src/strtou.c    \
              libbsd/src/fparseln.c

makeself/.stamp:
	install -m 755 -D makeself/makeself.sh dist/makeself/bin/enroot-makeself
	touch $@

ifndef FORCE_GLIBC
ifneq (,$(findstring gcc, $(notdir $(CC))))
%.o: CC := $(CURDIR)/dist/musl/bin/musl-gcc
else ifneq (,$(findstring clang, $(notdir $(CC))))
%.o: CC := $(CURDIR)/dist/musl/bin/musl-clang
else
$(error MUSL CC wrapper not found for $(CC))
endif
endif
%.o: CPPFLAGS += -DHAVE_DIRFD -DHAVE_DIRENT_H -DLIBBSD_OVERLAY -include libbsd/include/bsd/libutil.h

libbsd/.stamp: dist/libbsd/libbsd.a($(LIBBSD_SRC:.c=.o))
	install -D libbsd/include/sys/queue.h dist/libbsd/include/sys/queue.h
	install -D libbsd/include/bsd/libutil.h dist/libbsd/include/bsd/libutil.h
	install -D libbsd/include/bsd/inttypes.h dist/libbsd/include/bsd/inttypes.h
	install -D libbsd/include/bsd/unistd.h dist/libbsd/include/bsd/unistd.h
	touch $@
dist/libbsd/libbsd.a($(LIBBSD_SRC:.c=.o)): | dist/libbsd
dist/libbsd:
	install -d $@

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
	$(MAKE) -C linux-headers install prefix=$(CURDIR)/dist/linux
	touch $@

all: libbsd makeself linux-headers $(if $(FORCE_GLIBC),,musl)

musl: musl/.stamp
linux-headers: linux-headers/.stamp
.NOTPARALLEL: libbsd
libbsd: $(if $(FORCE_GLIBC),,musl) libbsd/.stamp
makeself: makeself/.stamp

clean:
	-cd makeself && { git clean -f -d -x; $(RM) .stamp; }
	-cd libbsd && $(RM) .stamp
	-cd musl && { git clean -f -d -x; $(MAKE) distclean; git checkout .; $(RM) .stamp; }
	-cd linux-headers && { git clean -f -d -x; $(RM) .stamp; }
	rm -rf dist
	$(RM) $(LOCKFILE)

update: clean
	git submodule sync --recursive
	cd makeself && { git fetch origin; git checkout -f release-$(MAKESELF_VERSION); }
	cd musl && { git fetch origin; git checkout -f v$(MUSL_VERSION); }
	cd linux-headers && { git fetch origin; git checkout -f v$(LINUX_HEADER_VERSION); }
