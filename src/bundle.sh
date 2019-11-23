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

cat << EOF > "${archname}"
#! /usr/bin/env bash

if [ \${BASH_VERSION:0:1} -lt 4 ] || [ \${BASH_VERSION:0:1} -eq 4 -a \${BASH_VERSION:2:1} -lt 2 ]; then
    printf "Unsupported %s version: %s\n" "\${BASH}" "\${BASH_VERSION}" >&2
    exit 1
fi

set -euo pipefail
shopt -s lastpipe

readonly description="${LABEL}"
readonly compression="${COMPRESS}"
readonly target_dir="${archdirname}"
readonly file_sizes=(${filesizes})
readonly sha256_sum="${SHAsum}"
readonly skip_lines="${SKIP}"
readonly total_size="${USIZE}"
readonly decompress="${GUNZIP_CMD}"
readonly script_args=(${SCRIPTARGS})

readonly runtime_version="${ENROOT_VERSION}"

EOF
cat "${ENROOT_LIBRARY_PATH}/common.sh" - << 'EOF' >> "${archname}"

readonly bin_dir="${script_args[0]}"
readonly lib_dir="${script_args[1]}"
readonly sysconf_dir="${script_args[2]}"
readonly usrconf_dir="${script_args[3]}"

common::checkcmd tar "${decompress%% *}"

bundle::_dd() {
    local -r file="$1"
    local -r offset="$2"
    local -r size="$3"
    local -r progress="$4"

    local progress_cmd="cat"
    local -r blocks=$((size / 1024))
    local -r bytes=$((size % 1024))

    if [ -n "${progress}" ] && command -v pv > /dev/null; then
        progress_cmd="pv -s ${size}"
    fi

    dd status=none if="${file}" ibs="${offset}" skip=1 obs=1024 conv=sync | { \
      if [ "${blocks}" -gt 0 ]; then dd status=none ibs=1024 obs=1024 count="${blocks}"; fi; \
      if [ "${bytes}" -gt 0 ]; then dd status=none ibs=1 obs=1024 count="${bytes}"; fi; \
    } | ${progress_cmd}
}

bundle::_check() {
    local -r file="$1"

    local -i offset=0
    local sum1=""
    local sum2=""

    if [[ "0x${sha256_sum}" -eq 0x0 ]]; then
        return
    fi

    offset=$(head -n "${skip_lines}" "${file}" | wc -c | tr -d ' ')

    for i in "${!file_sizes[@]}"; do
        cut -d ' ' -f $((i + 1)) <<< "${sha256_sum}" | read -r sum1
        bundle::_dd "${file}" "${offset}" "${file_sizes[i]}" "" | sha256sum | read -r sum2 x
        if [ "${sum1}" != "${sum2}" ]; then
            common::err "Checksum validation failed"
        fi
        offset=$((offset + file_sizes[i]))
    done
}

bundle::verify() {
    local -r configs=(
      "/proc/config.gz"
      "/boot/config-$(uname -r)"
      "/usr/src/linux-$(uname -r)/.config"
      "/usr/src/linux/.config"
    )

    common::checkcmd zgrep cat

    for i in "${!configs[@]}"; do
        if [ -f "${configs[i]}" ]; then
            conf="${configs[i]}"
            break
        fi
    done
    if [ ! -v conf ]; then
        common::err "Could not find kernel configuration"
    fi

    printf "%s\n\n" "$(common::fmt bold "Kernel version:")"
    cat /proc/version

    printf "\n%s\n\n" "$(common::fmt bold "Kernel configuration:")"
    for param in CONFIG_NAMESPACES CONFIG_USER_NS CONFIG_SECCOMP_FILTER; do
        if zgrep -q "${param}=y" "${conf}"; then
            printf "%-34s: %s\n" "${param}" "$(common::fmt green "OK")"
        elif zgrep -q "${param}=m" "${conf}"; then
            printf "%-34s: %s\n" "${param}" "$(common::fmt green "OK (module)")"
        else
            printf "%-34s: %s\n" "${param}" "$(common::fmt red "KO")"
        fi
    done
    for param in CONFIG_OVERLAY_FS; do
        if zgrep -q "${param}=y" "${conf}"; then
            printf "%-34s: %s\n" "${param}" "$(common::fmt green "OK")"
        elif zgrep -q "${param}=m" "${conf}"; then
            printf "%-34s: %s\n" "${param}" "$(common::fmt green "OK (module)")"
        else
            printf "%-34s: %s\n" "${param}" "$(common::fmt yellow "KO (optional)")"
        fi
    done
    for param in CONFIG_X86_VSYSCALL_EMULATION CONFIG_VSYSCALL_EMULATE CONFIG_VSYSCALL_NATIVE; do
        if zgrep -q "${param}=y" "${conf}"; then
            printf "%-34s: %s\n" "${param}" "$(common::fmt green "OK")"
        else
            printf "%-34s: %s\n" "${param}" "$(common::fmt yellow "KO (required if glibc <= 2.13)")"
        fi
    done

    printf "\n%s\n\n" "$(common::fmt bold "Kernel command line:")"
    case "$(. /etc/os-release 2> /dev/null; echo "${ID-}${VERSION_ID-}")" in
    centos7*|rhel7*)
        for param in "namespace.unpriv_enable=1" "user_namespace.enable=1"; do
            if grep -q "${param}" /proc/cmdline; then
                printf "%-34s: %s\n" "${param}" "$(common::fmt green "OK")"
            else
                printf "%-34s: %s\n" "${param}" "$(common::fmt red "KO")"
            fi
        done
    esac
    for param in "vsyscall=native" "vsyscall=emulate"; do
        if grep -q "${param}" /proc/cmdline; then
            printf "%-34s: %s\n" "${param}" "$(common::fmt green "OK")"
        else
            printf "%-34s: %s\n" "${param}" "$(common::fmt yellow "KO (required if glibc <= 2.13)")"
        fi
    done

    printf "\n%s\n\n" "$(common::fmt bold "Kernel parameters:")"
    for param in "kernel/unprivileged_userns_clone" "user/max_user_namespaces" "user/max_mnt_namespaces"; do
        if [ -f "/proc/sys/${param}" ]; then
            if [ "$(< /proc/sys/${param})" -gt 0 ]; then
                printf "%-34s: %s\n" "${param/\//.}" "$(common::fmt green "OK")"
            else
                printf "%-34s: %s\n" "${param/\//.}" "$(common::fmt red "KO")"
            fi
        fi
    done

    printf "\n%s\n\n" "$(common::fmt bold "Extra packages:")"
    for cmd in nvidia-container-cli pv; do
        if command -v "${cmd}" > /dev/null; then
            printf "%-34s: %s\n" "${cmd}" "$(common::fmt green "OK")"
        elif [ "${cmd}" = "nvidia-container-cli" ]; then
            printf "%-34s: %s\n" "${cmd}" "$(common::fmt yellow "KO (required for GPU support)")"
        else
            printf "%-34s: %s\n" "${cmd}" "$(common::fmt yellow "KO (optional)")"
        fi
    done

    exit 0
}

bundle::extract() {
    local -r file="$1"
    local -r dest="$2"
    local -r quiet="$3"

    local progress=""
    local -i offset=0
    local -i diskspace=0

    if [ -z "${quiet}" ] && [ -t 2 ]; then
        progress=y
    fi

    offset=$(head -n "${skip_lines}" "${file}" | wc -c | tr -d ' ')
    diskspace=$(df -k "${dest}" | tail -1 | tr -s ' ' | cut -d' ' -f4)

    if [ "${diskspace}" -lt "${total_size}" ]; then
        common::err "Not enough space left in $(dirname "${dest}") (${total_size} KB needed)"
    fi
    for i in "${!file_sizes[@]}"; do
        bundle::_dd "${file}" "${offset}" "${file_sizes[i]}" "${progress}" | ${decompress} | tar -C "${dest}" --strip-components=1 -pxf -
        offset=$((offset + file_sizes[i]))
    done

    touch "${dest}"
}

bundle::usage() {
    printf "Usage: %s [options] [--] [COMMAND] [ARG...]\n" "${0##*/}"
    if [ "${description}" != "none" ]; then
        printf "\n%s\n" "${description}"
    fi
    cat <<- EOF
	
	 Options:
	   -i, --info           Display the information about this bundle
	   -k, --keep           Keep the bundle extracted in the target directory
	   -q, --quiet          Supress the progress bar output
	   -v, --verify         Verify that the host configuration is compatible with the bundle
	   -x, --extract        Extract the bundle in the target directory and exit (implies --keep)
	
	   -c, --conf CONFIG    Specify a configuration script to run before the container starts
	   -e, --env KEY[=VAL]  Export an environment variable inside the container
	   -m, --mount FSTAB    Perform a mount from the host inside the container (colon-separated)
	       --rc SCRIPT      Override the command script inside the container
	   -r, --root           Ask to be remapped to root inside the container
	   -w, --rw             Make the container root filesystem writable
	EOF
    exit 0
}

bundle::info() {
    if [[ "0x${sha256_sum}" -ne 0x0 ]]; then
        printf "Checksum: %s\n" "${sha256_sum}"
    fi
    cat <<- EOR
	Compression: ${compression}
	Description: ${description}
	Runtime version: ${runtime_version}
	Target directory: ${target_dir}
	Uncompressed size: ${total_size} KB
	EOR
    exit 0
}

bundle::_check "$0"

while [ $# -gt 0 ]; do
    case "$1" in
    -v|--verify)
        bundle::verify ;;
    -i|--info)
        bundle::info ;;
    -k|--keep)
        keep=y
        shift
        ;;
    -x|--extract)
        extract=y
        keep=y
        shift
        ;;
    -q|--quiet)
        quiet=y
        shift
        ;;
    -c|--conf)
        [ -z "${2-}" ] && bundle::usage
        conf="$2"
        shift 2
        ;;
    -m|--mount)
        [ -z "${2-}" ] && bundle::usage
        mounts+=("$2")
        shift 2
        ;;
    -e|--env)
        [ -z "${2-}" ] && bundle::usage
        environ+=("$2")
        shift 2
        ;;
    -r|--root)
        root=y
        shift
        ;;
    --rc)
        [ -z "${2-}" ] && bundle::usage
        mounts+=("$2:/etc/rc:none:x-create=file,bind,ro,nosuid,nodev")
        shift 2
        ;;
    -w|--rw)
        rw=y
        shift
        ;;
    --)
        shift; break ;;
    -?*)
        bundle::usage ;;
    *)
        break ;;
    esac
done

if [ -v keep ]; then
    rootfs=$(common::realpath "${target_dir}")
    if [ -e "${rootfs}" ]; then
        common::err "File already exists: ${rootfs}"
    fi
    rundir="${rootfs%/*}/.${rootfs##*/}"

    mkdir -m 0700 -p "${rootfs}" "${rundir}"
    trap "rmdir '${rundir}' 2> /dev/null" EXIT
else
    rootfs=$(common::mktmpdir "${target_dir##*/}")
    rundir="${rootfs%/*}/.${rootfs##*/}"

    mkdir -m 0700 -p "${rundir}"
    trap "common::rmall '${rootfs}'; rmdir '${rundir}' 2> /dev/null" EXIT
fi

bundle::extract "$0" "${rootfs}" "${quiet-}"
[ -v extract ] && exit 0

set +e
(
    set -e

    if [ -n "${conf-}" ]; then
        common::checkcmd sed
        while IFS=$' \t=' read -r key value; do
            export "${key}=$(eval echo "${value}")"
        done < <(sed -n '/^#[[:space:]]*ENROOT_/s/#//p' "${conf}")
    fi
    for var in $(compgen -e "ENROOT_"); do
        if [[ "${!var}" =~ ^(no?|N[oO]?|[fF](alse)?|FALSE)$ ]]; then
            unset "${var}"
        fi
    done

    if [ -v root ]; then
        export ENROOT_REMAP_ROOT=y
    fi
    if [ -v rw ]; then
        export ENROOT_ROOTFS_WRITABLE=y
    fi

    export PATH="${rootfs}${bin_dir}${PATH:+:${PATH}}"
    export ENROOT_LIBRARY_PATH="${rootfs}${lib_dir}"
    export ENROOT_SYSCONF_PATH="${rootfs}${sysconf_dir}"
    export ENROOT_CONFIG_PATH="${rootfs}${usrconf_dir}"
    export ENROOT_DATA_PATH="${rootfs}"
    export ENROOT_RUNTIME_PATH="${rundir}"
    export ENROOT_VERSION="${runtime_version}"

    source "${ENROOT_LIBRARY_PATH}/runtime.sh"

    runtime::start . "${conf-}" \
      "$(IFS=$'\n'; echo ${mounts[*]+"${mounts[*]}"})"  \
      "$(IFS=$'\n'; echo ${environ[*]+"${environ[*]}"})" \
      "$@"
)
exit $?
EOF
