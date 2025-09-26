#!/bin/bash -eu

OUTPUT_DIR="${1:-/output/}"
mkdir -p "${OUTPUT_DIR}"

set -x

# enroot package
CPPFLAGS="-DALLOW_SPECULATION -DINHERIT_FDS" make deb
cp -v dist/enroot*.deb "${OUTPUT_DIR}/"

# hardened enroot package
make deb PACKAGE=enroot-hardened
cp -v dist/enroot*.deb "${OUTPUT_DIR}/"

# Cross-compile only from x86_64
if [ "$(uname -m)" = "x86_64" ]; then
    # aarch64 enroot package
    ARCH=aarch64 CC=aarch64-linux-gnu-gcc-13 CPPFLAGS="-DALLOW_SPECULATION -DINHERIT_FDS" make deb
    cp -v dist/enroot*.deb "${OUTPUT_DIR}/"

    # aarch64 hardened enroot package
    ARCH=aarch64 CC=aarch64-linux-gnu-gcc-13 make deb PACKAGE=enroot-hardened
    cp -v dist/enroot*.deb "${OUTPUT_DIR}/"
fi
