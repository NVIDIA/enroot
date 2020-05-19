#! /usr/bin/env bash

# Copyright (c) 2018-2020, NVIDIA CORPORATION. All rights reserved.

set -euo pipefail
shopt -s lastpipe nullglob

export PATH="${PATH}:/usr/sbin:/sbin"

source "${ENROOT_LIBRARY_PATH}/common.sh"

common::checkcmd grep awk ldd ldconfig

tac "${ENROOT_ENVIRON}" | grep "^MELLANOX_" | while IFS='=' read -r key value; do
    [ -v "${key}" ] || export "${key}=${value}"
done || :

if [ "${MELLANOX_VISIBLE_DEVICES:-void}" = "void" ] || [ "${MELLANOX_VISIBLE_DEVICES}" = "none" ]; then
    exit 0
fi
: ${MELLANOX_CONFIG_DIR:=/etc/libibverbs.d}

declare -a drivers=()
declare -a devices=()
declare -a ifaces=()
declare -A providers=()

# Lookup all the devices and their respective driver.
for uevent in /sys/bus/pci/drivers/mlx?_core/*/infiniband_verbs/*/uevent; do
    case "${uevent}" in
    *mlx4*) drivers+=("mlx4") ;;
    *mlx5*) drivers+=("mlx5") ;;
    *) continue ;;
    esac
    devices+=("$(. "${uevent}"; echo "/dev/${DEVNAME}")")
done

# Lookup all the interfaces.
for uevent in /sys/bus/pci/drivers/mlx?_core/*/infiniband/*/uevent; do
    ifaces+=("$(. "${uevent}"; echo "${NAME}")")
done

# Hide all the device entries in sysfs by default.
cat << EOF | enroot-mount --root "${ENROOT_ROOTFS}" -
tmpfs /sys/class/infiniband tmpfs nosuid,noexec,nodev,mode=755,private
tmpfs /sys/class/infiniband_verbs tmpfs nosuid,noexec,nodev,mode=755,private
/sys/class/infiniband_verbs/abi_version /sys/class/infiniband_verbs/abi_version none x-create=file,bind,ro,nosuid,noexec,nodev,private
EOF

# Mount all the visible devices specified.
if [ "${MELLANOX_VISIBLE_DEVICES}" = "all" ]; then
    MELLANOX_VISIBLE_DEVICES="$(seq -s, 0 $((${#devices[@]} - 1)))"
fi
for id in ${MELLANOX_VISIBLE_DEVICES//,/ }; do
    if [[ ! "${id}" =~ ^[[:digit:]]+$ ]] || [ "${id}" -lt 0 ] || [ "${id}" -ge "${#devices[@]}" ]; then
        common::err "Unknown MELLANOX device id: ${id}"
    fi
    providers["${drivers[id]}"]=true
    enroot-mount --root "${ENROOT_ROOTFS}" - <<< "${devices[id]} ${devices[id]} none x-create=file,bind,ro,nosuid,noexec,private"
    ln -s "$(common::realpath "/sys/class/infiniband/${ifaces[id]}")" "${ENROOT_ROOTFS}/sys/class/infiniband/${ifaces[id]}"
    ln -s "$(common::realpath "/sys/class/infiniband_verbs/${devices[id]##*/}")" "${ENROOT_ROOTFS}/sys/class/infiniband_verbs/${devices[id]##*/}"
done

if [ -z "${MELLANOX_MOUNT_DRIVER-}" ]; then
    exit 0
fi

# Debian and its derivatives use a multiarch directory scheme.
if [ -f "${ENROOT_ROOTFS}/etc/debian_version" ]; then
    : ${MELLANOX_PROVIDER_DIR:=/usr/lib/$(uname -m)-linux-gnu/libibverbs}
    readonly libdir="/usr/local/lib/$(uname -m)-linux-gnu/mellanox"
else
    : ${MELLANOX_PROVIDER_DIR:=/usr/lib64/libibverbs}
    readonly libdir="/usr/local/lib64/mellanox"
fi
mkdir -p "${ENROOT_ROOTFS}/${libdir}"

for provider in "${!providers[@]}"; do
    # Find each driver by reading its provider config.
    if [ ! -f "${MELLANOX_CONFIG_DIR}/${provider}.driver" ]; then
        common::err "Provider config not found: ${provider}"
    fi
    read -r x driver < "${MELLANOX_CONFIG_DIR}/${provider}.driver"
    if [ -z "${driver}" ]; then
        common::err "Could not parse provider config: ${MELLANOX_CONFIG_DIR}/${provider}.driver"
    fi
    if [[ "${driver}" != /* ]]; then
        driver="${MELLANOX_PROVIDER_DIR}/lib${driver}"
    fi

    # Mount a copy of the provider config with a different driver path.
    printf "driver %s\n" "${libdir}/${driver##*/}" > "${ENROOT_RUNTIME_PATH}/${provider}.driver"
    printf "%s %s none x-create=file,bind,ro,nosuid,nodev,noexec,private\n" "${ENROOT_RUNTIME_PATH}/${provider}.driver" "${MELLANOX_CONFIG_DIR}/${provider}.driver"

    # Mount the latest driver (PABI).
    driver="$(set -- "" "${driver}"-*.so; echo "${@: -1}")"
    if [ -z "${driver}" ]; then
        common::err "Provider driver not found: ${provider}"
    fi
    printf "%s %s none x-create=file,bind,ro,nosuid,nodev,private\n" "${driver}" "${libdir}/${driver##*/}"

    # Mount all the driver dependencies (except glibc).
    for lib in $(ldd "${driver}" | awk '($1 !~ /^(.*ld-linux.*|linux-vdso|libc|libpthread|libdl|libm)\.so/){ print $3 }'); do
        soname="${lib##*/}"
        printf "%s %s none x-create=file,bind,ro,nosuid,nodev,private\n" "$(common::realpath "${lib}")" "${libdir}/${soname}"
        ln -f -s -r "${ENROOT_ROOTFS}/${libdir}/${soname}" "${ENROOT_ROOTFS}/${libdir}/${soname%.so*}.so"
    done

    # Create a configuration for the dynamic linker.
    if [ ! -s "${ENROOT_ROOTFS}/etc/ld.so.conf" ]; then
        printf "include /etc/ld.so.conf.d/*.conf\n" > "${ENROOT_RUNTIME_PATH}/ld.so.conf"
        printf "%s %s none x-create=file,bind,ro,nosuid,nodev,noexec,private\n" "${ENROOT_RUNTIME_PATH}/ld.so.conf" "/etc/ld.so.conf"
    fi
    printf "%s\n" "${libdir}" > "${ENROOT_RUNTIME_PATH}/00-mellanox.conf"
    printf "%s %s none x-create=file,bind,ro,nosuid,nodev,noexec,private\n" "${ENROOT_RUNTIME_PATH}/00-mellanox.conf" "/etc/ld.so.conf.d/00-mellanox.conf"
done | sort -u | enroot-mount --root "${ENROOT_ROOTFS}" -

# Refresh the dynamic linker cache.
ldconfig="$(set -- "" "${ENROOT_ROOTFS}"/sbin/ldconfig*; echo "${@: -1}")"
if ! ${ldconfig:-ldconfig} -r "${ENROOT_ROOTFS}" > /dev/null 2>&1; then
    common::err "Failed to refresh the dynamic linker cache"
fi

# If ibv_devices is present on the host, use it. The purpose of this is twofold:
# We can perform relocations and check for any missing library or symbol.
# This will check the uverbs ABI of each visible device.
if cmd=$(command -v ibv_devices); then
    exec {fd}<"${cmd}"
    if ! chroot "${ENROOT_ROOTFS}" ldd -r "/proc/self/fd/${fd}" 2> /dev/null | grep -qvE '(not found|undefined symbol)'; then
        common::err "Driver incompatibility detected"
    fi
    chroot "${ENROOT_ROOTFS}" "/proc/self/fd/${fd}" 2>&1 > /dev/null | common::log WARN -
    exec {fd}>&-
fi
