#! /bin/bash

# Copyright (c) 2018-2019, NVIDIA CORPORATION. All rights reserved.

set -eu

if [ -z "${ENROOT_RESTRICT_DEV-}" ]; then
    exit 0
fi

cat << EOF | "${ENROOT_LIBEXEC_PATH}/mountat" --root "${ENROOT_ROOTFS}" -
none                    /dev            none    x-detach,nofail,silent
tmpfs                   /dev            tmpfs   x-create=dir,rw,nosuid,noexec,mode=755
/dev/zero               /dev/zero       none    x-create=file,bind,rw,nosuid,noexec
/dev/null               /dev/null       none    x-create=file,bind,rw,nosuid,noexec
/dev/full               /dev/full       none    x-create=file,bind,rw,nosuid,noexec
/dev/urandom            /dev/urandom    none    x-create=file,bind,rw,nosuid,noexec
/dev/random             /dev/random     none    x-create=file,bind,rw,nosuid,noexec
/dev/pts                /dev/pts        none    x-create=dir,bind,rw,nosuid,noexec
/dev/ptmx               /dev/ptmx       none    x-create=file,bind,rw,nosuid,noexec
/dev/console            /dev/console    none    x-create=file,bind,rw,nosuid,noexec
/dev/shm                /dev/shm        none    x-create=dir,bind,rw,nosuid,noexec,nodev
/dev/mqueue             /dev/mqueue     none    x-create=dir,bind,rw,nosuid,noexec,nodev
/dev/hugepages          /dev/hugepages  none    x-create=dir,bind,rw,nosuid,noexec,nodev,nofail,silent
/dev/log                /dev/log        none    x-create=file,bind,rw,nosuid,noexec,nodev
/proc/${ENROOT_PID}/fd  /dev/fd         none    x-create=dir,bind,rw,nosuid,noexec,nodev
EOF

ln -s "/proc/self/fd/0" "${ENROOT_ROOTFS}/dev/stdin"
ln -s "/proc/self/fd/1" "${ENROOT_ROOTFS}/dev/stdout"
ln -s "/proc/self/fd/2" "${ENROOT_ROOTFS}/dev/stderr"
