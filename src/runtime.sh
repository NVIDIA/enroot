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

source "${ENROOT_LIBRARY_PATH}/common.sh"

readonly hook_dirs=("${ENROOT_SYSCONF_PATH}/hooks.d" "${ENROOT_CONFIG_PATH}/hooks.d")
readonly mount_dirs=("${ENROOT_SYSCONF_PATH}/mounts.d" "${ENROOT_CONFIG_PATH}/mounts.d")
readonly environ_dirs=("${ENROOT_SYSCONF_PATH}/environ.d" "${ENROOT_CONFIG_PATH}/environ.d")
readonly environ_file="${ENROOT_RUNTIME_PATH}/environment"
readonly mount_file="${ENROOT_RUNTIME_PATH}/fstab"
readonly rc_file="${ENROOT_RUNTIME_PATH}/rc"
readonly lock_file="/.enroot.lock"

readonly bundle_dir="/.enroot"
readonly bundle_bin_dir="${bundle_dir}/bin"
readonly bundle_lib_dir="${bundle_dir}/lib"
readonly bundle_sysconf_dir="${bundle_dir}/etc/system"
readonly bundle_usrconf_dir="${bundle_dir}/etc/user"

runtime::_do_mounts_fstab() {
    local -r rootfs="$1"

    : > "${mount_file}"

    # Generate the mount configuration file from the rootfs fstab.
    common::envsubst "${rootfs}/etc/fstab" >> "${mount_file}"

    # Generate the mount configuration file from the host directories.
    for dir in "${mount_dirs[@]}"; do
        if [ -d "${dir}" ]; then
            for file in $(common::runparts list .fstab "${dir}"); do
                common::envsubst "${file}" >> "${mount_file}"
            done
        fi
    done

    # Perform all the mounts specified in the configuration file with fs_passno -1.
    enroot-mount --root "${rootfs}" --pass -1 "${mount_file}"
}

runtime::_do_mounts_cli() {
    local -r rootfs="$1"
    local -a mounts=()

    readarray -t mounts <<< "$2"

    # Generate the mount configuration file from the user config and CLI arguments.
    if declare -F mounts > /dev/null; then
        mounts >> "${mount_file}"
    fi
    for mount in ${mounts[@]+"${mounts[@]}"}; do
        tr ':' ' ' <<< "${mount}"
    done >> "${mount_file}"

    # Perform all the mounts specified in the configuration file with fs_passno unspecified (0).
    enroot-mount --root "${rootfs}" "${mount_file}"
}

runtime::_do_environ() {
    local -r rootfs="$1"
    local -a environ=()

    readarray -t environ <<< "$2"

    : > "${environ_file}"

    # Generate the environment configuration file from the rootfs.
    common::envsubst "${rootfs}/etc/environment" >> "${environ_file}"

    # Generate the environment configuration file from the host directories.
    for dir in "${environ_dirs[@]}"; do
        if [ -d "${dir}" ]; then
            for file in $(common::runparts list .env "${dir}"); do
                common::envsubst "${file}" >> "${environ_file}"
            done
        fi
    done

    # Generate the environment configuration file from the user config and CLI arguments.
    if declare -F environ > /dev/null; then
        environ >> "${environ_file}"
    fi
    for env in ${environ[@]+"${environ[@]}"}; do
         awk '{ print /=/ ? $0 : $0"="ENVIRON[$0] }' <<< "${env}"
    done >> "${environ_file}"

    # Format the environment file in case hooks rely on it.
    common::envfmt "${environ_file}"
}

runtime::_do_hooks() {
    local -r rootfs="$1"

    # Generate a new mount configuration file specifically for the hooks.
    mv "${mount_file}" "${mount_file}~"
    : > "${mount_file}"

    # Execute the hooks from the host directories.
    for dir in "${hook_dirs[@]}"; do
        if [ -d "${dir}" ]; then
            common::runparts exec .sh "${dir}"
        fi
    done

    # Execute the hooks from the user config.
    if declare -F hooks > /dev/null; then
        hooks
    fi

    # Perform all the mounts specified in the configuration file with fs_passno unspecified (0).
    enroot-mount --root "${rootfs}" "${mount_file}"
    mv "${mount_file}~" "${mount_file}"

    # Format the environment file again in case hooks touched it.
    common::envfmt "${environ_file}"
}

runtime::_do_rc() {
    local -r rootfs="$1"
    local -r rc="$2"

    # Generate the command script from the user config or the CLI argument.
    if [ -n "${rc}" ]; then
        cp -Lp "${rc}" "${rc_file}"
    elif declare -F rc > /dev/null; then
        declare -f rc | sed '1,2d;$d' > "${rc_file}"
    fi
}

runtime::_do_mount_rootfs() {
    local -r image="$1"
    local -r rootfs="$2"

    local -i euid=${EUID}
    local -i egid=-1; egid=$(stat -c "%g" /proc/$$)
    local -i timeout=100
    local -i pid=-1
    local -i i=0

    trap "kill -KILL 0 2> /dev/null" EXIT

    # Mount the image as the lower layer.
    squashfuse -f -o "uid=${euid},gid=${egid}" "${image}" "${rootfs}/lower" &
    pid=$!; i=0
    while ! mountpoint -q "${rootfs}/lower"; do
        ! kill -0 "${pid}" 2> /dev/null || ((i++ == timeout)) && exit 1
        sleep .001
    done

    # Mount the rootfs by overlaying the image and a tmpfs directory.
    FUSE_OVERLAYFS_DISABLE_OVL_WHITEOUT=y \
    fuse-overlayfs -f -o "lowerdir=${rootfs}/lower,upperdir=${rootfs}/upper,workdir=${rootfs}/work" "${rootfs}" &
    pid=$!; i=0
    while ! mountpoint -q "${rootfs}"; do
        ! kill -0 "${pid}" 2> /dev/null || ((i++ == timeout)) && exit 1
        sleep .001
    done

    # Stop this process in order to have the kernel trigger a SIGHUP if we ever get orphaned.
    kill -STOP $$
    exit 0
}

runtime::_mount_rootfs() {
    local -r image="$1"
    local -r rootfs="$2"

    local -i pid=0
    local -i rv=0

    common::checkcmd squashfuse fuse-overlayfs mountpoint

    mkfifo "${ENROOT_RUNTIME_PATH}/fuse"
    exec 3<>"${ENROOT_RUNTIME_PATH}/fuse"
    mkdir -p "${rootfs}"/{lower,upper,work}

    # Start a subshell in a new process group to act as a shim for fuse.
    # Since we don't have a pid namespace, the trick here is to start the fuse processes in
    # foreground and tie them to the lifetime of our process through a new child process group.
    # This way, we can leverage the rules for orphaned process groups and we don't need to leverage
    # an external binary to achieve essentially the same thing (e.g. subreaper, pidns, pdeathsig).
    set -m
    (
        # XXX Read the function from stdin to get a nicer ps(1) output.
        exec -a fuse-shim "${BASH}" <<< " \
          $(declare -f runtime::_do_mount_rootfs)
          runtime::_do_mount_rootfs '${image}' '${rootfs}'
        "
    ) > /dev/null 2>&3 & pid=$!

    # Wait for the fuse mounts to be done.
    wait "${pid}" > /dev/null 2>&1 || rv=$?
    set +m

    # Check for SIGSTOP.
    if ((rv != 128 + 19)); then
        common::log WARN - <&3
        common::err "Failed to mount: ${image}"
    fi
    exec 3>&-
    disown "${pid}" > /dev/null 2>&1
}

runtime::_start() {
    local rootfs="$1"; shift
    local -r rc="$1"; shift
    local -r config="$1"; shift
    local -r mounts="$1"; shift
    local -r environ="$1"; shift

    unset BASH_ENV

    # Setup a temporary working directory.
    enroot-mount - <<< "tmpfs ${ENROOT_RUNTIME_PATH} tmpfs x-create=dir,mode=700"

    # The rootfs was specified as an image, we need to mount it first before we can use it.
    if [ -f "${rootfs}" ]; then
        runtime::_mount_rootfs "${rootfs}" "${ENROOT_RUNTIME_PATH}/$(basename "${rootfs%.sqsh}")"
        rootfs="${ENROOT_RUNTIME_PATH}/$(basename "${rootfs%.sqsh}")"
    fi

    # Setup the rootfs with slave propagation.
    enroot-mount - <<< "${rootfs} ${rootfs} none bind,nosuid,nodev,slave"

    # Configure the container by performing mounts, setting its environment and executing hooks.
    (
        export ENROOT_PID="$$"
        export ENROOT_ROOTFS="${rootfs}"
        export ENROOT_ENVIRON="${environ_file}"
        export ENROOT_MOUNTS="${mount_file}"

        flock -w 30 "${lock}" > /dev/null 2>&1 || common::err "Could not acquire rootfs lock"

        if [ -n "${config}" ]; then
            source "${config}"
        fi
        runtime::_do_environ "${rootfs}" "${environ}" > /dev/null
        runtime::_do_mounts_fstab "${rootfs}" > /dev/null
        runtime::_do_hooks "${rootfs}" > /dev/null
        runtime::_do_mounts_cli "${rootfs}" "${mounts}" > /dev/null
        runtime::_do_rc "${rootfs}" "${rc}" > /dev/null

    ) {lock}> "${rootfs}${lock_file}"

    # Remount the rootfs readonly if necessary.
    if [ -z "${ENROOT_ROOTFS_WRITABLE-}" ]; then
        enroot-mount - <<< "none ${rootfs} none remount,bind,nosuid,nodev,ro"
    fi

    # Make the bundle directory and the lockfile readonly if present.
    if [ -d "${rootfs}${bundle_dir}" ]; then
        enroot-mount - <<< "${rootfs}${bundle_dir} ${rootfs}${bundle_dir} none rbind,nosuid,nodev,ro"
    fi
    if [ -f "${rootfs}${lock_file}" ]; then
        enroot-mount - <<< "${rootfs}${lock_file} ${rootfs}${lock_file} none bind,nosuid,nodev,noexec,ro"
    fi

    # Switch to the new root, and invoke the command script.
    if [ -f "${rc_file}" ]; then
        exec enroot-switchroot ${ENROOT_LOGIN_SHELL:+--login} --rcfile "${rc_file}" --envfile "${environ_file}" "${rootfs}" "$@"
    else
        exec enroot-switchroot ${ENROOT_LOGIN_SHELL:+--login} --envfile "${environ_file}" "${rootfs}" "$@"
    fi
}

runtime::start() {
    local rootfs="$1"; shift
    local rc="$1"; shift
    local config="$1"; shift
    local mounts="$1"; shift
    local environ="$1"; shift

    common::checkcmd awk grep sed flock

    # Resolve the container rootfs path.
    if [ -z "${rootfs}" ]; then
        common::err "Invalid argument"
    fi
    if [ -f "${rootfs}" ] && command -v unsquashfs > /dev/null && unsquashfs -s "${rootfs}" > /dev/null 2>&1; then
        rootfs=$(common::realpath "${rootfs}")
    else
        if [[ "${rootfs}" == */* ]]; then
            common::err "Invalid argument: ${rootfs}"
        fi
        rootfs=$(common::realpath "${ENROOT_DATA_PATH}/${rootfs}")
        if [ ! -d "${rootfs}" ]; then
            common::err "No such file or directory: ${rootfs}"
        fi
    fi

    # Check for invalid mount specifications.
    if [ -n "${mounts}" ]; then
        while IFS=$'\n' read -r mount; do
            if [[ ! "${mount}" =~ ^[^[:space:]]+:[^[:space:]]+$ ]]; then
                common::err "Invalid argument: ${mount}"
            fi
        done <<< "${mounts}"
    fi

    # Check for invalid environment variables.
    if [ -n "${environ}" ]; then
        while IFS=$'\n' read -r env; do
            if [[ ! "${env}" =~ ^[[:alpha:]_][[:alnum:]_]*(=|$) ]]; then
                common::err "Invalid argument: ${env}"
            fi
        done <<< "${environ}"
    fi

    # Resolve the command script path.
    if [ -n "${rc}" ] && [ ! -p "${rc}" ]; then
        rc=$(common::realpath "${rc}")
        if [ ! -f "${rc}" ]; then
            common::err "No such file or directory: ${rc}"
        fi
    fi

    # Resolve the container configuration path.
    if [ -n "${config}" ]; then
        config=$(common::realpath "${config}")
        if [ ! -f "${config}" ]; then
            common::err "No such file or directory: ${config}"
        fi
        if ! "${BASH}" -n "${config}" 2>&1 > /dev/null | common::log WARN -; then
            common::err "Invalid argument: ${config}"
        fi
    fi

    # Create new namespaces and start the container.
    export BASH_ENV="${BASH_SOURCE[0]}"
    exec enroot-unshare ${ENROOT_REMAP_ROOT:+--root} \
      "${BASH}" -o ${SHELLOPTS//:/ -o } -O ${BASHOPTS//:/ -O } -c \
      'runtime::_start "$@"' "${config}" "${rootfs}" "${rc}" "${config}" "${mounts}" "${environ}" "$@"
}

runtime::create() {
    local image="$1"
    local rootfs="$2"

    common::checkcmd unsquashfs find

    # Resolve the container image path.
    if [ -z "${image}" ]; then
        common::err "Invalid argument"
    fi
    image=$(common::realpath "${image}")
    if [ ! -f "${image}" ]; then
        common::err "No such file or directory: ${image}"
    fi
    if ! unsquashfs -s "${image}" > /dev/null 2>&1; then
        common::err "Invalid image format: ${image}"
    fi

    # Resolve the container rootfs path.
    if [ -z "${rootfs}" ]; then
        rootfs=$(basename "${image%.sqsh}")
    fi
    if [[ "${rootfs}" == */* ]]; then
        common::err "Invalid argument: ${rootfs}"
    fi
    rootfs=$(common::realpath "${ENROOT_DATA_PATH}/${rootfs}")
    if [ -e "${rootfs}" ]; then
        common::err "File already exists: ${rootfs}"
    fi

    # Extract the container rootfs from the image.
    common::log INFO "Extracting squashfs filesystem..." NL
    unsquashfs ${TTY_OFF+-no-progress} -user-xattrs -d "${rootfs}" "${image}"
    common::fixperms "${rootfs}"
}

runtime::import() {
    local -r uri="$1"
    local -r filename="$2"
    local arch="$3"

    # Use the host architecture as the default.
    if [ -z "${arch}" ]; then
        arch=$(uname -m)
    fi

    # Import a container image from the URI specified.
    case "${uri}" in
    docker://*)
        docker::import "${uri}" "${filename}" "${arch}" ;;
    *)
        common::err "Invalid argument: ${uri}" ;;
    esac
}

runtime::export() {
    local rootfs="$1"
    local filename="$2"

    local -a exclude=()

    common::checkcmd mksquashfs

    # Resolve the container rootfs path.
    if [ -z "${rootfs}" ]; then
        common::err "Invalid argument"
    fi
    if [[ "${rootfs}" == */* ]]; then
        common::err "Invalid argument: ${rootfs}"
    fi
    rootfs=$(common::realpath "${ENROOT_DATA_PATH}/${rootfs}")
    if [ ! -d "${rootfs}" ]; then
        common::err "No such file or directory: ${rootfs}"
    fi

    # Generate an absolute filename if none was specified.
    if [ -z "${filename}" ]; then
        filename="$(basename "${rootfs}").sqsh"
    fi
    filename=$(common::realpath "${filename}")
    if [ -e "${filename}" ]; then
        common::err "File already exists: ${filename}"
    fi

    # Exclude mountpoints, the bundle directory and the lockfile.
    find "${rootfs}" -path "${rootfs}/dev/*" -o -perm 0000 -prune \( -empty -o -type d \) | readarray -t exclude
    if [ -d "${rootfs}${bundle_dir}" ]; then
        exclude+=("${rootfs}${bundle_dir}")
    fi
    if [ -f "${rootfs}${lock_file}" ]; then
        exclude+=("${rootfs}${lock_file}")
    fi

    # Export a container image from the rootfs specified.
    common::log INFO "Creating squashfs filesystem..." NL
    mksquashfs "${rootfs}" "${filename}" -all-root ${TTY_OFF+-no-progress} -processors "${ENROOT_MAX_PROCESSORS}" \
      ${ENROOT_SQUASH_OPTIONS} ${exclude[@]+-e "${exclude[@]}"}
}

runtime::list() {
    local fancy="$1"

    common::chdir "${ENROOT_DATA_PATH}"

    # List all the container rootfs along with their size.
    if [ -n "${fancy}" ]; then
        if [ -n "$(ls -A)" ]; then
            printf "%b\n" "$(common::fmt bold "SIZE\tNAME")"
            du -sh -- * 2> /dev/null
        fi
    else
        ls -1
    fi
}

runtime::remove() {
    local rootfs="$1"
    local force="$2"

    # Resolve the container rootfs path.
    if [ -z "${rootfs}" ]; then
        common::err "Invalid argument"
    fi
    if [[ "${rootfs}" == */* ]]; then
        common::err "Invalid argument: ${rootfs}"
    fi
    rootfs=$(common::realpath "${ENROOT_DATA_PATH}/${rootfs}")
    if [ ! -d "${rootfs}" ]; then
        common::err "No such file or directory: ${rootfs}"
    fi

    # Remove the rootfs specified after asking for confirmation.
    if [ -z "${force}" ]; then
        read -r -e -p "Do you really want to delete ${rootfs}? [y/N] "
    fi
    if [ -n "${force}" ] || [ "${REPLY}" = "y" ] || [ "${REPLY}" = "Y" ]; then
        common::rmall "${rootfs}"
    fi
}

runtime::bundle() (
    local image="$1"
    local filename="$2"
    local target="$3"
    local desc="$4"

    local super=""
    local tmpdir=""
    local compress=""

    common::checkcmd unsquashfs find awk grep

    # Resolve the container image path.
    if [ -z "${image}" ]; then
        common::err "Invalid argument"
    fi
    image=$(common::realpath "${image}")
    if [ ! -f "${image}" ]; then
        common::err "No such file or directory: ${image}"
    fi
    if ! super=$(unsquashfs -s "${image}" 2> /dev/null); then
        common::err "Invalid image format: ${image}"
    fi

    # Generate an absolute filename if none was specified.
    if [ -z "${filename}" ]; then
        filename="$(basename "${image%.sqsh}").run"
    fi
    filename=$(common::realpath "${filename}")
    if [ -e "${filename}" ]; then
        common::err "File already exists: ${filename}"
    fi

    # Generate a target directory if none was specified.
    if [ -z "${target}" ]; then
        target="$(basename "${filename%.run}")"
    fi

    # Use the filename as the description if none was specified.
    if [ -z "${desc}" ]; then
        desc="none"
    fi

    # If the image data is compressed, reuse the same one for the bundle.
    if grep -q "^Data is compressed" <<< "${super}"; then
        compress=$(awk '/^Compression/ { print "--"$2 }' <<< "${super}")
    else
        compress="--nocomp"
    fi

    tmpdir=$(common::mktmpdir enroot)
    trap "common::rmall '${tmpdir}' 2> /dev/null" EXIT

    # Extract the container rootfs from the image.
    common::log INFO "Extracting squashfs filesystem..." NL
    unsquashfs ${TTY_OFF+-no-progress} -user-xattrs -f -d "${tmpdir}" "${image}"
    common::fixperms "${tmpdir}"
    common::log

    # Copy runtime components to the bundle directory.
    common::log INFO "Generating bundle..." NL
    mkdir -p "${tmpdir}${bundle_bin_dir}" "${tmpdir}${bundle_lib_dir}" "${tmpdir}${bundle_sysconf_dir}" "${tmpdir}${bundle_usrconf_dir}"
    cp -Lp $(command -v enroot-unshare enroot-mount enroot-switchroot) "${tmpdir}${bundle_bin_dir}"
    cp -Lp "${ENROOT_LIBRARY_PATH}"/{common.sh,runtime.sh} "${tmpdir}${bundle_lib_dir}"

    # Copy runtime configurations to the bundle directory.
    cp -Lpr "${hook_dirs[0]}" "${mount_dirs[0]}" "${environ_dirs[0]}" "${tmpdir}${bundle_sysconf_dir}"
    if [ -n "${ENROOT_BUNDLE_ALL-}" ]; then
        [ -d "${hook_dirs[1]}" ] && cp -Lpr "${hook_dirs[1]}" "${tmpdir}${bundle_usrconf_dir}"
        [ -d "${mount_dirs[1]}" ] && cp -Lpr "${mount_dirs[1]}" "${tmpdir}${bundle_usrconf_dir}"
        [ -d "${environ_dirs[1]}" ] && cp -Lpr "${environ_dirs[1]}" "${tmpdir}${bundle_usrconf_dir}"
    fi

    # Make a self-extracting archive with the entrypoint being our bundle script.
    enroot-makeself --tar-quietly --tar-extra '--numeric-owner --owner=0 --group=0 --ignore-failed-read' \
      --nomd5 --nocrc ${ENROOT_BUNDLE_CHECKSUM:+--sha256} --header "${ENROOT_LIBRARY_PATH}/bundle.sh" "${compress}" \
      --target "${target}" "${tmpdir}" "${filename}" "${desc}" -- \
      "${bundle_bin_dir}" "${bundle_lib_dir}" "${bundle_sysconf_dir}" "${bundle_usrconf_dir}"
)
