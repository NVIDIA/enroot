arch        ?= $(shell uname -m)
prefix      ?= /usr/local
exec_prefix ?= $(prefix)
bindir      ?= $(exec_prefix)/bin
libdir      ?= $(exec_prefix)/lib
sysconfdir  ?= $(prefix)/etc

DESTDIR     := $(abspath $(DESTDIR))
BINDIR      = $(DESTDIR)$(bindir)
LIBDIR      = $(DESTDIR)$(libdir)/enroot
SYSCONFDIR  = $(DESTDIR)$(sysconfdir)/enroot

USERNAME := NVIDIA CORPORATION
EMAIL    := cudatools@nvidia.com

PACKAGE ?= enroot
VERSION := 1.0.0

BIN     := enroot

SRCS    := src/common.sh  \
           src/bundle.sh  \
           src/docker.sh  \
           src/init.sh    \
           src/runtime.sh

DEPS    := deps/dist/usr/bin/enroot-makeself \

UTILS   := bin/enroot-aufs2ovlfs    \
           bin/enroot-mksquashovlfs \
           bin/enroot-mount         \
           bin/enroot-switchroot    \
           bin/enroot-unshare

CONFIG  := conf/enroot.conf

HOOKS   := conf/hooks/10-cgroups.sh \
           conf/hooks/10-devices.sh \
           conf/hooks/10-home.sh    \
           conf/hooks/10-shadow.sh  \
           conf/hooks/20-autorc.sh  \
           conf/hooks/99-nvidia.sh

MOUNTS  := conf/mounts/10-system.fstab \
           conf/mounts/20-config.fstab

ENVIRON := conf/environ/10-terminal.env

.PHONY: all install uninstall clean dist deps depsclean mostlyclean deb distclean
.DEFAULT_GOAL := all

CPPFLAGS := -D_FORTIFY_SOURCE=2 -I$(CURDIR)/deps/dist/include $(CPPFLAGS)
CFLAGS   := -std=c99 -O2 -fstack-protector -fPIE -s -pedantic                                       \
            -Wall -Wextra -Wcast-align -Wpointer-arith -Wmissing-prototypes -Wnonnull               \
            -Wwrite-strings -Wlogical-op -Wformat=2 -Wmissing-format-attribute -Winit-self -Wshadow \
            -Wstrict-prototypes -Wunreachable-code -Wconversion -Wsign-conversion $(CFLAGS)
LDFLAGS  := -pie -Wl,-zrelro -Wl,-znow -Wl,-zdefs -Wl,--as-needed -Wl,--gc-sections -L$(CURDIR)/deps/dist/lib $(LDFLAGS)
LDLIBS   := -lbsd

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

install: all uninstall
	install -d -m 755 $(SYSCONFDIR) $(LIBDIR) $(BINDIR)
	install -d -m 755 $(SYSCONFDIR)/environ.d $(SYSCONFDIR)/mounts.d $(SYSCONFDIR)/hooks.d
	install -m 644 $(ENVIRON) $(SYSCONFDIR)/environ.d
	install -m 644 $(MOUNTS) $(SYSCONFDIR)/mounts.d
	install -m 755 $(HOOKS) $(SYSCONFDIR)/hooks.d
	install -m 644 $(CONFIG) $(SYSCONFDIR)
	install -m 644 $(SRCS) $(LIBDIR)
	install -m 755 $(BIN) $(UTILS) $(DEPS) $(BINDIR)

uninstall:
	$(RM) $(addprefix $(BINDIR)/, $(notdir $(BIN)) $(notdir $(UTILS)) $(notdir $(DEPS)))
	$(RM) -r $(LIBDIR) $(SYSCONFDIR)

mostlyclean:
	$(RM) $(BIN) $(CONFIG) $(UTILS)

clean: mostlyclean depsclean

dist: DESTDIR:=enroot_$(VERSION)
dist: install
	mkdir -p dist
	sed -i 's;$(DESTDIR);;' $(BINDIR)/$(BIN) $(SYSCONFDIR)/$(notdir $(CONFIG))
	tar --numeric-owner --owner=0 --group=0 -C $(dir $(DESTDIR)) -caf dist/$(DESTDIR)_$(arch).tar.xz $(notdir $(DESTDIR))
	$(RM) -r $(DESTDIR)

distclean: clean
	$(RM) -r dist

setcap:
	setcap cap_sys_admin+pe $(BINDIR)/enroot-mksquashovlfs
	setcap cap_sys_admin,cap_mknod+pe $(BINDIR)/enroot-aufs2ovlfs

deb: export DEBFULLNAME := $(USERNAME)
deb: export DEBEMAIL    := $(EMAIL)
deb: clean
	dh_make -y -d -s -c bsd -t $(CURDIR)/pkg/deb -p $(PACKAGE)_$(VERSION) --createorig
	cp -a pkg/deb/source debian && rename.ul "#PACKAGE#" $(PACKAGE) debian/* && chmod +x debian/do_release
	debuild -e PACKAGE -e DO_RELEASE --dpkg-buildpackage-hook=debian/do_release -us -uc -G -i -tc
	$(RM) -r debian

rpm: clean
	mkdir -p dist
	rpmbuild --clean -ba -D"_topdir $(CURDIR)/pkg/rpm" -D"PACKAGE $(PACKAGE)" -D"VERSION $(VERSION)" -D"USERNAME $(USERNAME)" -D"EMAIL $(EMAIL)" pkg/rpm/SPECS/*
	-rpmlint pkg/rpm/RPMS/*
	$(RM) -r $(addprefix pkg/rpm/, BUILDROOT SOURCES)
