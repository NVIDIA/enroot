#!/bin/bash -eu

readonly project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly output_dir="${project_dir}/dist"
readonly arch=${ARCH:-$(uname -m)}

echo "Building enroot-check.run to: ${output_dir}"
echo "Architecture: ${arch}"

set -x

mkdir -p "${output_dir}"

docker build --platform "linux/${arch}" \
       -f "${project_dir}/pkg/release/Dockerfile.ubuntu" \
       -t "enroot-build-ubuntu:${arch}" "${project_dir}"

docker run --rm \
       --platform "linux/${arch}" \
       --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
       -v "${output_dir}:/output" \
       "enroot-build-ubuntu:${arch}" run-build.sh
