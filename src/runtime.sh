# Copyright (c) 2018-2019, NVIDIA CORPORATION. All rights reserved.

source "${ENROOT_LIBEXEC_PATH}/common.sh"

readonly hook_dirs=("${ENROOT_SYSCONF_PATH}/hooks.d" "${ENROOT_CONFIG_PATH}/hooks.d")
readonly mount_dirs=("${ENROOT_SYSCONF_PATH}/mounts.d" "${ENROOT_CONFIG_PATH}/mounts.d")
readonly environ_dirs=("${ENROOT_SYSCONF_PATH}/environ.d" "${ENROOT_CONFIG_PATH}/environ.d")
readonly environ_file="${ENROOT_RUNTIME_PATH}/environment"
readonly mount_file="${ENROOT_RUNTIME_PATH}/fstab"

readonly bundle_dir="/.enroot"
readonly bundle_libexec_dir="${bundle_dir}/libexec"
readonly bundle_sysconf_dir="${bundle_dir}/etc/system"
readonly bundle_usrconf_dir="${bundle_dir}/etc/user"

runtime::_do_mounts() {
    local -r rootfs="$1"
    local -a mounts=()

    readarray -t mounts <<< "$2"

    # Generate the mount configuration file from the rootfs fstab.
    common::envsubst "${rootfs}/etc/fstab" >> "${mount_file}"

    # Generate the mount configuration files from the host directories.
    for dir in "${mount_dirs[@]}"; do
        if [ -d "${dir}" ]; then
            for file in $(common::runparts list .fstab "${dir}"); do
                common::envsubst "${file}" >> "${mount_file}"
            done
        fi
    done

    # Generate the mount configuration file from the user config and CLI arguments.
    if declare -F mounts > /dev/null; then
        mounts >> "${mount_file}"
    fi
    for mount in ${mounts[@]+"${mounts[@]}"}; do
        tr ':' ' ' <<< "${mount}" >> "${mount_file}"
    done

    # Perform all the mounts specified in the configuration files.
    "${ENROOT_LIBEXEC_PATH}/mountat" --root "${rootfs}" "${mount_file}"
}

runtime::_do_environ() {
    local -r rootfs="$1"
    local -a environ=()

    readarray -t environ <<< "$2"

    # Generate the environment configuration file from the rootfs.
    common::envsubst "${rootfs}/etc/environment" >> "${environ_file}"

    # Generate the environment configuration files from the host directories.
    for dir in "${environ_dirs[@]}"; do
        if [ -d "${dir}" ]; then
            for file in $(common::runparts list .env "${dir}"); do
                common::envsubst "${file}" >> "${environ_file}"
            done
        fi
    done

    # Generate the environment configuration file from the user config and CLI arguments.
    if declare -F environ > /dev/null; then
        environ | { grep -v "^ENROOT_" || :; } >> "${environ_file}"
    fi
    for env in ${environ[@]+"${environ[@]}"}; do
        awk '{sub(/^[A-Za-z_][A-Za-z0-9_]*$/, $0"="ENVIRON[$0]); print}' <<< "${env}" >> "${environ_file}"
    done
}

runtime::_do_hooks() {
    local -r rootfs="$1"

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
}

runtime::_do_mount_rootfs() {
    local -r image="$1"
    local -r rootfs="$2"

    local -i euid=${EUID}
    local -i egid=$(stat -c "%g" /proc/$$)
    local -i timeout=10
    local -i pid=0
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

    common::ckcmd squashfuse fuse-overlayfs mountpoint

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
    local -r config="$1"; shift
    local -r mounts="$1"; shift
    local -r environ="$1"; shift

    unset BASH_ENV

    # Setup a temporary working directory.
    "${ENROOT_LIBEXEC_PATH}/mountat" - <<< "tmpfs ${ENROOT_RUNTIME_PATH} tmpfs x-create=dir,mode=600"

    # The rootfs was specified as an image, we need to mount it first before we can use it.
    if [ -f "${rootfs}" ]; then
        runtime::_mount_rootfs "${rootfs}" "${ENROOT_RUNTIME_PATH}/rootfs"
        rootfs="${ENROOT_RUNTIME_PATH}/rootfs"
    fi

    # Setup the rootfs with slave propagation.
    "${ENROOT_LIBEXEC_PATH}/mountat" - <<< "${rootfs} ${rootfs} none bind,nosuid,nodev,slave"

    # Configure the container by performing mounts, setting its environment and executing hooks.
    (
        export ENROOT_PID="$$"
        export ENROOT_ROOTFS="${rootfs}"
        export ENROOT_ENVIRON="${environ_file}"

        if [ -n "${config}" ]; then
            source "${config}"
        fi
        runtime::_do_mounts "${rootfs}" "${mounts}" > /dev/null
        runtime::_do_environ "${rootfs}" "${environ}" > /dev/null
        runtime::_do_hooks "${rootfs}" > /dev/null
    )

    # Remount the rootfs readonly if necessary.
    if [ -z "${ENROOT_ROOTFS_RW}" ]; then
        "${ENROOT_LIBEXEC_PATH}/mountat" - <<< "none ${rootfs} none remount,bind,nosuid,nodev,ro"
    fi

    # Make the bundle directory readonly if present.
    if [ -d "${rootfs}${bundle_dir}" ]; then
        "${ENROOT_LIBEXEC_PATH}/mountat" - <<< "${rootfs}${bundle_dir} ${rootfs}${bundle_dir} none rbind,nosuid,nodev,ro"
    fi

    # Switch to the new root, and invoke the init script.
    if [ -n "${ENROOT_LOGIN_SHELL}" ]; then
        export SHELL="${ENROOT_LOGIN_SHELL}"
    fi
    exec 3< "${ENROOT_LIBEXEC_PATH}/init.sh"
    exec "${ENROOT_LIBEXEC_PATH}/switchroot" --env "${environ_file}" "${rootfs}" -3 "$@"
}

runtime::start() {
    local rootfs="$1"; shift
    local config="$1"; shift
    local mounts="$1"; shift
    local environ="$1"; shift

    common::ckcmd unsquashfs awk grep

    # Resolve the container rootfs path.
    if [ -z "${rootfs}" ]; then
        common::err "Invalid argument"
    fi
    if [ -f "${rootfs}" ] && unsquashfs -s "${rootfs}" > /dev/null 2>&1; then
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
        while read -r mount; do
            if [[ ! "${mount}" =~ ^[^[:space:]]+:[^[:space:]]+$ ]]; then
                common::err "Invalid argument: ${mount}"
            fi
        done <<< "${mounts}"
    fi

    # Check for invalid environment variables.
    if [ -n "${environ}" ]; then
        while read -r env; do
            if [[ ! "${env}" =~ ^[A-Za-z_][A-Za-z0-9_]*(=|$) ]]; then
                common::err "Invalid argument: ${env}"
            fi
        done <<< "${environ}"
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
    exec "${ENROOT_LIBEXEC_PATH}/unsharens" ${ENROOT_REMAP_ROOT:+--root} \
      "${BASH}" -o ${SHELLOPTS//:/ -o } -O ${BASHOPTS//:/ -O } -c \
      'runtime::_start "$@"' "${config}" "${rootfs}" "${config}" "${mounts}" "${environ}" "$@"
}

runtime::create() {
    local image="$1"
    local rootfs="$2"

    common::ckcmd unsquashfs find

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

    # Some distributions require CAP_DAC_OVERRIDE on system directories, work around it
    # (see https://bugzilla.redhat.com/show_bug.cgi?id=517575)
    find "${rootfs}" "${rootfs}/usr" -maxdepth 1 -type d ! -perm -u+w -exec chmod u+w {} \+
}

runtime::import() {
    local -r uri="$1"
    local -r filename="$2"

    # Import a container image from the URI specified.
    case "${uri}" in
    docker://*)
        docker::import "${uri}" "${filename}" ;;
    *)
        common::err "Invalid argument: ${uri}" ;;
    esac
}

runtime::export() {
    local rootfs="$1"
    local filename="$2"

    local excludeopt=""

    common::ckcmd mksquashfs

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

    # Exclude the bundle directory.
    if [ -d "${rootfs}${bundle_dir}" ]; then
        excludeopt="-e ${rootfs}${bundle_dir}"
    fi

    # Export a container image from the rootfs specified.
    common::log INFO "Creating squashfs filesystem..." NL
    mksquashfs "${rootfs}" "${filename}" -all-root ${excludeopt} \
      ${TTY_OFF+-no-progress} ${ENROOT_SQUASH_OPTS}
}

runtime::list() {
    local fancy="$1"

    common::chdir "${ENROOT_DATA_PATH}"

    # List all the container rootfs along with their size.
    if [ -n "${fancy}" ]; then
        if [ -n "$(ls -A)" ]; then
            printf "%b\n" "$(common::fmt bold "SIZE\tIMAGE")"
            du -sh * 2> /dev/null
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

    common::ckcmd unsquashfs awk grep

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

    tmpdir=$(common::mktemp -d)
    trap "common::rmall '${tmpdir}' 2> /dev/null" EXIT

    # Extract the container rootfs from the image.
    common::log INFO "Extracting squashfs filesystem..." NL
    unsquashfs ${TTY_OFF+-no-progress} -user-xattrs -f -d "${tmpdir}" "${image}"
    common::log

    # Copy runtime components to the bundle directory.
    common::log INFO "Generating bundle..." NL
    mkdir -p "${tmpdir}${bundle_libexec_dir}" "${tmpdir}${bundle_sysconf_dir}" "${tmpdir}${bundle_usrconf_dir}"
    cp -a "${ENROOT_LIBEXEC_PATH}"/{unsharens,mountat,switchroot} "${tmpdir}${bundle_libexec_dir}"
    cp -a "${ENROOT_LIBEXEC_PATH}"/{common.sh,runtime.sh,init.sh} "${tmpdir}${bundle_libexec_dir}"

    # Copy runtime configurations to the bundle directory.
    cp -a "${hook_dirs[0]}" "${mount_dirs[0]}" "${environ_dirs[0]}" "${tmpdir}${bundle_sysconf_dir}"
    if [ -n "${ENROOT_BUNDLE_ALL}" ]; then
        [ -d "${hook_dirs[1]}" ] && cp -a "${hook_dirs[1]}" "${tmpdir}${bundle_usrconf_dir}"
        [ -d "${mount_dirs[1]}" ] && cp -a "${mount_dirs[1]}" "${tmpdir}${bundle_usrconf_dir}"
        [ -d "${environ_dirs[1]}" ] && cp -a "${environ_dirs[1]}" "${tmpdir}${bundle_usrconf_dir}"
    fi

    # Make a self-extracting archive with the entrypoint being our bundle script.
    "${ENROOT_LIBEXEC_PATH}/makeself" --tar-quietly --tar-extra '--numeric-owner --owner=0 --group=0 --ignore-failed-read' \
      --nomd5 --nocrc ${ENROOT_BUNDLE_SUM:+--sha256} --header "${ENROOT_LIBEXEC_PATH}/bundle.sh" "${compress}" \
      --target "${target}" "${tmpdir}" "${filename}" "${desc}" -- "${bundle_libexec_dir}" "${bundle_sysconf_dir}" "${bundle_usrconf_dir}"
)
