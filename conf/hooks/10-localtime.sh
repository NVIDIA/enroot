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

if [ ! -L /etc/localtime ] ; then
    exit 0
fi

source "${ENROOT_LIBRARY_PATH}/common.sh"

cp --no-dereference --preserve=links /etc/localtime "${ENROOT_ROOTFS}/etc/localtime"
target="$(common::realpath /etc/localtime)"
if [ ! -e "${ENROOT_ROOTFS}${target}" ] ; then
    mkdir --parents "${ENROOT_ROOTFS}$(dirname "${target}")"
    cp "${target}" "${ENROOT_ROOTFS}${target}"
fi
