MAKESELF_VERSION := 2.4.0
LIBBSD_VERSION   := 0.9.1

.PHONY: all libbsd makeself clean
.DEFAULT_GOAL := all

makeself/.stamp:
	install -m 755 -D makeself/makeself.sh dist/usr/bin/makeself
	touch $@

libbsd/.stamp: export CPPFLAGS := -D_FORTIFY_SOURCE=2 $(CPPFLAGS)
libbsd/.stamp: export CFLAGS   := -O2 -fdata-sections -ffunction-sections -fstack-protector -fPIC $(CFLAGS)
libbsd/.stamp:
	echo $(LIBBSD_VERSION) > libbsd/.dist-version
	cd libbsd && ./autogen && ./configure --prefix=$(CURDIR)/dist --disable-shared
	$(MAKE) -C libbsd install
	touch $@

all: makeself libbsd
libbsd: libbsd/.stamp
makeself: makeself/.stamp
clean:
	cd makeself && git clean -f -d -x
	cd libbsd && git clean -f -d -x
	rm -rf dist
