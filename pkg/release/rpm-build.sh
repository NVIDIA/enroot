#!/bin/bash -eu

OUTPUT_DIR="${1:-/output/}"
mkdir -p "${OUTPUT_DIR}"

set -x

# enroot package
CPPFLAGS="-DALLOW_SPECULATION -DINHERIT_FDS" make rpm
cp -v dist/$(uname -m)/enroot*.rpm "${OUTPUT_DIR}/"

# hardened enroot package
make rpm PACKAGE=enroot-hardened
cp -v dist/$(uname -m)/enroot*.rpm "${OUTPUT_DIR}/"

# Cross-compile only from x86_64
if [ "$(uname -m)" = "x86_64" ]; then
    # aarch64 enroot package
    ARCH=aarch64 CC=aarch64-none-linux-gnu-gcc CPPFLAGS="-DALLOW_SPECULATION -DINHERIT_FDS" make rpm
    cp -v dist/aarch64/enroot*.rpm "${OUTPUT_DIR}/"

    # aarch64 hardened enroot package
    ARCH=aarch64 CC=aarch64-none-linux-gnu-gcc make rpm PACKAGE=enroot-hardened
    cp -v dist/aarch64/enroot*.rpm "${OUTPUT_DIR}/"
fi
