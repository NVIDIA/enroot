# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

[ -t 2 ] && readonly LOG_TTY=1 || readonly LOG_NO_TTY=1

if [ "${LOG_TTY-0}" -eq 1 ] && [ "$(tput colors)" -ge 15 ]; then
    readonly FMT_CLEAR=$(tput sgr0)
    readonly FMT_BOLD=$(tput bold)
    readonly FMT_RED=$(tput setaf 1)
    readonly FMT_YELLOW=$(tput setaf 3)
    readonly FMT_BLUE=$(tput setaf 12)
fi

log() {
    local -r level="$1"; shift
    local -r message="$*"

    local fmt_on="${FMT_CLEAR-}"
    local -r fmt_off="${FMT_CLEAR-}"

    case "${level}" in
        INFO)  fmt_on="${FMT_BLUE-}" ;;
        WARN)  fmt_on="${FMT_YELLOW-}" ;;
        ERROR) fmt_on="${FMT_RED-}" ;;
    esac
    printf "%s[%s]%s %b\n" "${fmt_on}" "${level}" "${fmt_off}" "${message}" >&2
}

logln() {
    [ "${LOG_NO_TTY-0}" -eq 1 ] || echo >&2
}

err() {
    local -r message="$*"

    log ERROR "${message}"
    exit 1
}

rmrf() {
    local -r path="$1"

    rm --one-file-system --preserve-root -rf "${path}" 2> /dev/null || \
    { chmod -R +w "${path}"; rm --one-file-system --preserve-root -rf "${path}"; }
}

xmktemp() (
    umask 077
    mktemp --tmpdir enroot.XXXXXXXXXX "$@"
)

xread() {
    read "$@" || :
}

xcd() {
    cd "$1" || err "Could not change directory: $1"
}

xcurl() {
    local -i rv=0
    local -i status=0

    exec 9>&1
    { status=$(curl -o /proc/self/fd/9 -w '%{http_code}' "$@") || rv=$?; } 9>&1
    exec 9>&-

    if [ "${status}" -ge 400 ]; then
        for ign in ${XCURL_IGNORE-}; do
            [ "${status}" -eq "${ign}" ] && return
        done
        err "URL ${@: -1} returned error code: ${status}"
    fi
    return ${rv}
}

xrealpath() {
    local -r path="$1"

    local rpath=""

    if ! rpath=$(realpath "${path}" 2> /dev/null); then
        err "No such file or directory: ${path}"
    fi
    echo "${rpath}"
}
