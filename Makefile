arch        ?= $(shell uname -m)
prefix      ?= /usr/local
exec_prefix ?= $(prefix)
bindir      ?= $(exec_prefix)/bin
libexecdir  ?= $(exec_prefix)/libexec
sysconfdir  ?= $(prefix)/etc

DESTDIR     := $(abspath $(DESTDIR))
BINDIR      = $(DESTDIR)$(bindir)
LIBEXECDIR  = $(DESTDIR)$(libexecdir)/enroot
SYSCONFDIR  = $(DESTDIR)$(sysconfdir)/enroot

VERSION := 1.0.0

BIN     := enroot

SRCS    := src/common.sh  \
           src/bundle.sh  \
           src/docker.sh  \
           src/init.sh    \
           src/runtime.sh

DEPS    := deps/dist/usr/bin/makeself \

UTILS   := bin/aufs2ovlfs    \
           bin/mksquashovlfs \
           bin/mountat       \
           bin/switchroot    \
           bin/unsharens

HOOKS   := conf/hooks/10-cgroups.sh \
           conf/hooks/10-devices.sh \
           conf/hooks/10-home.sh    \
           conf/hooks/10-shadow.sh  \
           conf/hooks/20-autorc.sh  \
           conf/hooks/99-nvidia.sh

MOUNTS  := conf/mounts/10-system.fstab \
           conf/mounts/20-config.fstab

ENVION  := conf/environ/10-terminal.env

.PHONY: all install uninstall clean dist deps depsclean mostlyclean
.DEFAULT_GOAL := all

CPPFLAGS := -D_FORTIFY_SOURCE=2 -Ideps/dist/include $(CPPFLAGS)
CFLAGS   := -std=c99 -O2 -fstack-protector -fPIE -s -pedantic                                       \
            -Wall -Wextra -Wcast-align -Wpointer-arith -Wmissing-prototypes -Wnonnull               \
            -Wwrite-strings -Wlogical-op -Wformat=2 -Wmissing-format-attribute -Winit-self -Wshadow \
            -Wstrict-prototypes -Wunreachable-code -Wconversion -Wsign-conversion $(CFLAGS)
LDFLAGS  := -pie -Wl,-zrelro -Wl,-znow -Wl,-zdefs -Wl,--as-needed -Wl,--gc-sections -Ldeps/dist/lib $(LDFLAGS)
LDLIBS   := -lbsd

$(BIN): %: %.in
	sed -e 's;@sysconfdir@;$(SYSCONFDIR);' \
	    -e 's;@libexecdir@;$(LIBEXECDIR);' \
	    -e 's;@version@;$(VERSION);' $< > $@

all: deps $(BIN) $(UTILS)

deps:
	git submodule update --init
	$(MAKE) -C deps

depsclean:
	$(MAKE) -C deps clean

install: all uninstall
	install -d -m 755 $(SYSCONFDIR) $(LIBEXECDIR) $(BINDIR)
	install -d -m 755 $(SYSCONFDIR)/environ.d $(SYSCONFDIR)/mounts.d $(SYSCONFDIR)/hooks.d
	install -m 644 $(ENVION) $(SYSCONFDIR)/environ.d
	install -m 644 $(MOUNTS) $(SYSCONFDIR)/mounts.d
	install -m 755 $(HOOKS) $(SYSCONFDIR)/hooks.d
	install -m 755 $(UTILS) $(LIBEXECDIR)
	install -m 644 $(SRCS) $(LIBEXECDIR)
	install -m 755 $(DEPS) $(LIBEXECDIR)
	install -m 755 $(BIN) $(BINDIR)

uninstall:
	$(RM) $(BINDIR)/$(BIN)
	$(RM) -r $(LIBEXECDIR) $(SYSCONFDIR)

mostlyclean:
	$(RM) $(BIN) $(UTILS)

clean: mostlyclean depsclean

dist: DESTDIR:=enroot_$(VERSION)
dist: install
	sed -i 's;$(DESTDIR);;' $(BINDIR)/$(BIN)
	tar --numeric-owner --owner=0 --group=0 -C $(dir $(DESTDIR)) -caf $(DESTDIR)_$(arch).tar.xz $(notdir $(DESTDIR))
	$(RM) -r $(DESTDIR)

setcap:
	setcap cap_sys_admin+pe $(LIBEXECDIR)/mksquashovlfs
	setcap cap_sys_admin,cap_mknod+pe $(LIBEXECDIR)/aufs2ovlfs
