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
declare -a issms=()
declare -a umads=()
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

# Lookup all the management devices.
for uevent in /sys/bus/pci/drivers/mlx?_core/*/infiniband_mad/*/uevent; do
    case "${uevent}" in
    *issm*) issms+=("$(. "${uevent}"; echo "/dev/${DEVNAME}")") ;;
    *umad*) umads+=("$(. "${uevent}"; echo "/dev/${DEVNAME}")") ;;
    *) continue ;;
    esac
done

# Hide all the device entries in sysfs by default and mount RDMA CM.
cat << EOF | enroot-mount --root "${ENROOT_ROOTFS}" -
tmpfs /sys/class/infiniband tmpfs nosuid,noexec,nodev,mode=755,private
tmpfs /sys/class/infiniband_verbs tmpfs nosuid,noexec,nodev,mode=755,private
tmpfs /sys/class/infiniband_cm tmpfs nosuid,noexec,nodev,mode=755,private,nofail,silent
tmpfs /sys/class/infiniband_mad tmpfs nosuid,noexec,nodev,mode=755,private
/sys/class/infiniband_verbs/abi_version /sys/class/infiniband_verbs/abi_version none x-create=file,bind,ro,nosuid,noexec,nodev,private
/sys/class/infiniband_cm/abi_version /sys/class/infiniband_cm/abi_version none x-create=file,bind,ro,nosuid,noexec,nodev,private,nofail,silent
/sys/class/infiniband_mad/abi_version /sys/class/infiniband_mad/abi_version none x-create=file,bind,ro,nosuid,noexec,nodev,private
/dev/infiniband/rdma_cm /dev/infiniband/rdma_cm none x-create=file,bind,ro,nosuid,noexec,private
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

    if [ -n "${ENROOT_ALLOW_SUPERUSER-}" ] && [ "$(awk '{print $2}' /proc/self/uid_map)" -eq 0 ]; then
        enroot-mount --root "${ENROOT_ROOTFS}" - <<< "${umads[id]} ${umads[id]} none x-create=file,bind,ro,nosuid,noexec,private,nofail,silent"
        enroot-mount --root "${ENROOT_ROOTFS}" - <<< "${issms[id]} ${issms[id]} none x-create=file,bind,ro,nosuid,noexec,private,nofail,silent"
        ln -s "$(common::realpath "/sys/class/infiniband_mad/${umads[id]##*/}")" "${ENROOT_ROOTFS}/sys/class/infiniband_mad/${umads[id]##*/}"
        ln -s "$(common::realpath "/sys/class/infiniband_mad/${issms[id]##*/}")" "${ENROOT_ROOTFS}/sys/class/infiniband_mad/${issms[id]##*/}"
    fi
done
