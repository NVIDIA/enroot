#! /usr/bin/env bash

# Copyright (c) 2018-2019, NVIDIA CORPORATION. All rights reserved.
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

# shellcheck disable=SC1090
source "${ENROOT_LIBRARY_PATH}/common.sh"

common::checkcmd grep find

readonly prefix="$(basename "${ENROOT_ROOTFS}" | grep -o "^[[:alnum:]_]\+")"

if [ -n "${prefix}" ]; then
    find . -maxdepth 1 -type f ! -empty \( -name "${prefix}.rc" -o -name "enroot.rc" \) -exec echo \
      {} /etc/rc none bind,x-create=file,nofail,silent \; \
      | enroot-mount --root "${ENROOT_ROOTFS}" -
fi
