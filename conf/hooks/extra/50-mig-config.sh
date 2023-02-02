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

source "${ENROOT_LIBRARY_PATH}/common.sh"

common::checkcmd grep

tac "${ENROOT_ENVIRON}" | grep "^NVIDIA_" | while IFS='=' read -r key value; do
    [ -v "${key}" ] || export "${key}=${value}"
done || :

if [ "${NVIDIA_VISIBLE_DEVICES:-void}" = "void" ] || [ "${NVIDIA_VISIBLE_DEVICES}" = "none" ]; then
    exit 0
fi
if [[ "${NVIDIA_VISIBLE_DEVICES}" =~ "MIG-" ]] || [[ "${NVIDIA_VISIBLE_DEVICES}" =~ .:. ]]; then
    exit 0
fi

common::checkcmd nvidia-smi

nvsmi_args=("--query-gpu=mig.mode.current" "--format=csv,noheader")

if [ "${NVIDIA_VISIBLE_DEVICES}" != "all" ]; then
    nvsmi_args+=("-i" "${NVIDIA_VISIBLE_DEVICES}")
fi

if nvidia-smi "${nvsmi_args[@]}" | grep -q "Enabled"; then
    echo "NVIDIA_MIG_CONFIG_DEVICES=all" >> "${ENROOT_ENVIRON}"
fi
