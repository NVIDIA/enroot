#! /bin/bash

# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

set -eu

{ getent passwd "${EUID}" "$(< /proc/sys/kernel/overflowuid)" || :; } > "${ENROOT_WORKDIR}/passwd"
{ getent group "$(id -g ${EUID})" "$(< /proc/sys/kernel/overflowgid)" || :; } > "${ENROOT_WORKDIR}/group"

cat << EOF | "${ENROOT_LIBEXEC_PATH}/mountat" --root "${ENROOT_ROOTFS}" -
${ENROOT_WORKDIR}/passwd /etc/passwd none x-create=file,bind,nosuid,noexec,nodev,ro
${ENROOT_WORKDIR}/group /etc/group none x-create=file,bind,nosuid,noexec,nodev,ro
EOF
