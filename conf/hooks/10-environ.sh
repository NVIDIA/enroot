#! /bin/bash

# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

set -eu

readonly USERNAME=$(awk '{ system("getent passwd " $2) }' /proc/self/uid_map | cut -d: -f1)

if [ -z "${LOGNAME-}" ]; then
    echo "LOGNAME=${USERNAME}" >> "${ENROOT_ENVIRON}"
fi

if [ -z "${USER-}" ]; then
    if [ "${EUID}" -eq 0 ]; then
        echo "USER=root" >> "${ENROOT_ENVIRON}"
    else
        echo "USER=${USERNAME}" >> "${ENROOT_ENVIRON}"
    fi
fi

if [ -z "${HOME-}" ]; then
    if [ "${EUID}" -eq 0 ]; then
        echo "HOME=/root" >> "${ENROOT_ENVIRON}"
    else
        eval echo "HOME=~${USERNAME}" >> "${ENROOT_ENVIRON}"
    fi
fi
