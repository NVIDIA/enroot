#! /bin/bash

# Copyright (c) 2018-2019, NVIDIA CORPORATION. All rights reserved.

set -eu

if [ -z "${ENROOT_MOUNT_HOME-}" ]; then
    exit 0
fi

source "${ENROOT_LIBEXEC_PATH}/common.sh"

common::checkcmd getent

if [ -z "${HOME-}" ]; then
    export "HOME=$(common::getpwent | cut -d ':' -f6)"
fi

if [ -n "${ENROOT_REMAP_ROOT-}" ]; then
    "${ENROOT_LIBEXEC_PATH}/mountat" --root "${ENROOT_ROOTFS}" - <<< "${HOME} /root none x-create=dir,rbind,rw,nosuid"
else
    "${ENROOT_LIBEXEC_PATH}/mountat" --root "${ENROOT_ROOTFS}" - <<< "${HOME} ${HOME} none x-create=dir,rbind,rw,nosuid"
    printf "HOME=%s\n" "${HOME}" >> "${ENROOT_ENVIRON}"
fi
