#! /bin/bash

# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

set -eu

source "${ENROOT_LIBEXEC_PATH}/common.sh"

#readonly NVIDIA_DEBUG_LOG=1
readonly LDCONFIG_PATH="@$(command -v ldconfig.real || command -v ldconfig)"

CLI_ARGS=("--no-cgroups" "--ldconfig=${LDCONFIG_PATH}")

# https://github.com/nvidia/nvidia-container-runtime#nvidia_visible_devices
if [ -z "${NVIDIA_VISIBLE_DEVICES-}" ] || [ "${NVIDIA_VISIBLE_DEVICES-}" = "void" ]; then
    exit 0
fi
if [ "${NVIDIA_VISIBLE_DEVICES}" != "none" ]; then
    CLI_ARGS+=("--device=${NVIDIA_VISIBLE_DEVICES}")
fi

# https://github.com/nvidia/nvidia-container-runtime#nvidia_driver_capabilities
if [ -z "${NVIDIA_DRIVER_CAPABILITIES-}" ]; then
    NVIDIA_DRIVER_CAPABILITIES="utility"
fi
for cap in ${NVIDIA_DRIVER_CAPABILITIES//,/ }; do
    case "${cap}" in
    all)
        CLI_ARGS+=("--compute" "--compat32" "--display" "--graphics" "--utility" "--video")
        break
        ;;
    compute|compat32|display|graphics|utility|video)
        CLI_ARGS+=("--${cap}")
        ;;
    *)
        err "Unknown NVIDIA driver capability: ${cap}"
        ;;
    esac
done

# https://github.com/nvidia/nvidia-container-runtime#nvidia_require_
if [ -z "${NVIDIA_DISABLE_REQUIRE:-}" ]; then
    for req in $(compgen -e "NVIDIA_REQUIRE_"); do
        CLI_ARGS+=("--require=${!req}")
    done
fi

if ! command -v nvidia-container-cli > /dev/null; then
    err "Command not found: nvidia-container-cli, see https://github.com/NVIDIA/libnvidia-container"
fi
if ! grep -q nvidia_uvm /proc/modules; then
    log WARN "Kernel module nvidia_uvm is not loaded. Make sure the NVIDIA device driver is installed and loaded."
fi

exec nvidia-container-cli --user ${NVIDIA_DEBUG_LOG+--debug=/dev/stderr} configure "${CLI_ARGS[@]}" "${ENROOT_ROOTFS}"
