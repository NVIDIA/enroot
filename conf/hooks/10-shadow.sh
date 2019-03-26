#! /bin/bash

# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

set -eu

readonly NOBODY=$(< /proc/sys/kernel/overflowuid)
readonly NOGROUP=$(< /proc/sys/kernel/overflowgid)
readonly PWDENT=$(awk '{ system("getent passwd " $2) }' /proc/self/uid_map)
readonly GRPENT=$(awk '{ system("getent group " $2) }' /proc/self/gid_map)

# Load the default shadow settings.
defaults=($(awk '(NF && $1 !~ "^#"){ print "def_"$1"="$2 }' "${ENROOT_ROOTFS}/etc/login.defs" 2> /dev/null))
defaults+=($(awk '(NF && $1 !~ "^#"){ print "def_"$1 }' "${ENROOT_ROOTFS}/etc/default/useradd" 2> /dev/null))
readonly "${defaults[@]}"

# Read the user/group database entries for the current user on the host.
IFS=':' read -r user x uid x gecos home shell <<< "${PWDENT}"
IFS=':' read -r group x gid <<< "${GRPENT}"

if [ ! -x "${ENROOT_ROOTFS}${shell}" ]; then
    shell="${def_SHELL:-/bin/sh}"
fi

# Create new database files based on the ones present in the rootfs.
cp -a "${ENROOT_ROOTFS}/etc/passwd" "${ENROOT_ROOTFS}/etc/passwd-"
cp -a "${ENROOT_ROOTFS}/etc/group" "${ENROOT_ROOTFS}/etc/group-"

# XXX On debian based distributions, remove the _apt user/group otherwise apt will try to drop privileges and fail.
if [ -f "${ENROOT_ROOTFS}/etc/debian_version" ]; then
    sed -i '/^_apt:/d' "${ENROOT_ROOTFS}/etc/passwd-"
    sed -i '/^_apt:/d' "${ENROOT_ROOTFS}/etc/group-"
fi

# Generate user entries for root, nobody and the current user.
cat << EOF >> "${ENROOT_ROOTFS}/etc/passwd-"
root:x:0:0:root:/root:${shell}
nobody:x:${NOBODY}:${NOGROUP}:nobody:/:/sbin/nologin
${user}:x:${uid}:${gid}:${gecos}:${home}:${shell}
EOF

# Generate group entries for root, nobody and the current user.
cat << EOF >> "${ENROOT_ROOTFS}/etc/group-"
root:x:0:
nogroup:x:${NOGROUP}:
${group}:x:${gid}:
EOF

# Check and install the new group database making sure our generated groups come first.
yes | grpck -R "${ENROOT_ROOTFS}" /etc/group- > /dev/null || :
tail -n -3 "${ENROOT_ROOTFS}/etc/group-" > "${ENROOT_ROOTFS}/etc/group"
head -n -3 "${ENROOT_ROOTFS}/etc/group-" >> "${ENROOT_ROOTFS}/etc/group"

# Check and install the new user database making sure our generated users come first.
yes | pwck -R "${ENROOT_ROOTFS}" /etc/passwd- > /dev/null || :
tail -n -3 "${ENROOT_ROOTFS}/etc/passwd-" > "${ENROOT_ROOTFS}/etc/passwd"
head -n -3 "${ENROOT_ROOTFS}/etc/passwd-" >> "${ENROOT_ROOTFS}/etc/passwd"

rm -f "${ENROOT_ROOTFS}/etc/group-" "${ENROOT_ROOTFS}/etc/passwd-"

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
