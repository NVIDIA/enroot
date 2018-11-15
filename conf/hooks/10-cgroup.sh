#! /bin/bash

# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

set -eu
shopt -s lastpipe

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

    echo "${mount}/${path#${root}} ${mount} none x-create=dir,bind,nosuid,noexec,nodev,ro" \
      | mountat --root "${ENROOT_ROOTFS}" -
}

while read line; do
    mount_cgroup "${line}"
done < /proc/self/cgroup

echo "none /sys/fs/cgroup none bind,remount,nosuid,noexec,nodev,ro" | mountat --root "${ENROOT_ROOTFS}" -
