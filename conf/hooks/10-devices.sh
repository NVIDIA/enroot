#! /usr/bin/env bash

# Copyright (c) 2018-2020, NVIDIA CORPORATION. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu

if [ -z "${ENROOT_RESTRICT_DEV-}" ]; then
    exit 0
fi

source "${ENROOT_LIBRARY_PATH}/common.sh"

cat << EOF | enroot-mount --root "${ENROOT_ROOTFS}" -
none                    /dev            none    x-detach,nofail,silent
tmpfs                   /dev            tmpfs   x-create=dir,rw,nosuid,noexec,mode=755,slave
/dev/zero               /dev/zero       none    x-create=file,bind,rw,nosuid,noexec,private
/dev/null               /dev/null       none    x-create=file,bind,rw,nosuid,noexec,private
/dev/full               /dev/full       none    x-create=file,bind,rw,nosuid,noexec,private
/dev/urandom            /dev/urandom    none    x-create=file,bind,rw,nosuid,noexec,private
/dev/random             /dev/random     none    x-create=file,bind,rw,nosuid,noexec,private
devpts                  /dev/pts        devpts  x-create=dir,rw,nosuid,noexec,newinstance,ptmxmode=0666,mode=620,slave
/dev/tty                /dev/tty        none    x-create=file,bind,rw,nosuid,noexec,private
/dev/shm                /dev/shm        none    x-create=dir,bind,rw,nosuid,noexec,nodev,rslave
/dev/mqueue             /dev/mqueue     none    x-create=dir,bind,rw,nosuid,noexec,nodev,rslave
/dev/hugepages          /dev/hugepages  none    x-create=dir,bind,rw,nosuid,noexec,nodev,rslave,nofail,silent
/dev/log                /dev/log        none    x-create=file,bind,rw,nosuid,noexec,nodev,private
EOF

if [ -t 0 ]; then
    enroot-mount --root "${ENROOT_ROOTFS}" - <<< "$(common::realpath /dev/stdin) /dev/console none x-create=file,bind,rw,nosuid,noexec,private"
fi

ln -s "/proc/self/fd" "${ENROOT_ROOTFS}/dev/fd"
ln -s "/dev/pts/ptmx" "${ENROOT_ROOTFS}/dev/ptmx"
ln -s "/proc/self/fd/0" "${ENROOT_ROOTFS}/dev/stdin"
ln -s "/proc/self/fd/1" "${ENROOT_ROOTFS}/dev/stdout"
ln -s "/proc/self/fd/2" "${ENROOT_ROOTFS}/dev/stderr"
