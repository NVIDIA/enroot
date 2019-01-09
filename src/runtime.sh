# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

readonly HOOKS_DIRS=("${ENROOT_SYSCONF_PATH}/hooks.d" "${ENROOT_CONFIG_PATH}/hooks.d")
readonly MOUNTS_DIRS=("${ENROOT_SYSCONF_PATH}/mounts.d" "${ENROOT_CONFIG_PATH}/mounts.d")
readonly ENVIRON_DIRS=("${ENROOT_SYSCONF_PATH}/environ.d" "${ENROOT_CONFIG_PATH}/environ.d")
readonly WORKING_DIR="${ENROOT_RUNTIME_PATH}/workdir"
readonly ENVIRON_FILE="${WORKING_DIR}/environment"
readonly BUNDLE_DIR="/.enroot"

do_mounts() {
    local -r rootfs="$1"

    # Generate the mount configuration files.
    ln -s "${rootfs}/etc/fstab" "${WORKING_DIR}/00-rootfs.fstab"
    for dir in "${MOUNTS_DIRS[@]}"; do
        if [ -d "${dir}" ]; then
            find "${dir}" -type f -name '*.fstab' -exec ln -s "{}" "${WORKING_DIR}" \;
        fi
    done
    if declare -F mounts > /dev/null; then
        mounts > "${WORKING_DIR}/99-config.fstab"
    fi

    # Perform all the mounts specified in the configuration files.
    "${ENROOT_LIBEXEC_PATH}/mountat" --root "${rootfs}" "${WORKING_DIR}"/*.fstab
}

do_environ() {
    local -r rootfs="$1"

    local envsubst=""

    read -r -d '' envsubst <<- 'EOF' || :
	function envsubst(key, val) {
	    printf key
	    while (match(val, /\$(([A-Za-z_][A-Za-z0-9_]*)|{([A-Za-z_][A-Za-z0-9_]*)})/, arr)) {
	        printf "%s%s", substr(val, 1, RSTART - 1), ENVIRON[arr[2] arr[3]]
	        val = substr(val, RSTART + RLENGTH)
	    }
	    print val
	}
	BEGIN {FS="="; OFS=FS} { key=$1; $1=""; envsubst(key, $0) }
	EOF

    # Generate the environment configuration file.
    if [ -f "${rootfs}/etc/locale.conf" ]; then
        cat "${rootfs}/etc/locale.conf" >> "${ENVIRON_FILE}"
    fi
    awk "${envsubst}" "${rootfs}/etc/environment" >> "${ENVIRON_FILE}"
    for dir in "${ENVIRON_DIRS[@]}"; do
        if [ -d "${dir}" ]; then
            find "${dir}" -type f -name '*.env' -exec awk "${envsubst}" "{}" \; >> "${ENVIRON_FILE}"
        fi
    done
    if declare -F environ > /dev/null; then
        environ | { grep -vE "^ENROOT_" || :; } >> "${ENVIRON_FILE}"
    fi
}

do_hooks() {
    local -r rootfs="$1"

    local -r pattern="(PATH|ENV|TERM|LD_.+|LC_.+|ENROOT_.+)"

    export ENROOT_PID="$$"
    export ENROOT_ROOTFS="${rootfs}"
    export ENROOT_ENVIRON="${ENVIRON_FILE}"
    export ENROOT_WORKDIR="${WORKING_DIR}"

    # Execute the hooks with the environment from the container in addition with the variables defined above.
    # Exclude anything which could affect the proper execution of the hook (e.g. search path, linker, locale).
    unset $(env -0 | sed -z 's/=.*/\n/;s/^BASH_FUNC_\(.\+\)%%/\1/' | tr -d '\000' | { grep -vE "^${pattern}$" || :; })
    while read -r var; do
        if [[ "${var}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ && ! "${var}" =~ ^${pattern}= ]]; then
            export "${var}"
        fi
    done < "${ENVIRON_FILE}"

    for dir in "${HOOKS_DIRS[@]}"; do
        if [ -d "${dir}" ]; then
            find "${dir}" -type f -executable -name '*.sh' -exec "{}" \;
        fi
    done
    if declare -F hooks > /dev/null; then
        hooks > /dev/null
    fi
}

start() {
    local -r rootfs="$1"; shift
    local -r config="$1"; shift

    unset BASH_ENV

    # Setup the rootfs with slave propagation.
    "${ENROOT_LIBEXEC_PATH}/mountat" - <<< "${rootfs} ${rootfs} none bind,nosuid,nodev,slave"

    # Setup a temporary working directory.
    "${ENROOT_LIBEXEC_PATH}/mountat" - <<< "tmpfs ${WORKING_DIR} tmpfs x-create=dir,mode=600"

    # Configure the container by performing mounts, setting its environment and executing hooks.
    (
        if [ -n "${config}" ]; then
            source "${config}"
        fi
        do_mounts "${rootfs}"
        do_environ "${rootfs}"
        do_hooks "${rootfs}"
    )

    # Remount the rootfs readonly if necessary.
    if [ -z "${ENROOT_ROOTFS_RW}" ]; then
        "${ENROOT_LIBEXEC_PATH}/mountat" - <<< "none ${rootfs} none remount,bind,nosuid,nodev,ro"
    fi

    # Make the bundle directory readonly if present.
    if [ -d "${rootfs}${BUNDLE_DIR}" ]; then
        "${ENROOT_LIBEXEC_PATH}/mountat" - <<< "${rootfs}${BUNDLE_DIR} ${rootfs}${BUNDLE_DIR} none rbind,nosuid,nodev,ro"
    fi

    # Switch to the new root, and invoke the init script.
    if [ -n "${ENROOT_INIT_SHELL}" ]; then
        export SHELL="${ENROOT_INIT_SHELL}"
    fi
    exec "${ENROOT_LIBEXEC_PATH}/switchroot" --env "${ENVIRON_FILE}" "${rootfs}" "$(< "${ENROOT_LIBEXEC_PATH}/init.sh")" init "$@"
}

runtime::start() {
    local rootfs="$1"; shift
    local config="$1"; shift

    # Resolve the container rootfs path.
    if [ -z "${rootfs}" ]; then
        err "Invalid argument"
    fi
    if [[ "${rootfs}" == */* ]]; then
        err "Invalid argument: ${rootfs}"
    fi
    rootfs=$(xrealpath "${ENROOT_DATA_PATH}/${rootfs}")
    if [ ! -d "${rootfs}" ]; then
        err "Not such file or directory: ${rootfs}"
    fi

    # Resolve the container configuration path.
    if [ -n "${config}" ]; then
        config=$(xrealpath "${config}")
        if [ ! -f "${config}" ]; then
            err "Not such file or directory: ${config}"
        fi
    fi

    # Create new namespaces and start the container.
    export BASH_ENV="${BASH_SOURCE[0]}"
    exec "${ENROOT_LIBEXEC_PATH}/unsharens" ${ENROOT_REMAP_ROOT:+--root} \
      "${BASH}" -o ${SHELLOPTS//:/ -o } -O ${BASHOPTS//:/ -O } -c 'start "$@"' "${config}" "${rootfs}" "${config}" "$@"
}

runtime::create() {
    local image="$1"
    local rootfs="$2"

    # Resolve the container image path.
    if [ -z "${image}" ]; then
        err "Invalid argument"
    fi
    image=$(xrealpath "${image}")
    if [ ! -f "${image}" ]; then
        err "Not such file or directory: ${image}"
    fi
    if ! unsquashfs -s "${image}" > /dev/null 2>&1; then
        err "Invalid image format: ${image}"
    fi

    # Resolve the container rootfs path.
    if [ -z "${rootfs}" ]; then
        rootfs=$(basename "${image%.squashfs}")
    fi
    if [[ "${rootfs}" == */* ]]; then
        err "Invalid argument: ${rootfs}"
    fi
    rootfs=$(xrealpath "${ENROOT_DATA_PATH}/${rootfs}")
    if [ -e "${rootfs}" ]; then
        err "File already exists: ${rootfs}"
    fi

    # Extract the container rootfs from the image.
    log INFO "Extracting squashfs filesystem..."; logln
    unsquashfs ${LOG_NO_TTY+-no-progress} -user-xattrs -d "${rootfs}" "${image}"

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
        docker::import "${uri}" "${filename}"
        ;;
    *)
        err "Invalid argument: ${uri}"
        ;;
    esac
}

runtime::export() {
    local rootfs="$1"
    local filename="$2"

    local excludeopt=""

    # Resolve the container rootfs path.
    if [ -z "${rootfs}" ]; then
        err "Invalid argument"
    fi
    if [[ "${rootfs}" == */* ]]; then
        err "Invalid argument: ${rootfs}"
    fi
    rootfs=$(xrealpath "${ENROOT_DATA_PATH}/${rootfs}")
    if [ ! -d "${rootfs}" ]; then
        err "No such file or directory: ${rootfs}"
    fi

    # Generate an absolute filename if none was specified.
    if [ -z "${filename}" ]; then
        filename="$(basename "${rootfs}").squashfs"
    fi
    filename=$(xrealpath "${filename}")
    if [ -e "${filename}" ]; then
        err "File already exists: ${filename}"
    fi

    # Exclude the bundle directory.
    if [ -d "${rootfs}${BUNDLE_DIR}" ]; then
        excludeopt="-e ${rootfs}${BUNDLE_DIR}"
    fi

    # Export a container image from the rootfs specified.
    log INFO "Creating squashfs filesystem..."; logln
    mksquashfs "${rootfs}" "${filename}" -all-root ${excludeopt} \
      ${LOG_NO_TTY+-no-progress} ${ENROOT_SQUASH_OPTS}
}

runtime::list() {
    local fancy="$1"

    xcd "${ENROOT_DATA_PATH}"

    # List all the container rootfs along with their size.
    if [ -n "${fancy}" ]; then
        if [ -n "$(ls -A)" ]; then
            printf "%sSIZE\tIMAGE%s\n" "${FMT_BOLD-}" "${FMT_CLEAR-}"
            du -sh *
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
        err "Invalid argument"
    fi
    if [[ "${rootfs}" == */* ]]; then
        err "Invalid argument: ${rootfs}"
    fi
    rootfs=$(xrealpath "${ENROOT_DATA_PATH}/${rootfs}")
    if [ ! -d "${rootfs}" ]; then
        err "No such file or directory: ${rootfs}"
    fi

    # Remove the rootfs specified after asking for confirmation.
    if [ -z "${force}" ]; then
        read -r -e -p "Do you really want to delete ${rootfs}? [y/N] "
    fi
    if [ -n "${force}" ] || [ "${REPLY}" = "y" ] || [ "${REPLY}" = "Y" ]; then
        rmrf "${rootfs}"
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

    # Resolve the container image path.
    if [ -z "${image}" ]; then
        err "Invalid argument"
    fi
    image=$(xrealpath "${image}")
    if [ ! -f "${image}" ]; then
        err "Not such file or directory: ${image}"
    fi
    if ! super=$(unsquashfs -s "${image}" 2> /dev/null); then
        err "Invalid image format: ${image}"
    fi

    # Generate an absolute filename if none was specified.
    if [ -z "${filename}" ]; then
        filename="$(basename "${image%.squashfs}").run"
    fi
    filename=$(xrealpath "${filename}")
    if [ -e "${filename}" ]; then
        err "File already exists: ${filename}"
    fi

    # Generate a target directory if none was specified.
    if [ -z "${target}" ]; then
        target="$(basename "${filename%.run}")"
    fi

    # Use the filename as the description if none was specified.
    if [ -z "${desc}" ]; then
        desc="$(basename "${filename}")"
    fi

    # If the image data is compressed, reuse the same one for the bundle.
    if grep -q "^Data is compressed" <<< "${super}"; then
        compress=$(awk '/^Compression/ { print "--"$2 }' <<< "${super}")
    else
        compress="--nocomp"
    fi

    tmpdir=$(xmktemp -d)
    trap "rmrf '${tmpdir}' 2> /dev/null" EXIT

    # Extract the container rootfs from the image.
    log INFO "Extracting squashfs filesystem..."; logln
    unsquashfs ${LOG_NO_TTY+-no-progress} -user-xattrs -f -d "${tmpdir}" "${image}"

    # Copy runtime components to the bundle directory.
    logln; log INFO "Generating bundle..."; logln
    mkdir -p "${tmpdir}${BUNDLE_DIR}"
    cp -a "${ENROOT_LIBEXEC_PATH}"/{unsharens,mountat,switchroot} "${tmpdir}${BUNDLE_DIR}"
    cp -a "${ENROOT_LIBEXEC_PATH}"/{common.sh,runtime.sh,init.sh} "${tmpdir}${BUNDLE_DIR}"

    # Copy runtime configurations to the bundle directory.
    cp -a "${HOOKS_DIRS[0]}" "${MOUNTS_DIRS[0]}" "${ENVIRON_DIRS[0]}" "${tmpdir}${BUNDLE_DIR}"
    if [ -n "${ENROOT_BUNDLE_ALL}" ]; then
        [ -d "${HOOKS_DIRS[1]}" ] && cp -a "${HOOKS_DIRS[1]}" "${tmpdir}${BUNDLE_DIR}"
        [ -d "${MOUNTS_DIRS[1]}" ] && cp -a "${MOUNTS_DIRS[1]}" "${tmpdir}${BUNDLE_DIR}"
        [ -d "${ENVIRON_DIRS[1]}" ] && cp -a "${ENVIRON_DIRS[1]}" "${tmpdir}${BUNDLE_DIR}"
    fi

    # Make a self-extracting archive with the entrypoint being our bundle script.
    "${ENROOT_LIBEXEC_PATH}/makeself.sh" --tar-quietly --tar-extra '--numeric-owner --owner=0 --group=0 --ignore-failed-read' \
      --nomd5 --nocrc ${ENROOT_BUNDLE_SUM:+--sha256} --header "${ENROOT_LIBEXEC_PATH}/bundle.sh" "${compress}" \
      --target "${target}" "${tmpdir}" "${filename}" "${desc}" true
)
