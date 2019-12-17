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
readonly lock_file="/.lock"

readonly bundle_dir="/.enroot"
readonly bundle_bin_dir="${bundle_dir}/bin"
readonly bundle_lib_dir="${bundle_dir}/lib"
readonly bundle_sysconf_dir="${bundle_dir}/etc/system"
readonly bundle_usrconf_dir="${bundle_dir}/etc/user"

runtime::_do_environ() {
    local -r rootfs="$1"
    local environ=()

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

runtime::_do_mounts_init() {
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

runtime::_do_mounts_fini() {
    local -r rootfs="$1"
    local mounts=()

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

runtime::_do_rc() {
    local -r rootfs="$1" rc="$2"

    # Generate the command script from the user config or the CLI argument.
    if [ -n "${rc}" ]; then
        cp -Lp "${rc}" "${rc_file}"
    elif declare -F rc > /dev/null; then
        declare -f rc | sed '1,2d;$d' > "${rc_file}"
    fi
}

runtime::_mount_rootfs_shim() {
    local -r image="$1" rootfs="$2"
    local euid=${EUID} egid=; egid=$(stat -c "%g" /proc/$$)
    local timeout=100 pid=-1 id=0

    trap 'kill -KILL 0 2> /dev/null' EXIT

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
    local -r image="$1" rootfs="$2"
    local pid=0 rv=0

    common::checkcmd squashfuse fuse-overlayfs mountpoint

    mkfifo "${ENROOT_RUNTIME_PATH}/fuse"
    exec {fd}<>"${ENROOT_RUNTIME_PATH}/fuse"
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
          $(declare -f runtime::_mount_rootfs_shim)
          runtime::_mount_rootfs_shim '${image}' '${rootfs}'
        "
    ) > /dev/null 2>&${fd} & pid=$!

    # Wait for the fuse mounts to be done.
    wait "${pid}" > /dev/null 2>&1 || rv=$?
    set +m

    # Check for SIGSTOP.
    if ((rv != 128 + 19)); then
        common::log WARN - <&${fd}
        common::err "Failed to mount: ${image}"
    fi
    exec {fd}>&-
    disown "${pid}" > /dev/null 2>&1
}

runtime::_start() {
    local _rootfs="$1"; shift
    local -r _rc="$1"; shift
    local -r _config="$1"; shift
    local -r _mounts="$1"; shift
    local -r _environ="$1"; shift

    unset BASH_ENV

    # Setup a temporary working directory.
    cat <<- EOF | enroot-mount -
	none $(common::mountpoint "${ENROOT_RUNTIME_PATH}") none slave
	tmpfs ${ENROOT_RUNTIME_PATH} tmpfs x-create=dir,mode=700,slave
	EOF

    # The rootfs was specified as an image, we need to mount it first before we can use it.
    if [ -f "${_rootfs}" ]; then
        runtime::_mount_rootfs "${_rootfs}" "${ENROOT_RUNTIME_PATH}/$(basename "${_rootfs%.sqsh}")"
        _rootfs="${ENROOT_RUNTIME_PATH}/$(basename "${_rootfs%.sqsh}")"
    fi

    # Setup the rootfs with slave propagation.
    cat <<- EOF | enroot-mount -
	none $(common::mountpoint "${_rootfs}") none slave
	${_rootfs} ${_rootfs} none bind,nosuid,nodev,slave
	EOF

    # Configure the container by performing mounts, setting its environment and executing hooks.
    (
        export ENROOT_PID="$$"
        export ENROOT_ROOTFS="${_rootfs}"
        export ENROOT_ENVIRON="${environ_file}"
        export ENROOT_MOUNTS="${mount_file}"

        flock -w 30 "${_lock}" > /dev/null 2>&1 || common::err "Could not acquire rootfs lock"

        if [ -n "${_config}" ]; then
            source "${_config}"
        fi
        runtime::_do_environ "${_rootfs}" "${_environ}" > /dev/null
        runtime::_do_mounts_init "${_rootfs}" > /dev/null
        runtime::_do_hooks "${_rootfs}" > /dev/null
        runtime::_do_mounts_fini "${_rootfs}" "${_mounts}" > /dev/null
        runtime::_do_rc "${_rootfs}" "${_rc}" > /dev/null

    ) {_lock}> "${_rootfs}${lock_file}"

    # Remount the rootfs readonly if necessary.
    if [ -z "${ENROOT_ROOTFS_WRITABLE-}" ]; then
        enroot-mount - <<< "none ${_rootfs} none remount,bind,nosuid,nodev,ro"
    fi

    # Make the bundle directory and the lockfile readonly if present.
    if [ -d "${_rootfs}${bundle_dir}" ]; then
        enroot-mount - <<< "${_rootfs}${bundle_dir} ${_rootfs}${bundle_dir} none rbind,nosuid,nodev,ro,private"
    fi
    if [ -f "${_rootfs}${lock_file}" ]; then
        enroot-mount - <<< "${_rootfs}${lock_file} ${_rootfs}${lock_file} none bind,nosuid,nodev,noexec,ro,private"
    fi

    # Switch to the new root, and invoke the command script.
    if [ -f "${rc_file}" ]; then
        exec enroot-switchroot ${ENROOT_LOGIN_SHELL:+--login} --rcfile "${rc_file}" --envfile "${environ_file}" "${_rootfs}" "$@"
    else
        exec enroot-switchroot ${ENROOT_LOGIN_SHELL:+--login} --envfile "${environ_file}" "${_rootfs}" "$@"
    fi
}

runtime::start() {
    local rootfs="$1"; shift
    local rc="$1"; shift
    local config="$1"; shift
    local mounts="$1"; shift
    local environ="$1"; shift
    local unpriv=

    common::checkcmd mountpoint awk grep sed flock

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

    # Check if we're running unprivileged.
    if [ -z "${ENROOT_ALLOW_SUPERUSER-}" ] || [ "${EUID}" -ne 0 ]; then
        unpriv=y
    fi

    # Create new namespaces and start the container.
    export BASH_ENV="${BASH_SOURCE[0]}"
    exec enroot-nsenter ${unpriv:+--user} --mount ${ENROOT_REMAP_ROOT:+--remap-root} \
      "${BASH}" -o ${SHELLOPTS//:/ -o } -O ${BASHOPTS//:/ -O } -c \
      'runtime::_start "$@"' "${config}" "${rootfs}" "${rc}" "${config}" "${mounts}" "${environ}" "$@"
}

runtime::create() {
    local image="$1" rootfs="$2"

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
    unsquashfs ${TTY_OFF+-no-progress} -user-xattrs -d "${rootfs}" "${image}" >&2
    common::fixperms "${rootfs}"
}

runtime::import() {
    local -r uri="$1" filename="$2"
    local arch="$3"

    # Use the host architecture as the default.
    if [ -z "${arch}" ]; then
        arch=$(uname -m)
    fi

    # Import a container image from the URI specified.
    case "${uri}" in
    docker://*)
        docker::import "${uri}" "${filename}" "${arch}" ;;
    dockerd://*)
        docker::daemon::import "${uri}" "${filename}" "${arch}" ;;
    *)
        common::err "Invalid argument: ${uri}" ;;
    esac
}

runtime::export() {
    local rootfs="$1" filename="$2"
    local exclude=()

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
      ${ENROOT_SQUASH_OPTIONS} ${exclude[@]+-e "${exclude[@]}"} >&2
}

runtime::list() {
    local -r fancy="$1"
    local cwd= name= size= pid= entry=()
    declare -A info

    common::checkcmd mountpoint awk lsns ps column
    common::chdir "${ENROOT_DATA_PATH}"

    if [ -z "${fancy}" ]; then
        ls -1
        return
    fi

    cwd="${PWD#$(common::mountpoint .)}/"
    [[ "${cwd}" != /* ]] && cwd="/${cwd}"

    # Retrieve each container rootfs along with its size.
    info["<unknown>"]="0"
    { du -sh -- * 2> /dev/null || :; } | while read -r size name; do
        info["${name}"]="${size}"
    done

    # Look for all the pids associated with any of the rootfs.
    for pid in $(lsns -n -r -t mnt -o pid); do
        if [ -e "/proc/${pid}/root/${lock_file}" ]; then
            name=$(awk '($5 == "/"){print $4; exit}' "/proc/${pid}/mountinfo" 2> /dev/null)
            if [ -v info["${name#${cwd}}"] ]; then
                info["${name#${cwd}}"]+=" ${pid} "
            else
                info["<unknown>"]+=" ${pid} "
            fi
        fi
    done

    # List all the rootfs entries and their respective processes.
    for name in $(printf "%s\n" "${!info[@]}" | sort); do
        entry=(${info["${name}"]})
        if [ "${#entry[@]}" -eq 1 ]; then
            printf "%s\t%s\n" "${name}" "${entry[0]}"
        else
            ps -p "${entry[*]:1}" --no-headers -o pid:1,stat:1,start:1,etime:1,mntns:1,userns:1,command:1 \
              | awk -v name="${name}" -v size="${entry[0]}" '{
                  printf (NR==1) ? "%s\t%s\t" : "\t\t", name, size
                  printf "%s\t%s\t%s\t%s\t%s\t%s\t", $1, $2, $3, $4, $5, $6
                  print substr($0, index($0, $7))
              }'
        fi
    done | column -t -s $'\t' -N NAME,SIZE,PID,STATE,STARTED,TIME,MNTNS,USERNS,COMMAND -T COMMAND
}

runtime::remove() {
    local rootfs="$1" force="$2"

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
    local image="$1" filename="$2" target="$3" desc="$4"
    local super= tmpdir= compress=

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

    trap 'common::rmall "${tmpdir}" 2> /dev/null' EXIT
    tmpdir=$(common::mktmpdir enroot)

    # Extract the container rootfs from the image.
    common::log INFO "Extracting squashfs filesystem..." NL
    unsquashfs ${TTY_OFF+-no-progress} -user-xattrs -f -d "${tmpdir}" "${image}" >&2
    common::fixperms "${tmpdir}"
    common::log

    # Copy runtime components to the bundle directory.
    common::log INFO "Generating bundle..." NL
    mkdir -p "${tmpdir}${bundle_bin_dir}" "${tmpdir}${bundle_lib_dir}" "${tmpdir}${bundle_sysconf_dir}" "${tmpdir}${bundle_usrconf_dir}"
    cp -Lp $(command -v enroot-nsenter enroot-mount enroot-switchroot) "${tmpdir}${bundle_bin_dir}"
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
      "${bundle_bin_dir}" "${bundle_lib_dir}" "${bundle_sysconf_dir}" "${bundle_usrconf_dir}" >&2
)
