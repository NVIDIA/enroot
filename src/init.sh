# Copyright (c) 2018-2019, NVIDIA CORPORATION. All rights reserved.

set -eu

# If we have been called from a file descriptor, close it.
if [ "${0%/*}" = "/proc/self/fd" ]; then
    eval exec "${0##*/}<&-"
fi

# Parse the default login settings.
if [ -f /etc/login.defs ]; then
    while read -r key value; do
        case "${key}" in
        ""|\#*) continue ;;
        *)      readonly "def_${key}=${value}" ;;
        esac
    done < /etc/login.defs
fi

# Parse the uid mappings of the current user.
read -r euid muid x < /proc/self/uid_map

# Parse the username and shell of the current user.
if [ -f /etc/passwd ]; then
    while IFS=':' read -r username x uid x x x shell; do
        [ "${uid}" = "${muid}" ] && break
    done < /etc/passwd
fi

is_abs_path() {
    case "$1" in
    /*) return 0 ;;
    *)  return 1 ;;
    esac
}

is_env_set() {
    ( POSIXLY_CORRECT=1 export ) | {
        while read -r x var; do
            case "${var}" in
            $1=*) return 0 ;;
            esac
        done
        return 1
    }
}

print_file() {
    while IFS= read -r line; do
        printf "%s\n" "${line}"
    done < "$1"
}

display_motd() {
    if [ -z "${def_MOTD_FILE-}" ]; then
        return
    fi
    if [ -n "${def_HUSHLOGIN_FILE-}" ]; then
        if is_abs_path "${def_HUSHLOGIN_FILE}"; then
            [ -e "${def_HUSHLOGIN_FILE}" ] && return
        else
            [ -n "${HOME-}" ] && [ -e "${HOME}/${def_HUSHLOGIN_FILE}" ] && return
        fi
    fi
    IFS=':'
    for file in ${def_MOTD_FILE}; do
        [ -f "${file}" ] && print_file "${file}"
    done
    unset IFS
}

# Check if non-root login is allowed.
if [ "${euid}" -ne 0 ]; then
    if [ -n "${def_NOLOGINS_FILE-}" ] && [ -f "${def_NOLOGINS_FILE}" ]; then
        print_file "${def_NOLOGINS_FILE}"
        exit 0
    fi
fi

# Set the default environment variables (PATH, HOME, SHELL, USER, LOGNAME, MAIL, TZ, LANG/LC_*).
if ! is_env_set PATH; then
    if [ "${euid}" -eq 0 ]; then
        case "${def_ENV_SUPATH-}" in
        PATH=*) export "${def_ENV_SUPATH}" ;;
        *)      export "PATH=/sbin:/bin:/usr/sbin:/usr/bin" ;;
        esac
    else
        case "${def_ENV_PATH-}" in
        PATH=*) export "${def_ENV_PATH}" ;;
        *)      export "PATH=/bin:/usr/bin" ;;
        esac
    fi
fi
if ! is_env_set HOME; then
    if [ "${euid}" -eq 0 ]; then
        export "HOME=$(echo ~root)"
    elif [ -n "${username-}" ]; then
        export "HOME=$(eval echo "~${username}")"
    fi
fi
if ! is_env_set SHELL; then
    if [ -n "${shell-}" ]; then
        export "SHELL=${shell}"
    fi
fi
if [ -z "${USER-}" ]; then
    if [ "${euid}" -eq 0 ]; then
        export "USER=root"
    elif [ -n "${username-}" ]; then
        export "USER=${username}"
    fi
fi
if [ -z "${LOGNAME-}" ] && [ -n "${username-}" ]; then
    export "LOGNAME=${username}"
fi
if [ -z "${MAIL-}" ] && [ -n "${def_MAIL_DIR-}" ]; then
    if [ "${euid}" -eq 0 ]; then
        export "MAIL=${def_MAIL_DIR}/root"
    elif [ -n "${username-}" ]; then
        export "MAIL=${def_MAIL_DIR}/${username}"
    fi
fi
if [ -z "${MAIL-}" ] && [ -n "${HOME-}" ] && [ -n "${def_MAIL_FILE-}" ]; then
    export "MAIL=${HOME}/${def_MAIL_FILE}"
fi
if [ -z "${TZ-}" ] && [ -n "${def_ENV_TZ-}" ]; then
    if is_abs_path "${def_ENV_TZ}" && [ -f "${def_ENV_TZ}" ]; then
        read -r timezone < "${def_ENV_TZ}"
    else
        timezone="${def_ENV_TZ}"
    fi
    case "${timezone}" in
    TZ=*) export "${timezone}" ;;
    esac
fi
if [ -f /etc/locale.conf ]; then
    while IFS='=' read -r key value; do
        case "${key}" in
        LC_ALL)
            continue ;;
        LANG|LANGUAGE|LC_*)
            if [ -z "$(eval echo "\${${key}-}")" ]; then
                export "${key}=${value}"
            fi
            ;;
        esac
    done < /etc/locale.conf
fi

# Set the default ulimit.
if [ -n "${def_ULIMIT-}" ]; then
    ulimit -f "${def_ULIMIT}"
fi

# Set the default umask.
if [ -n "${def_UMASK-}" ]; then
    umask "${def_UMASK}"
fi

# Change to the user home directory.
cd /
if [ -n "${HOME-}" ]; then
    if [ "${def_DEFAULT_HOME:-no}" = "yes" ]; then
        cd "${HOME}" 2> /dev/null || :
    else
        cd "${HOME}" || exit 1
    fi
fi
unset OLDPWD

# Record the last login time.
if [ "${def_LASTLOG_ENAB:-no}" = "yes" ] && [ -x "$(command -v lastlog)" ]; then
    lastlog -u "${euid}" -S > /dev/null 2>&1 || :
fi

# Execute the entrypoint of the container if it exists.
# If not, run the command passed in arguments or fallback to an interactive shell.

# XXX Detect if we're being executed from busybox because /proc/self/exe won't work.
exe=$(readlink -f /proc/$$/exe 2> /dev/null || :)
[ "${exe##*/}" = "busybox" ] && exe=sh

if [ -s /etc/rc ]; then
    if [ -x /etc/rc ]; then
        exec /etc/rc "$@"
    else
        exec "${exe:-/proc/self/exe}" /etc/rc "$@"
    fi
elif [ $# -gt 0 ]; then
    exec "${exe:-/proc/self/exe}" -c "$*"
elif [ -n "${def_FAKE_SHELL-}" ] && [ -x "${def_FAKE_SHELL}" ]; then
    display_motd
    exec "${def_FAKE_SHELL}"
elif [ -n "${SHELL-}" ] && [ -x "${SHELL}" ]; then
    display_motd
    exec "${SHELL}"
else
    display_motd
    exec /bin/sh
fi

exit 127
