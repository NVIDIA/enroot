#! /bin/bash

# Copyright (c) 2018-2019, NVIDIA CORPORATION. All rights reserved.

set -eu

# shellcheck disable=SC1090
source "${ENROOT_LIBRARY_PATH}/common.sh"

common::checkcmd awk getent sed grpck pwck flock

readonly nobody=$(< /proc/sys/kernel/overflowuid)
readonly nogroup=$(< /proc/sys/kernel/overflowgid)
readonly pwdent=$(common::getpwent)
readonly grpent=$(common::getgrent)

# Load the default shadow settings.
if [ -f "${ENROOT_ROOTFS}/etc/login.defs" ]; then
    # shellcheck disable=SC2046
    readonly $(awk '(NF && $1 !~ "^#"){ print "def_"$1"="$2 }' "${ENROOT_ROOTFS}/etc/login.defs")
fi
if [ -f "${ENROOT_ROOTFS}/etc/default/useradd" ]; then
    # shellcheck disable=SC2046
    readonly $(awk '(NF && $1 !~ "^#"){ print "def_"$1 }' "${ENROOT_ROOTFS}/etc/default/useradd")
fi

# Read the user/group database entries for the current user on the host.
# shellcheck disable=SC2034
IFS=':' read -r user x uid x gecos home shell <<< "${pwdent}"
# shellcheck disable=SC2034
IFS=':' read -r group x gid x <<< "${grpent}"

if [ ! -x "${ENROOT_ROOTFS}${shell}" ]; then
    shell="${def_SHELL:-/bin/sh}"
fi

(
    flock -w 5 "${pwdlock}" || common:err "Could not acquire passwd lock"
    flock -w 5 "${grplock}" || common:err "Could not acquire group lock"

    # Create new database files based on the ones present in the rootfs.
    cp -a "${ENROOT_ROOTFS}/etc/passwd" "${ENROOT_ROOTFS}/etc/passwd-"
    cp -a "${ENROOT_ROOTFS}/etc/group" "${ENROOT_ROOTFS}/etc/group-"

    # XXX On debian based distributions, remove the _apt user/group otherwise apt will try to drop privileges and fail.
    if [ -f "${ENROOT_ROOTFS}/etc/debian_version" ]; then
        sed -i '/^_apt:/d' "${ENROOT_ROOTFS}/etc/passwd-"
        sed -i '/^_apt:/d' "${ENROOT_ROOTFS}/etc/group-"
    fi

    # Generate user entries for root, nobody and the current user.
    cat <<- EOF >> "${ENROOT_ROOTFS}/etc/passwd-"
	root:x:0:0:root:/root:${shell}
	nobody:x:${nobody}:${nogroup}:nobody:/:/sbin/nologin
	${user}:x:${uid}:${gid}:${gecos}:${home}:${shell}
	EOF

    # Generate group entries for root, nobody and the current user.
    cat <<- EOF >> "${ENROOT_ROOTFS}/etc/group-"
	root:x:0:
	nogroup:x:${nogroup}:
	${group}:x:${gid}:
	EOF

    # Check and install the new group database making sure our generated groups come first.
    yes | grpck -R "${ENROOT_ROOTFS}" /etc/group- > /dev/null 2>&1 || :
    tail -n -3 "${ENROOT_ROOTFS}/etc/group-" > "${ENROOT_ROOTFS}/etc/group"
    head -n -3 "${ENROOT_ROOTFS}/etc/group-" >> "${ENROOT_ROOTFS}/etc/group"

    # Check and install the new user database making sure our generated users come first.
    yes | pwck -R "${ENROOT_ROOTFS}" /etc/passwd- > /dev/null 2>&1 || :
    tail -n -3 "${ENROOT_ROOTFS}/etc/passwd-" > "${ENROOT_ROOTFS}/etc/passwd"
    head -n -3 "${ENROOT_ROOTFS}/etc/passwd-" >> "${ENROOT_ROOTFS}/etc/passwd"

    rm -f "${ENROOT_ROOTFS}/etc/group-"* "${ENROOT_ROOTFS}/etc/passwd-"*

) {pwdlock}>> "${ENROOT_ROOTFS}/etc/passwd" {grplock}>> "${ENROOT_ROOTFS}/etc/group"

# Create the user home directory if it doesn't exist and populate it with the content of the skeleton directory.
if [ ! -e "${ENROOT_ROOTFS}${home}" ] && [ "${def_CREATE_HOME:-yes}" = "yes" ]; then
    ( umask "${def_UMASK:-077}" && mkdir -p "${ENROOT_ROOTFS}${home}" )
    skel="${def_SKEL:-/etc/skel}"
    if [ -d "${ENROOT_ROOTFS}${skel}" ]; then
        cp -a "${ENROOT_ROOTFS}${skel}/." "${ENROOT_ROOTFS}${home}"
    fi
fi

# Create the user mailbox if it doesn't exist.
if [ "${def_CREATE_MAIL_SPOOL:-no}" = "yes" ]; then
    maildir="${def_MAIL_DIR:-/var/mail}"
    if [ ! -e "${ENROOT_ROOTFS}${maildir}/${user}" ]; then
        mkdir -p "${ENROOT_ROOTFS}${maildir}"
        ( umask 007 && touch "${ENROOT_ROOTFS}${maildir}/${user}" )
    fi
fi
