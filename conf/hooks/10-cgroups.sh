#! /bin/bash

# Copyright (c) 2018-2019, NVIDIA CORPORATION. All rights reserved.

set -eu
shopt -s lastpipe

while IFS=':' read -r x ctrl path; do
    if [ -n "${ctrl}" ]; then
        grep -m1 "\- cgroup cgroup [^ ]*${ctrl}"
    else
        grep -m1 "\- cgroup2 cgroup"
    fi < /proc/self/mountinfo | { IFS=' ' read -r x x x root mount x || :; }

    if [ -n "${root}" ] && [ -n "${mount}" ]; then
        enroot-mount --root "${ENROOT_ROOTFS}" - <<< \
          "${mount}/${path#${root}} ${mount} none x-create=dir,bind,nosuid,noexec,nodev,ro"
    fi
done < /proc/self/cgroup

enroot-mount --root "${ENROOT_ROOTFS}" - <<< "none /sys/fs/cgroup none bind,remount,nosuid,noexec,nodev,ro"
