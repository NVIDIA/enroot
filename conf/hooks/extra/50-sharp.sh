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

set -euo pipefail
shopt -s lastpipe

source "${ENROOT_LIBRARY_PATH}/common.sh"

common::checkcmd awk

tac "${ENROOT_ENVIRON}" | grep "^MELLANOX_" | while IFS='=' read -r key value; do
    [ -v "${key}" ] || export "${key}=${value}"
done || :

if [ "${MELLANOX_VISIBLE_DEVICES:-void}" = "void" ] || [ "${MELLANOX_VISIBLE_DEVICES}" = "none" ]; then
    exit 0
fi

if [ "${SLURM_NETWORK:-}" != "sharp" ]; then
    exit 0
fi

# Disable SHARP lazy locking and initialization.
# https://docs.mellanox.com/display/sharpv214/Mellanox+SHARP+Collective+Library
if ! grep -q "^SHARP_COLL_LOCK_ON_COMM_INIT=" "${ENROOT_ENVIRON}"; then
    printf "SHARP_COLL_LOCK_ON_COMM_INIT=1\n" >> "${ENROOT_ENVIRON}"
fi
if ! grep -q "^SHARP_COLL_NUM_COLL_GROUP_RESOURCE_ALLOC_THRESHOLD=" "${ENROOT_ENVIRON}"; then
    printf "SHARP_COLL_NUM_COLL_GROUP_RESOURCE_ALLOC_THRESHOLD=0\n" >> "${ENROOT_ENVIRON}"
fi

# https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html#nccl-collnet-enable
if ! grep -q "^NCCL_COLLNET_ENABLE=" "${ENROOT_ENVIRON}"; then
    printf "NCCL_COLLNET_ENABLE=1\n" >> "${ENROOT_ENVIRON}"
fi

if [ -n "${SLURM_STEP_NUM_NODES-}" ] && ! grep -q "^NCCL_SHARP_GROUP_SIZE_THRESH=" "${ENROOT_ENVIRON}"; then
    printf "NCCL_SHARP_GROUP_SIZE_THRESH=%s\n" "${SLURM_STEP_NUM_NODES}" >> "${ENROOT_ENVIRON}"
fi
if [ -n "${OMPI_MCA_orte_num_nodes-}" ] && ! grep -q "^NCCL_SHARP_GROUP_SIZE_THRESH=" "${ENROOT_ENVIRON}"; then
    printf "NCCL_SHARP_GROUP_SIZE_THRESH=%s\n" "${OMPI_MCA_orte_num_nodes}" >> "${ENROOT_ENVIRON}"
fi
