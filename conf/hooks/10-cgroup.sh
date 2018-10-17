#! /bin/bash

# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

set -eu
shopt -s lastpipe

xfakeroot() {
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/\$LIB/libfakeroot:/usr/\$LIB/libfakeroot" \
    LD_PRELOAD="${LD_PRELOAD:+LD_PRELOAD:}libfakeroot-sysv.so" \
    "$@"
}

mount_cgroup() {
    local -r line="$1"

    local ctrl=""
    local path=""
    local mtab=""
    local root=""
    local mount=""

    cut -d: -f2,3 <<< "${line}" | IFS=':' read -r ctrl path
    if [ -n "${ctrl}" ]; then
        mtab=$(grep -m1 "\- cgroup cgroup [^ ]*${ctrl}" /proc/self/mountinfo || true)
    else
        mtab=$(grep -m1 "\- cgroup2 cgroup" /proc/self/mountinfo || true)
    fi
    if [ -z "${mtab}" ]; then
        return
    fi
    cut -d' ' -f4,5 <<< "${mtab}" | IFS=' ' read -r root mount

    mkdir -p "${ENROOT_ROOTFS}/${mount:1}"
    xfakeroot mount -n --bind "${mount}/${path#${root}}" "${ENROOT_ROOTFS}/${mount:1}"
    xfakeroot mount -n -o bind,remount,nosuid,noexec,nodev,ro "${ENROOT_ROOTFS}/${mount:1}"
}

while read line; do
    mount_cgroup "${line}"
done < /proc/self/cgroup

xfakeroot mount -n -o bind,remount,nosuid,noexec,nodev,ro "${ENROOT_ROOTFS}/sys/fs/cgroup"
