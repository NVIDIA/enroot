#! /bin/bash

# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

set -eu

xfakeroot() {
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/\$LIB/libfakeroot:/usr/\$LIB/libfakeroot" \
    LD_PRELOAD="${LD_PRELOAD:+LD_PRELOAD:}libfakeroot-sysv.so" \
    "$@"
}

xfakeroot mount -n -t tmpfs -o mode=644 tmpfs /mnt
trap "xfakeroot umount /mnt" EXIT

{ getent passwd "${EUID}" "$(< /proc/sys/kernel/overflowuid)" || true; } > /mnt/passwd
{ getent group "$(id -g ${EUID})" "$(< /proc/sys/kernel/overflowgid)" || true; } > /mnt/group

touch "${ENROOT_ROOTFS}/etc/passwd" "${ENROOT_ROOTFS}/etc/group"

xfakeroot mount -n --bind /mnt/passwd "${ENROOT_ROOTFS}/etc/passwd"
xfakeroot mount -n --bind /mnt/group "${ENROOT_ROOTFS}/etc/group"
xfakeroot mount -n -o bind,remount,nosuid,noexec,nodev,ro "${ENROOT_ROOTFS}/etc/passwd"
xfakeroot mount -n -o bind,remount,nosuid,noexec,nodev,ro "${ENROOT_ROOTFS}/etc/group"
