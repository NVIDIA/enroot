prefix      ?= /usr/local
exec_prefix ?= $(prefix)
bindir      ?= $(exec_prefix)/bin
libdir      ?= $(exec_prefix)/lib
sysconfdir  ?= $(prefix)/etc
datarootdir ?= $(prefix)/share
datadir     ?= $(datarootdir)

override DESTDIR := $(abspath $(DESTDIR))

BINDIR     = $(DESTDIR)$(bindir)
LIBDIR     = $(DESTDIR)$(libdir)/enroot
SYSCONFDIR = $(DESTDIR)$(sysconfdir)/enroot
DATADIR    = $(DESTDIR)$(datadir)/enroot

VERSION       := 3.5.0
PACKAGE       ?= enroot
ARCH          ?= $(shell uname -m)
DEBUG         ?=
CROSS_COMPILE ?=
FORCE_GLIBC   ?=
DO_RELEASE    ?=

USERNAME := NVIDIA CORPORATION
EMAIL    := cudatools@nvidia.com

BIN := enroot

SRCS := src/common.sh  \
        src/bundle.sh  \
        src/docker.sh  \
        src/runtime.sh

DEPS := deps/dist/makeself/bin/enroot-makeself \

UTILS := bin/enroot-aufs2ovlfs    \
         bin/enroot-mksquashovlfs \
         bin/enroot-mount         \
         bin/enroot-switchroot    \
         bin/enroot-nsenter

CONFIGFILE := enroot.conf
CONFIG := conf/$(CONFIGFILE)
CONFIGINFO := conf/$(CONFIGFILE).d/README

HOOKS := conf/hooks/10-aptfix.sh    \
         conf/hooks/10-cgroups.sh   \
         conf/hooks/10-devices.sh   \
         conf/hooks/10-home.sh      \
         conf/hooks/10-localtime.sh \
         conf/hooks/10-shadow.sh    \
         conf/hooks/98-nvidia.sh    \
         conf/hooks/99-mellanox.sh  \

CONFIG_EXTRA := conf/bash_completion \
                conf/apparmor.profile

HOOKS_EXTRA := conf/hooks/extra/50-slurm-pmi.sh     \
               conf/hooks/extra/50-slurm-pytorch.sh \
               conf/hooks/extra/50-mig-config.sh    \
               conf/hooks/extra/50-sharp.sh

MOUNTS := conf/mounts/10-system.fstab \
          conf/mounts/20-config.fstab

MOUNTS_EXTRA := conf/mounts/extra/30-lxcfs.fstab

ENVIRON := conf/environ/10-terminal.env

.PHONY: all install uninstall clean dist deps depsclean mostlyclean deb distclean
.DEFAULT_GOAL := all

CPPFLAGS := -D_FORTIFY_SOURCE=2 -isystem $(CURDIR)/deps/dist/libbsd/include -isystem $(CURDIR)/deps/dist/linux/include $(CPPFLAGS)
CFLAGS   := -std=c99 -O2 -fstack-protector -fPIE -pedantic                                          \
            -Wall -Wextra -Wcast-align -Wpointer-arith -Wmissing-prototypes -Wnonnull               \
            -Wwrite-strings -Wlogical-op -Wformat=2 -Wmissing-format-attribute -Winit-self -Wshadow \
            -Wstrict-prototypes -Wunreachable-code -Wconversion -Wsign-conversion $(CFLAGS)
LDFLAGS  := -Wl,-zrelro -Wl,-znow -Wl,-zdefs -Wl,--as-needed -Wl,--gc-sections -L$(CURDIR)/deps/dist/libbsd $(LDFLAGS)
LDLIBS   := -l:libbsd.a

ifdef DEBUG
CFLAGS   += -g3 -fno-omit-frame-pointer -fno-common -fsanitize=undefined,address,leak
LDLIBS   += -lubsan
else
CFLAGS   += -s
endif

# Required for Musl on PPC64
ifeq "$(ARCH:power%=p%)" "ppc64le"
CFLAGS   += -mlong-double-64
endif

# Infer the compiler used for cross compilation if not specified.
ifeq "$(origin CC)" "default"
CC       := $(shell readlink -f $(shell sh -c 'command -v $(CC)'))
ifdef CROSS_COMPILE
CC       := $(CROSS_COMPILE)$(notdir $(CC))
endif
endif
export CC ARCH CROSS_COMPILE

# Compile the utilities statically against musl libc.
ifndef FORCE_GLIBC
ifneq (,$(findstring gcc, $(notdir $(CC))))
$(UTILS): override CC := $(CURDIR)/deps/dist/musl/bin/musl-gcc
$(UTILS): LDFLAGS     += -pie -static-pie
else ifneq (,$(findstring clang, $(notdir $(CC))))
$(UTILS): override CC := $(CURDIR)/deps/dist/musl/bin/musl-clang
$(UTILS): LDFLAGS     += -pie -static-pie
else
$(error MUSL CC wrapper not found for $(CC))
endif
endif

$(BIN) $(CONFIG): %: %.in
	sed -e 's;@sysconfdir@;$(SYSCONFDIR);' \
	    -e 's;@libdir@;$(LIBDIR);' \
	    -e 's;@version@;$(VERSION);' $< > $@

$(DEPS) $(UTILS): | deps

all: $(BIN) $(CONFIG) $(DEPS) $(UTILS)

deps:
	-git submodule update --init
	$(MAKE) -C deps

depsclean:
	$(MAKE) -C deps clean

install: all
	install -d -m 755 $(SYSCONFDIR) $(LIBDIR) $(BINDIR) $(DATADIR)
	install -d -m 755 $(addprefix $(SYSCONFDIR)/, environ.d mounts.d hooks.d $(CONFIGFILE).d)
	install -d -m 755 $(addprefix $(DATADIR)/, environ.d mounts.d hooks.d)
	install -m 644 $(ENVIRON) $(SYSCONFDIR)/environ.d
	install -m 644 $(MOUNTS) $(SYSCONFDIR)/mounts.d
	install -m 755 $(HOOKS) $(SYSCONFDIR)/hooks.d
	install -m 755 $(HOOKS_EXTRA) $(DATADIR)/hooks.d
	install -m 644 $(MOUNTS_EXTRA) $(DATADIR)/mounts.d
	install -m 644 $(CONFIG_EXTRA) $(DATADIR)
	install -m 644 $(CONFIG) $(SYSCONFDIR)
	install -m 644 $(CONFIGINFO) $(SYSCONFDIR)/$(CONFIGFILE).d
	install -m 644 $(SRCS) $(LIBDIR)
	install -m 755 $(BIN) $(UTILS) $(DEPS) $(BINDIR)

uninstall:
	$(RM) $(addprefix $(BINDIR)/, $(notdir $(BIN)) $(notdir $(UTILS)) $(notdir $(DEPS)))
	$(RM) -r $(LIBDIR) $(SYSCONFDIR) $(DATADIR)

mostlyclean:
	$(RM) $(BIN) $(CONFIG) $(UTILS)

clean: mostlyclean depsclean

dist: DESTDIR := enroot_$(VERSION)
dist: install
	mkdir -p dist
	sed -i 's;$(DESTDIR);;' $(BINDIR)/$(BIN) $(SYSCONFDIR)/$(notdir $(CONFIG))
	tar --numeric-owner --owner=0 --group=0 -C $(dir $(DESTDIR)) -caf dist/$(DESTDIR)_$(ARCH).tar.xz $(notdir $(DESTDIR))
	$(RM) -r $(DESTDIR)

distclean: clean
	$(RM) -r dist

setcap:
	setcap cap_sys_admin+pe $(BINDIR)/enroot-mksquashovlfs
	setcap cap_sys_admin,cap_mknod+pe $(BINDIR)/enroot-aufs2ovlfs

deb: export DEBFULLNAME := $(USERNAME)
deb: export DEBEMAIL    := $(EMAIL)
deb: clean
	$(RM) -r debian
	dh_make -y -d -s -c apache -t $(CURDIR)/pkg/deb -p $(PACKAGE)_$(VERSION) --createorig && cp -ar pkg/deb/source debian
	debuild --preserve-env -us -uc -G -i -tc --host-type $(ARCH)-linux-gnu
	mkdir -p dist && find .. -maxdepth 1 -type f -name '$(PACKAGE)*' -exec mv {} dist \;
	$(RM) -r debian

rpm: clean
	mkdir -p dist
	rpmbuild --target=$(ARCH) --clean -ba -D"_topdir $(CURDIR)/pkg/rpm" -D"PACKAGE $(PACKAGE)" -D"VERSION $(VERSION)" -D"USERNAME $(USERNAME)" -D"EMAIL $(EMAIL)" pkg/rpm/SPECS/*
	-rpmlint pkg/rpm/RPMS/*
	$(RM) -r $(addprefix pkg/rpm/, BUILDROOT SOURCES)
