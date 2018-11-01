# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

[ -n "${SOURCE_RUNTIME_SH-}" ] && return || readonly SOURCE_RUNTIME_SH=1

source "${ENROOT_LIBEXEC_PATH}/common.sh"
source "${ENROOT_LIBEXEC_PATH}/docker.sh"

readonly HOOKS_DIRS=("${ENROOT_SYSCONF_PATH}/hooks.d" "${ENROOT_CONFIG_PATH}/hooks.d")
readonly MOUNTS_DIRS=("${ENROOT_SYSCONF_PATH}/mounts.d" "${ENROOT_CONFIG_PATH}/mounts.d")
readonly ENVIRON_DIRS=("${ENROOT_SYSCONF_PATH}/environ.d" "${ENROOT_CONFIG_PATH}/environ.d")
readonly UNSHARENS_UTIL="${ENROOT_LIBEXEC_PATH}/utils/unsharens"
readonly SWITCHROOT_UTIL="${ENROOT_LIBEXEC_PATH}/utils/switchroot"
readonly INIT_SCRIPT="${ENROOT_LIBEXEC_PATH}/init.sh"
readonly WORKING_DIR="${ENROOT_RUNTIME_PATH}/workdir"
readonly ENVIRON_FILE="${WORKING_DIR}/environment"

do_mounts() {
    local -r rootfs="$1"

    # Generate the mount configuration files.
    cp "${rootfs}/etc/fstab" "${WORKING_DIR}/00-rootfs.fstab"
    for dir in "${MOUNTS_DIRS[@]}"; do
        if [ -d "${dir}" ]; then
            find "${dir}" -type f -name '*.fstab' -exec cp {} "${WORKING_DIR}" \;
        fi
    done
    if declare -F mounts > /dev/null; then
        mounts > "${WORKING_DIR}/99-config.fstab"
    fi

    # Attempt to create files and directories in the rootfs if necessary.
    awk '($4 ~ "create=(file|dir)"){ if ($4 ~ "file") sub("[^/]*$", "", $2); print $2 }' "${WORKING_DIR}"/*.fstab \
      | ( PATH=/usr/sbin:/usr/bin:/sbin:/bin xargs -r chroot "${rootfs}" mkdir -p || true ) 2> /dev/null
    awk '($4 ~ "create=file"){ print $2 }' "${WORKING_DIR}"/*.fstab \
      | ( PATH=/usr/sbin:/usr/bin:/sbin:/bin xargs -r chroot "${rootfs}" touch || true ) 2> /dev/null
    sed -i 's/create=\(file\|dir\),\?//g' "${WORKING_DIR}"/*.fstab

    # Perform all the mounts specified in the configuration files.
    ( xcd "${rootfs}"; xfakeroot mount -n -a -T "${WORKING_DIR}" )
}

do_environ() {
    local -r rootfs="$1"

    # Generate the environment configuration file.
    if [ -f "${rootfs}/etc/locale.conf" ]; then
        cat "${rootfs}/etc/locale.conf" >> "${ENVIRON_FILE}"
    fi
    envsubst < "${rootfs}/etc/environment" >> "${ENVIRON_FILE}"
    for dir in "${ENVIRON_DIRS[@]}"; do
        if [ -d "${dir}" ]; then
            find "${dir}" -type f -name '*.env' -exec sh -c 'envsubst < "$1"' -- {} \; >> "${ENVIRON_FILE}"
        fi
    done
    if declare -F environ > /dev/null; then
        environ | grep -vE "^ENROOT_" >> "${ENVIRON_FILE}"
    fi

    # Swap the environment with the one specified in the configuration file excluding PATH and LD_LIBRARY_PATH.
    unset $(env | cut -d= -f1 | grep -vE "^(PATH|LD_LIBRARY_PATH)$")
    while read -r var; do
        if [[ -n "${var}" && ! "${var}" =~ ^(PATH|LD_LIBRARY_PATH)= ]]; then
            export "${var}"
        fi
    done < "${ENVIRON_FILE}"
}

do_hooks() {
    local -r rootfs="$1"

    export ENROOT_PID="$$"
    export ENROOT_ROOTFS="${rootfs}"
    export ENROOT_ENVIRON="${ENVIRON_FILE}"

    # Execute all the hooks with the environment from the container in addition with the variables above.
    for dir in "${HOOKS_DIRS[@]}"; do
        if [ -d "${dir}" ]; then
            find "${dir}" -type f -executable -name '*.sh' -print0 | xargs -n 1 -0 sh -c
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

    # Setup a temporary working directory.
    mkdir -p "${WORKING_DIR}"
    xfakeroot mount -n -t tmpfs -o mode=600 tmpfs "${WORKING_DIR}"

    # Setup the rootfs with slave propagation.
    xfakeroot mount -n --bind "${rootfs}" "${rootfs}"
    xfakeroot mount -n --make-slave "${rootfs}"

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
        xfakeroot mount -n -o remount,bind,nosuid,ro "${rootfs}"
    fi

    # Switch to the new root, and invoke the init script.
    if [ -n "${ENROOT_INIT_SHELL}" ]; then
        export SHELL="${ENROOT_INIT_SHELL}"
    fi
    exec "${SWITCHROOT_UTIL}" --env "${ENVIRON_FILE}" "${rootfs}" "$(< ${INIT_SCRIPT})" "${INIT_SCRIPT}" "$@"
}

runtime_create() {
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
    if ! file "${image}" | grep -i squashfs > /dev/null; then
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

runtime_start() {
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
    exec "${UNSHARENS_UTIL}" ${ENROOT_REMAP_ROOT:+--root} "${BASH}" -o ${SHELLOPTS//:/ -o } -O ${BASHOPTS//:/ -O } -c \
      'start "$@"' -- "${rootfs}" "${config}" "$@"
}

runtime_import() {
    local -r uri="$1"
    local -r filename="$2"

    # Import a container image from the URI specified.
    case "${uri}" in
    docker://*)
        docker_import "${uri}" "${filename}"
        ;;
    *)
        err "Invalid argument: ${uri}"
        ;;
    esac
}

runtime_list() {
    xcd "${ENROOT_DATA_PATH}"

    # List all the container rootfs along with their size.
    if [ -n "$(ls -A)" ]; then
        printf "%sSIZE\tIMAGE%s\n" "${FMT_BOLD-}" "${FMT_CLEAR-}"
        du -sh *
    fi
}

runtime_remove() {
    local rootfs="$1"

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
    read -r -e -p "Do you really want to delete ${rootfs}? [y/N] "
    if [ "${REPLY}" = "y" ] || [ "${REPLY}" = "Y" ]; then
        removeall "${rootfs}"
    fi
}
