# Copyright (c) 2018-2020, NVIDIA CORPORATION. All rights reserved.
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
readonly envconf="${script_args[2]}"
readonly sysconf_dir="${script_args[3]}"
readonly usrconf_dir="${script_args[4]}"

common::checkcmd tar "${decompress%% *}"

bundle::_dd() (
    local -r file="$1" offset="$2" size="$3" progress="$4"
    local -r blocks=$((size / 4194304)) bytes=$((size % 4194304)) barsize=20

    if [ -n "${progress}" ]; then
        trap 'tput cnorm >&2' EXIT; tput civis >&2

        dd status=none if="${file}" ibs="${offset}" skip=1 obs=4M conv=sync | {
          for i in $(seq 1 "${blocks}"); do
              dd status=none bs=4M iflag=fullblock count=1
              p=$((i * 4194304 * 100 / (blocks * 4194304 + bytes))); n=$((p * barsize / 100))
              { printf "\rExtracting ["; ((n)) && printf "#%.0s" $(seq 1 "${n}"); printf "%$((barsize - n))s] ${p}%%"; } >&2
          done
          if [ "${bytes}" -gt 0 ]; then
              dd status=none ibs=1 obs=4M count="${bytes}"
              { printf "\rExtracting ["; printf "#%.0s" $(seq 1 "${barsize}"); printf "] 100%%\n"; } >&2
          fi
        }
    else
        dd status=none if="${file}" ibs="${offset}" skip=1 obs=4M conv=sync | {
          if [ "${blocks}" -gt 0 ]; then dd status=none bs=4M iflag=fullblock count="${blocks}"; fi
          if [ "${bytes}" -gt 0 ]; then dd status=none ibs=1 obs=4M count="${bytes}"; fi
        }
    fi
)

bundle::_check() {
    local -r file="$1"
    local offset=0 sum1= sum2=

    if [[ "0x${sha256_sum}" -eq 0x0 ]]; then
        return
    fi

    offset=$(head -n "${skip_lines}" "${file}" | wc -c | tr -d ' ')

    for i in "${!file_sizes[@]}"; do
        cut -d ' ' -f $((i + 1)) <<< "${sha256_sum}" | read -r sum1
        bundle::_dd "${file}" "${offset}" "${file_sizes[i]}" "" | sha256sum | { read -r sum2 x || :; }
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
      "/lib/modules/$(uname -r)/build/.config"
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
    if command -v "nvidia-container-cli" > /dev/null; then
        printf "%-34s: %s\n" "nvidia-container-cli" "$(common::fmt green "OK")"
    else
        printf "%-34s: %s\n" "nvidia-container-cli" "$(common::fmt yellow "KO (required for GPU support)")"
    fi

    exit 0
}

bundle::extract() {
    local -r file="$1" dest="$2" quiet="$3"
    local progress= offset=0 diskspace=0

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
    --conf=*)
        [ -z "${1#*=}" ] && bundle::usage
        conf="${1#*=}"
        shift
        ;;
    -m|--mount)
        [ -z "${2-}" ] && bundle::usage
        mounts+=("$2")
        shift 2
        ;;
    --mount=*)
        [ -z "${1#*=}" ] && bundle::usage
        mounts+=("${1#*=}")
        shift
        ;;
    -e|--env)
        [ -z "${2-}" ] && bundle::usage
        environ+=("$2")
        shift 2
        ;;
    --env=*)
        [ -z "${1#*=}" ] && bundle::usage
        environ+=("${1#*=}")
        shift
        ;;
    -r|--root)
        root=y
        shift
        ;;
    --rc)
        [ -z "${2-}" ] && bundle::usage
        rc="$2"
        shift 2
        ;;
    --rc=*)
        [ -z "${1#*=}" ] && bundle::usage
        rc="${1#*=}"
        shift
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

    trap 'rmdir "${rundir}" 2> /dev/null' EXIT
    mkdir -m 0700 -p "${rootfs}" "${rundir}"
else
    rootfs=$(common::mktmpdir "${target_dir##*/}")
    rundir="${rootfs%/*}/.${rootfs##*/}"

    trap 'common::rmall "${rootfs}"; rmdir "${rundir}" 2> /dev/null' EXIT
    mkdir -m 0700 -p "${rundir}"
fi

bundle::extract "$0" "${rootfs}" "${quiet-}"
[ -v extract ] && exit 0

set +e
(
    set -e

    if [ -s "${rootfs}${envconf}" ]; then
        source "${rootfs}${envconf}"
    fi
    if [ -n "${conf-}" ] && [ -f "${conf}" ]; then
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

    runtime::start . "${rc-}" "${conf-}" \
      "$(IFS=$'\n'; echo ${mounts[*]+"${mounts[*]}"})"  \
      "$(IFS=$'\n'; echo ${environ[*]+"${environ[*]}"})" \
      "$@"
)
exit $?
EOF
