#! /bin/bash

# Copyright (c) 2018-2019, NVIDIA CORPORATION. All rights reserved.

set -eu

# shellcheck disable=SC1090
source "${ENROOT_LIBEXEC_PATH}/common.sh"

common::checkcmd grep find

readonly prefix="$(basename "${ENROOT_ROOTFS}" | grep -o "^[[:alnum:]_]\+")"

if [ -n "${prefix}" ]; then
    find . -maxdepth 1 -type f ! -empty \( -name "${prefix}.rc" -o -name "enroot.rc" \) -exec echo \
      {} /etc/rc none bind,x-create=file,nofail,silent \; \
      | enroot-mount --root "${ENROOT_ROOTFS}" -
fi
