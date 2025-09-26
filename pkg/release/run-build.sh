#!/bin/bash -eu

OUTPUT_DIR="${1:-/output/}"
mkdir -p "${OUTPUT_DIR}"

set -x

make deb PACKAGE=enroot-hardened
apt-get install -y ./dist/enroot*.deb

for arch in x86_64 aarch64; do
    ARCH=${arch} ./pkg/runbuild
done
cp -v dist/*.run "${OUTPUT_DIR}/"
