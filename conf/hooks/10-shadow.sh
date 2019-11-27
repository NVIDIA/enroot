#! /usr/bin/env bash

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

set -eu

export PATH="${PATH}:/usr/sbin:/sbin"

source "${ENROOT_LIBRARY_PATH}/common.sh"

common::checkcmd awk getent sed grpck pwck

readonly nobody=$(< /proc/sys/kernel/overflowuid)
readonly nogroup=$(< /proc/sys/kernel/overflowgid)
readonly pwdent=$(common::getpwent)
readonly grpent=$(common::getgrent)

# Load the default shadow settings.
if [ -f "${ENROOT_ROOTFS}/etc/login.defs" ]; then
    declare $(awk '(NF && $1 !~ "^#"){ print "def_"$1"="$2 }' "${ENROOT_ROOTFS}/etc/login.defs")
fi
if [ -f "${ENROOT_ROOTFS}/etc/default/useradd" ]; then
    declare $(awk '(NF && $1 !~ "^#"){ print "def_"$1 }' "${ENROOT_ROOTFS}/etc/default/useradd")
fi

# Read the user/group database entries for the current user on the host.
IFS=':' read -r user x uid x gecos home shell <<< "${pwdent}"
IFS=':' read -r group x gid x <<< "${grpent}"

if [ ! -x "${ENROOT_ROOTFS}${shell}" ]; then
    shell="${def_SHELL:-/bin/sh}"
fi

touch "${ENROOT_ROOTFS}/etc/passwd" "${ENROOT_ROOTFS}/etc/group"
pwddb=$(mktemp -p "${ENROOT_ROOTFS}/etc" .passwd.XXXXXX)
grpdb=$(mktemp -p "${ENROOT_ROOTFS}/etc" .group.XXXXXX)
trap "rm -f '${pwddb}' '${grpdb}'" EXIT

# Generate passwd and group entries for root, nobody and the current user.
# XXX Remove the _apt user/group otherwise apt will try to drop privileges and fail.
sed '/^_apt:/d' "${ENROOT_ROOTFS}/etc/passwd" - << EOF >> "${pwddb}"
root:x:0:0:root:/root:${shell}
nobody:x:${nobody}:${nogroup}:nobody:/:/sbin/nologin
${user}:x:${uid}:${gid}:${gecos}:${home}:${shell}
EOF

sed '/^_apt:/d' "${ENROOT_ROOTFS}/etc/group" - << EOF >> "${grpdb}"
root:x:0:
nogroup:x:${nogroup}:
${group}:x:${gid}:
EOF

# Check and install the new databases making sure our generated entries come first.
yes 2> /dev/null | grpck -R "${ENROOT_ROOTFS}" "${grpdb#${ENROOT_ROOTFS}}" /etc/gshadow > /dev/null 2>&1 || :
{ tail -n -3 "${grpdb}"; head -n -3 "${grpdb}"; } > "${grpdb}-" && mv "${grpdb}-" "${grpdb}"
mv "${grpdb}" "${ENROOT_ROOTFS}/etc/group"

yes 2> /dev/null | pwck -R "${ENROOT_ROOTFS}" "${pwddb#${ENROOT_ROOTFS}}" /etc/shadow > /dev/null 2>&1 || :
{ tail -n -3 "${pwddb}"; head -n -3 "${pwddb}"; } > "${pwddb}-" && mv "${pwddb}-" "${pwddb}"
mv "${pwddb}" "${ENROOT_ROOTFS}/etc/passwd"

# Create the user home directory if it doesn't exist and populate it with the content of the skeleton directory.
if [ ! -e "${ENROOT_ROOTFS}${home}" ] && [ "${def_CREATE_HOME:-yes}" = "yes" ]; then
    ( umask "${def_UMASK:-077}" && mkdir -p "${ENROOT_ROOTFS}${home}" )
    skel="${def_SKEL:-/etc/skel}"
    if [ -d "${ENROOT_ROOTFS}${skel}" ]; then
        cp -Lpr "${ENROOT_ROOTFS}${skel}/." "${ENROOT_ROOTFS}${home}"
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
