#!/bin/bash -eu

readonly project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly output_dir="${project_dir}/dist"
readonly arch=${ARCH:-$(uname -m)}

echo "Building deb/rpm packages to: ${output_dir}"
echo "Architecture: ${arch}"

mkdir -p "${output_dir}"

set -x

docker build --platform "linux/${arch}" \
       -f "${project_dir}/pkg/release/Dockerfile.ubuntu" \
       -t "enroot-build-ubuntu:${arch}" "${project_dir}"

docker run --rm \
       --platform "linux/${arch}" \
       -v "${output_dir}:/output" \
       "enroot-build-ubuntu:${arch}"

docker build \
       --platform "linux/${arch}" \
       -f "${project_dir}/pkg/release/Dockerfile.almalinux" \
       -t "enroot-build-almalinux:${arch}" "${project_dir}"

docker run --rm \
       --platform "linux/${arch}" \
       -v "${output_dir}:/output" \
       "enroot-build-almalinux:${arch}"
