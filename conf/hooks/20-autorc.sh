#! /bin/bash

# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

set -eu

readonly prefix="$(basename "${ENROOT_ROOTFS}" | grep -o "^[[:alnum:]_-]\+")"

if [ -n "${prefix}" ]; then
    find -maxdepth 1 -type f ! -empty -name "${prefix}.rc" -exec echo \
      {} /etc/rc none bind,x-create=file,nofail,silent \; \
      | "${ENROOT_LIBEXEC_PATH}/mountat" --root "${ENROOT_ROOTFS}" -
fi
