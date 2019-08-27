#! /bin/bash

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

set -euo pipefail
shopt -s lastpipe

export PATH="${PATH}:/usr/sbin:/sbin"

# shellcheck disable=SC1090
source "${ENROOT_LIBRARY_PATH}/common.sh"

common::checkcmd grep ldconfig

tac "${ENROOT_ENVIRON}" | grep "^NVIDIA_" | while IFS='=' read -r key value; do
    # shellcheck disable=SC2163
    [ -v "${key}" ] || export "${key}=${value}"
done || :

cli_args=("--no-cgroups" "--ldconfig=@$(command -v ldconfig.real || command -v ldconfig)")

# https://github.com/nvidia/nvidia-container-runtime#nvidia_visible_devices
if [ "${NVIDIA_VISIBLE_DEVICES:-void}" = "void" ]; then
    exit 0
fi
if [ "${NVIDIA_VISIBLE_DEVICES}" != "none" ]; then
    cli_args+=("--device=${NVIDIA_VISIBLE_DEVICES}")
fi

# https://github.com/nvidia/nvidia-container-runtime#nvidia_driver_capabilities
if [ -z "${NVIDIA_DRIVER_CAPABILITIES-}" ]; then
    NVIDIA_DRIVER_CAPABILITIES="utility"
fi
for cap in ${NVIDIA_DRIVER_CAPABILITIES//,/ }; do
    case "${cap}" in
    all)
        cli_args+=("--compute" "--compat32" "--display" "--graphics" "--utility" "--video")
        break
        ;;
    compute|compat32|display|graphics|utility|video)
        cli_args+=("--${cap}") ;;
    *)
        common::err "Unknown NVIDIA driver capability: ${cap}" ;;
    esac
done

# https://github.com/nvidia/nvidia-container-runtime#nvidia_require_
if [ -z "${NVIDIA_DISABLE_REQUIRE-}" ]; then
    for req in $(compgen -e "NVIDIA_REQUIRE_"); do
        cli_args+=("--require=${!req}")
    done
fi

if ! command -v nvidia-container-cli > /dev/null; then
    common::err "Command not found: nvidia-container-cli, see https://github.com/NVIDIA/libnvidia-container"
fi
if ! grep -q nvidia_uvm /proc/modules; then
    common::log WARN "Kernel module nvidia_uvm is not loaded. Make sure the NVIDIA device driver is installed and loaded."
fi

exec nvidia-container-cli --user ${NVIDIA_DEBUG_LOG+--debug=/dev/stderr} configure "${cli_args[@]}" "${ENROOT_ROOTFS}"
