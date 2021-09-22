#! /usr/bin/env bash

# Copyright (c) 2018-2021, NVIDIA CORPORATION. All rights reserved.
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

if ! grep -q "^PYTORCH_VERSION=" "${ENROOT_ENVIRON}"; then
    exit 0
fi

if [ -n "${SLURM_STEP_NODELIST-}" ] && ! grep -q "^MASTER_ADDR=" "${ENROOT_ENVIRON}" && command -v scontrol > /dev/null; then
    printf "MASTER_ADDR=%s\n" "$(scontrol show hostname "${SLURM_STEP_NODELIST}" | head -n1)" >> "${ENROOT_ENVIRON}"
fi
if [ -n "${SLURM_JOB_ID-}" ] && ! grep -q "^MASTER_PORT=" "${ENROOT_ENVIRON}"; then
    printf "MASTER_PORT=%s\n" "$((${SLURM_JOB_ID} % 16384 + 49152))" >> "${ENROOT_ENVIRON}"
fi
if [ -n "${SLURM_NTASKS-}" ] && ! grep -q "^WORLD_SIZE=" "${ENROOT_ENVIRON}"; then
    printf "WORLD_SIZE=%s\n" "${SLURM_NTASKS}" >> "${ENROOT_ENVIRON}"
fi
if [ -n "${SLURM_PROCID-}" ] && ! grep -q "^RANK=" "${ENROOT_ENVIRON}"; then
    printf "RANK=%s\n" "${SLURM_PROCID}" >> "${ENROOT_ENVIRON}"
fi
if [ -n "${SLURM_LOCALID-}" ] && ! grep -q "^LOCAL_RANK=" "${ENROOT_ENVIRON}"; then
    printf "LOCAL_RANK=%s\n" "${SLURM_LOCALID}" >> "${ENROOT_ENVIRON}"
fi

# Matching the behavior of torch.distributed.run: https://github.com/pytorch/pytorch/blob/v1.9.0/torch/distributed/run.py#L521-L532
if [ "${SLURM_NTASKS_PER_NODE:-1}" -gt 1 ] && ! grep -q "^OMP_NUM_THREADS=" "${ENROOT_ENVIRON}"; then
    printf "OMP_NUM_THREADS=1\n" >> "${ENROOT_ENVIRON}"
fi
