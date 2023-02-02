#! /usr/bin/env bash

# Copyright (c) 2018-2023, NVIDIA CORPORATION. All rights reserved.
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
shopt -s lastpipe

while IFS=':' read -r x ctrl path; do
    if [ -n "${ctrl}" ]; then
        grep -m1 "\- cgroup cgroup [^ ]*${ctrl}"
    else
        grep -m1 "\- cgroup2 cgroup"
    fi < /proc/self/mountinfo | { IFS=' ' read -r x x x root mount x || :; }

    if [ -n "${root}" ] && [ -n "${mount}" ]; then
        printf "%s %s none x-create=dir,rbind,nosuid,noexec,nodev,ro\n" "${mount}/${path#${root}}" "${mount}" >> "${ENROOT_MOUNTS}"
    fi
done < /proc/self/cgroup

printf "none /sys/fs/cgroup none rbind,remount,nosuid,noexec,nodev,ro,rslave,nofail,silent\n" >> "${ENROOT_MOUNTS}"
