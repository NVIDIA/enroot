# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

[ -n "${_COMMON_SH_-}" ] && return || readonly _COMMON_SH_=1

[ -t 2 ] && readonly TTY_ON=y || readonly TTY_OFF=y

if [ -n "${TTY_ON-}" ]; then
    if [ -x "$(command -v tput)" ] && [ "$(tput colors)" -ge 15 ]; then
        readonly clr=$(tput sgr0)
        readonly bold=$(tput bold)
        readonly red=$(tput setaf 1)
        readonly yellow=$(tput setaf 3)
        readonly blue=$(tput setaf 12)
    fi
fi

common::fmt() {
    local -r fmt="$1"
    local -r str="$2"

    printf "%s%s%s" "${!fmt-}" "${str}" "${clr-}"
}

common::log() {
    local -r lvl="${1-}"
    local -r msg="${2-}"
    local -r mod="${3-}"

    local prefix=""

    if [ -n "${msg}" ]; then
        case "${lvl}" in
            INFO)  prefix=$(common::fmt blue "[INFO]") ;;
            WARN)  prefix=$(common::fmt yellow "[WARN]") ;;
            ERROR) prefix=$(common::fmt red "[ERROR]") ;;
        esac
        printf "%s %b\n" "${prefix}" "${msg}" >&2
    fi
    if [ -n "${TTY_ON-}" ]; then
        if [ $# -eq 0 ] || [ "${mod}" = "NL" ]; then
            echo >&2
        fi
    fi
}

common::err() {
    local -r msg="$1"

    common::log ERROR "${msg}"
    exit 1
}

common::rmall() {
    local -r path="$1"

    rm --one-file-system --preserve-root -rf "${path}" 2> /dev/null || \
    { chmod -R +w "${path}"; rm --one-file-system --preserve-root -rf "${path}"; }
}

common::mktemp() (
    umask 077
    mktemp --tmpdir enroot.XXXXXXXXXX "$@"
)

common::read() {
    read "$@" || :
}

common::chdir() {
    cd "$1" 2> /dev/null || common::err "Could not change directory: $1"
}

common::curl() {
    local -i rv=0
    local -i status=0

    exec {stdout}>&1
    { status=$(curl -o "/proc/self/fd/${stdout}" -w '%{http_code}' "$@") || rv=$?; } {stdout}>&1
    exec {stdout}>&-

    if [ "${status}" -ge 400 ]; then
        for ign in ${CURL_IGNORE-}; do
            [ "${status}" -eq "${ign}" ] && return
        done
        common::err "URL ${@: -1} returned error code: ${status}"
    fi
    return ${rv}
}

common::realpath() {
    local -r path="$1"

    local rpath=""

    if ! rpath=$(readlink -f "${path}" 2> /dev/null); then
        common::err "No such file or directory: ${path}"
    fi
    echo "${rpath}"
}

common::envsubst() {
    local -r file="$1"

    awk '{
        line=$0
        while (match(line, /\${[A-Za-z_][A-Za-z0-9_]*}/)) {
            output = substr(line, 1, RSTART - 1)
            envvar = substr(line, RSTART, RLENGTH)

            gsub(/\$|{|}/, "", envvar)
            printf "%s%s", output, ENVIRON[envvar]

            line = substr(line, RSTART + RLENGTH)
        }
        print line
    }' "${file}"
}
