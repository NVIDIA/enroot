cat << EOF > "${archname}"
#! /bin/bash

set -euo pipefail
shopt -s lastpipe

readonly MAKESELF_DESCRIPTION="${LABEL}"
readonly MAKESELF_COMPRESSION="${COMPRESS}"
readonly MAKESELF_TARGET_DIR="${archdirname}"
readonly MAKESELF_FILE_SIZES=(${filesizes})
readonly MAKESELF_SHA256_SUM="${SHAsum}"
readonly MAKESELF_SKIP="${SKIP}"
readonly MAKESELF_SIZE="${USIZE}"
readonly MAKESELF_DECOMPRESS="${GUNZIP_CMD}"

readonly ENROOT_VERSION="@version@"

EOF
cat << 'EOF' >> "${archname}"

makeself::rm() {
    local -r path="$1"

    rm --one-file-system --preserve-root -rf "${path}" 2> /dev/null || \
    { chmod -R +w "${path}"; rm --one-file-system --preserve-root -rf "${path}"; }
}

makeself::dd() {
    local -r file="$1"
    local -r offset="$2"
    local -r size="$3"
    local -r progress="$4"

    local progress_cmd="cat"
    local -r blocks=$((size / 1024))
    local -r bytes=$((size % 1024))

    if [ -n "${progress}" ]; then
        if command -v pv > /dev/null; then
            progress_cmd="pv -s ${size}"
        fi
    fi

    dd status=none if="${file}" ibs="${offset}" skip=1 obs=1024 conv=sync | { \
      if [ "${blocks}" -gt 0 ]; then dd status=none ibs=1024 obs=1024 count="${blocks}"; fi; \
      if [ "${bytes}" -gt 0 ]; then dd status=none ibs=1 obs=1024 count="${bytes}"; fi; \
    } | ${progress_cmd}
}

makeself::check() {
    local -r file="$1"

    local -i offset=0
    local sum1=""
    local sum2=""

    if [[ "0x${MAKESELF_SHA256_SUM}" -eq 0x0 ]]; then
        return
    fi

    offset=$(head -n "${MAKESELF_SKIP}" "${file}" | wc -c | tr -d ' ')

    for i in "${!MAKESELF_FILE_SIZES[@]}"; do
        cut -d ' ' -f $((i + 1)) <<< "${MAKESELF_SHA256_SUM}" | read -r sum1
        makeself::dd "${file}" "${offset}" "${MAKESELF_FILE_SIZES[$i]}" "" | sha256sum | read -r sum2 x
        if [ "${sum1}" != "${sum2}" ]; then
            echo "ERROR: Checksum validation failed" >&2
            exit 1
        fi
        offset=$((offset + ${MAKESELF_FILE_SIZES[$i]}))
    done
}

makeself::extract() {
    local -r file="$1"
    local -r dest="$2"
    local -r quiet="$3"

    local progress=""
    local -i offset=0
    local -i diskspace=0

    if ! command -v "${MAKESELF_DECOMPRESS%% *}" > /dev/null; then
        echo "ERROR: Command not found: ${MAKESELF_DECOMPRESS%% *}" >&2
        exit 1
    fi
    if [ -z "${quiet}" ] && [ -t 2 ]; then
        progress=y
    fi

    offset=$(head -n "${MAKESELF_SKIP}" "${file}" | wc -c | tr -d ' ')
    diskspace=$(df -k --output=avail "${dest}" | tail -1)

    if [ "${diskspace}" -lt "${MAKESELF_SIZE}" ]; then
        echo "ERROR: Not enough space left in $(dirname "${dest}") (${MAKESELF_SIZE} KB needed)" >&2
        exit 1
    fi
    for i in "${!MAKESELF_FILE_SIZES[@]}"; do
        makeself::dd "${file}" "${offset}" "${MAKESELF_FILE_SIZES[$i]}" "${progress}" | ${MAKESELF_DECOMPRESS} | tar -C "${dest}" -pxf -
        offset=$((offset + ${MAKESELF_FILE_SIZES[$i]}))
    done

    touch "${dest}"
}

usage() {
    echo "Usage: ${0##*/} [--info|-i] [--keep|-k] [--quiet|-q] [--root|-r] [--rw|-w] [--conf|-c CONFIG] [COMMAND] [ARG...]"
    exit 0
}

info() {
    cat <<- EOR
	Description: ${MAKESELF_DESCRIPTION}
	Compression: ${MAKESELF_COMPRESSION}
	Target directory: ${MAKESELF_TARGET_DIR}
	Runtime version: ${ENROOT_VERSION}
	Uncompressed size: ${MAKESELF_SIZE} KB
	EOR
    if [[ "0x${MAKESELF_SHA256_SUM}" -ne 0x0 ]]; then
        echo "Checksum: ${MAKESELF_SHA256_SUM}"
    fi
    exit 0
}

keep=""
quiet=""
conf=""
rw=""
root=""

makeself::check "$0"

while [ $# -gt 0 ]; do
    case "$1" in
    -i|--info)
        info
        ;;
    -k|--keep)
        keep=y
        shift
        ;;
    -q|--quiet)
        quiet=y
        shift
        ;;
    -c|--conf)
        [ -z "${2-}" ] && usage
        conf="$2"
        shift 2
        ;;
    -r|--root)
        root=y
        shift
        ;;
    -w|--rw)
        rw=y
        shift
        ;;
    --)
        shift
        break
        ;;
    -?*)
        usage
        ;;
    *)
        break
        ;;
    esac
done

if [ -n "${keep}" ]; then
    rootfs=$(realpath "${MAKESELF_TARGET_DIR}")
    if [ -e "${rootfs}" ]; then
        echo "ERROR: File already exists: ${rootfs}" >&2
        exit 1
    fi
    mkdir -p "${rootfs}"
else
    rootfs=$(mktemp -d --tmpdir ${MAKESELF_TARGET_DIR##*/}.XXXXXXXXXX)
    trap "makeself::rm '${rootfs}' 2> /dev/null" EXIT
fi

makeself::extract "$0" "${rootfs}" "${quiet}"
set +e
(
    set -e

    export ENROOT_LIBEXEC_PATH="${rootfs}/.enroot"
    export ENROOT_SYSCONF_PATH="${rootfs}/.enroot"
    export ENROOT_CONFIG_PATH="${rootfs}"
    export ENROOT_DATA_PATH="${rootfs}"
    export ENROOT_RUNTIME_PATH="/run"
    export ENROOT_INIT_SHELL="/bin/sh"
    export ENROOT_ROOTFS_RW="${rw}"
    export ENROOT_REMAP_ROOT="${root}"

    source "${ENROOT_LIBEXEC_PATH}/common.sh"
    source "${ENROOT_LIBEXEC_PATH}/runtime.sh"

    runtime::start . "${conf}" "$@"
)
exit $?
EOF
