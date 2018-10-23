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

SRCS    := common.sh  \
           docker.sh  \
           init.sh    \
           runtime.sh

UTILS   := utils/aufs2ovlfs    \
           utils/mksquashovlfs \
           utils/switchroot    \
           utils/unsharens

HOOKS   := conf/hooks/10-cgroup.sh  \
           conf/hooks/10-environ.sh \
           conf/hooks/10-shadow.sh  \
           conf/hooks/99-nvidia.sh  \
           conf/hooks/nvidia

MOUNTS  := conf/mounts/10-system.fstab \
           conf/mounts/20-config.fstab

.PHONY: all install uninstall clean dist

CPPFLAGS := -D_FORTIFY_SOURCE=2 $(CPPFLAGS)
CFLAGS   := -std=c99 -O2 -fstack-protector -fPIE -s -pedantic                                       \
            -Wall -Wextra -Wcast-align -Wpointer-arith -Wmissing-prototypes -Wnonnull               \
            -Wwrite-strings -Wlogical-op -Wformat=2 -Wmissing-format-attribute -Winit-self -Wshadow \
            -Wstrict-prototypes -Wunreachable-code -Wconversion -Wsign-conversion $(CFLAGS)
LDFLAGS  := -pie -Wl,-zrelro -Wl,-znow -Wl,-zdefs $(LDFLAGS)

all: $(UTILS)

install: all
	install -d -m 755 $(SYSCONFDIR) $(LIBEXECDIR) $(BINDIR)
	install -d -m 755 $(SYSCONFDIR)/environ.d $(SYSCONFDIR)/mounts.d $(SYSCONFDIR)/hooks.d $(LIBEXECDIR)/utils
	install -m 644 $(MOUNTS) $(SYSCONFDIR)/mounts.d
	install -m 755 $(HOOKS) $(SYSCONFDIR)/hooks.d
	install -m 755 $(UTILS) $(LIBEXECDIR)/utils
	install -m 644 $(SRCS) $(LIBEXECDIR)
	install -m 755 $(BIN) $(BINDIR)
	sed -i 's;@sysconfdir@;$(SYSCONFDIR);' $(BINDIR)/$(BIN)
	sed -i 's;@libexecdir@;$(LIBEXECDIR);' $(BINDIR)/$(BIN)
	sed -i 's;@version@;$(VERSION);' $(BINDIR)/$(BIN)

uninstall:
	$(RM) $(BINDIR)/$(BIN)
	$(RM) -r $(LIBEXECDIR) $(SYSCONFDIR)

clean:
	$(RM) $(UTILS)

dist: DESTDIR:=enroot_$(VERSION)
dist: install
	sed -i '/^config/s;$(DESTDIR);;' $(BINDIR)/$(BIN)
	tar --numeric-owner --owner=0 --group=0 -C $(dir $(DESTDIR)) -caf $(DESTDIR)_$(arch).tar.xz $(notdir $(DESTDIR))
	$(RM) -r $(DESTDIR)

setcap:
	setcap cap_sys_admin+pe $(LIBEXECDIR)/utils/mksquashovlfs
	setcap cap_sys_admin,cap_mknod+pe $(LIBEXECDIR)/utils/aufs2ovlfs
