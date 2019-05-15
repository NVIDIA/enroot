#! /bin/bash

# Copyright (c) 2018-2019, NVIDIA CORPORATION. All rights reserved.

set -euo pipefail
shopt -s lastpipe

if [ -z "${SLURM_JOB_ID-}" ] || [ -z "${SLURM_STEP_ID-}" ] || ! compgen -e "PMIX_" ; then
    exit 0
fi

# shellcheck disable=SC1090
source "${ENROOT_LIBRARY_PATH}/common.sh"

common::checkcmd scontrol awk

scontrol show config | awk '/^SlurmdSpoolDir|^TmpFS/ {print $3}' \
  | { read -r slurm_spool; read -r slurm_tmpfs; } || :

if [ -z "${slurm_spool}" ] || [ -z "${slurm_tmpfs}" ]; then
    common:err "Could not read SLURM configuration"
fi

for var in $(compgen -e "SLURM_"); do
    printf "%s=%s\n" "${var}" "${!var}" >> "${ENROOT_ENVIRON}"
done
for var in $(compgen -e "PMIX_"); do
    printf "%s=%s\n" "${var}" "${!var}" >> "${ENROOT_ENVIRON}"
done

if [ -n "${PMIX_PTL_MODULE-}" ]; then
    printf "PMIX_MCA_ptl=%s\n" ${PMIX_PTL_MODULE} >> "${ENROOT_ENVIRON}"
fi
if [ -n "${PMIX_SECURITY_MODE-}" ]; then
    printf "PMIX_MCA_psec=%s\n" ${PMIX_SECURITY_MODE} >> "${ENROOT_ENVIRON}"
fi
if [ -n "${PMIX_GDS_MODULE-}" ]; then
    printf "PMIX_MCA_gds=%s\n" ${PMIX_GDS_MODULE} >> "${ENROOT_ENVIRON}"
fi

cat << EOF | enroot-mount --root "${ENROOT_ROOTFS}" -
${slurm_tmpfs}/spmix_appdir_${SLURM_JOB_ID}.${SLURM_STEP_ID} ${slurm_tmpfs}/spmix_appdir_${SLURM_JOB_ID}.${SLURM_STEP_ID} none x-create=dir,bind,rw,nosuid,noexec,nodev
${slurm_spool}/pmix.${SLURM_JOB_ID}.${SLURM_STEP_ID} ${slurm_spool}/pmix.${SLURM_JOB_ID}.${SLURM_STEP_ID} none x-create=dir,bind,rw,nosuid,noexec,nodev
EOF
