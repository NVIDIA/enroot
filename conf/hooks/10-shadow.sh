#! /bin/bash

# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

set -eu

{ getent passwd "${EUID}" "$(< /proc/sys/kernel/overflowuid)" || :; } > "${ENROOT_RUNTIME_PATH}/passwd"
{ getent group "$(id -g ${EUID})" "$(< /proc/sys/kernel/overflowgid)" || :; } > "${ENROOT_RUNTIME_PATH}/group"

cat << EOF | "${ENROOT_LIBEXEC_PATH}/mountat" --root "${ENROOT_ROOTFS}" -
${ENROOT_RUNTIME_PATH}/passwd /etc/passwd none x-create=file,bind,nosuid,noexec,nodev,ro
${ENROOT_RUNTIME_PATH}/group /etc/group none x-create=file,bind,nosuid,noexec,nodev,ro
EOF
