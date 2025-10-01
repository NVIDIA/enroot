#!/bin/bash -eu

OUTPUT_DIR="${1:-/output/}"
mkdir -p "${OUTPUT_DIR}"

set -x

make deb PACKAGE=enroot-hardened
apt-get install -y ./dist/enroot*.deb

./pkg/runbuild

cp -v dist/*.run "${OUTPUT_DIR}/"
