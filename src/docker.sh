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

source "${ENROOT_LIBRARY_PATH}/common.sh"

readonly token_dir="${ENROOT_CACHE_PATH}/.tokens.${EUID}"
readonly creds_file="${ENROOT_CONFIG_PATH}/.credentials"

if [ -n "${ENROOT_ALLOW_HTTP-}" ]; then
    readonly curl_proto="http"
    readonly curl_opts=("--proto" "=http,https" "--connect-timeout" "${ENROOT_CONNECT_TIMEOUT}" "--max-time" "${ENROOT_TRANSFER_TIMEOUT}" "-SsL")
else
    readonly curl_proto="https"
    readonly curl_opts=("--proto" "=https" "--connect-timeout" "${ENROOT_CONNECT_TIMEOUT}" "--max-time" "${ENROOT_TRANSFER_TIMEOUT}" "-SsL")
fi

docker::_authenticate() {
    local -r user="$1" registry="$2" url="$3"
    local realm= token= req_params=() resp_headers=

    # Query the registry to see if we're authorized.
    common::log INFO "Querying registry for permission grant"
    resp_headers=$(CURL_IGNORE=401 common::curl "${curl_opts[@]}" -I ${req_params[@]+"${req_params[@]}"} -- "${url}")

    # If we don't need to authenticate, we're done.
    if ! grep -qi '^www-authenticate:' <<< "${resp_headers}"; then
        common::log INFO "Permission granted"
        return
    fi

    # Otherwise, craft a new token request from the WWW-Authenticate header.
    printf "%s" "${resp_headers}" | awk -F '="|",' '(tolower($1) ~ "^www-authenticate:"){
        sub(/"\r/, "", $0)
        print $2
        for (i=3; i<=NF; i+=2) print "--data-urlencode\n" $i"="$(i+1)
    }' | { common::read -r realm; readarray -t req_params; }

    if [ -z "${realm}" ]; then
        common::err "Could not parse authentication realm from ${url}"
    fi

    # If a user was specified, lookup his credentials.
    common::log INFO "Authenticating with user: ${user:-<anonymous>}"
    if [ -n "${user}" ]; then
        if grep -qs "machine[[:space:]]\+${registry}[[:space:]]\+login[[:space:]]\+${user}" "${creds_file}"; then
            common::log INFO "Using credentials from file: ${creds_file}"
            exec {fd}< <(common::evalnetrc "${creds_file}" 2> /dev/null)
            req_params+=("--netrc-file" "/proc/self/fd/${fd}")
        else
            req_params+=("-u" "${user}")
        fi
    fi

    # Request a new token.
    common::curl "${curl_opts[@]}" -G ${req_params[@]+"${req_params[@]}"} -- "${realm}" \
      | jq -r '.token? // .access_token? // empty' \
      | common::read -r token

    [ -v fd ] && exec {fd}>&-

    # Store the new token.
    if [ -n "${token}" ]; then
        mkdir -m 0700 -p "${token_dir}"
        (umask 077 && printf 'header "Authorization: Bearer %s"' "${token}" > "${token_dir}/${registry}.$$")
        common::log INFO "Authentication succeeded"
    fi
}

docker::_download_extract() (
    local -r digest="$1"; shift
    local curl_args=("$@")
    local tmpfile= checksum=

    set -euo pipefail
    shopt -s lastpipe
    umask 037

    [ -e "${ENROOT_CACHE_PATH}/${digest}" ] && exit 0

    trap 'common::rmall "${tmpfile}" 2> /dev/null' EXIT
    tmpfile=$(mktemp -p "${ENROOT_CACHE_PATH}" "${digest}.XXXXXXXXXX")

    exec {stdout}>&1
    {
        curl "${curl_args[@]}" | tee "/proc/self/fd/${stdout}" \
          | "${ENROOT_GZIP_PROGRAM}" -d -f -c \
          | zstd -T"$(expr "${ENROOT_MAX_PROCESSORS}" / "${ENROOT_MAX_CONNECTIONS}" \| 1)" -q -f -o "${tmpfile}" ${ENROOT_ZSTD_OPTIONS}
    } {stdout}>&1 | sha256sum | common::read -r checksum x
    exec {stdout}>&-

    if [ "${digest}" != "${checksum}" ]; then
        printf "Checksum mismatch: %s\n" "${digest}" >&2
        exit 1
    fi

    mv -n "${tmpfile}" "${ENROOT_CACHE_PATH}/${digest}"
)

docker::_download() {
    local -r user="$1" registry="${2:-registry-1.docker.io}" tag="${4:-latest}" arch="$5"
    local image="$3"

    if  [[ "${image}" != */* ]]; then
        image="library/${image}"
    fi

    local layers=() missing_digests=() cached_digests= manifest= config=
    local req_params=("-H" "Accept: application/vnd.docker.distribution.manifest.v2+json")
    local url_manifest="${curl_proto}://${registry}/v2/${image}/manifests/${tag}"
    local -r url_digest="${curl_proto}://${registry}/v2/${image}/blobs/"

    # Authenticate with the registry.
    docker::_authenticate "${user}" "${registry}" "${url_manifest}"
    if [ -f "${token_dir}/${registry}.$$" ]; then
        req_params+=("-K" "${token_dir}/${registry}.$$")
    fi

    # Attempt to use the image manifest list if it exists.
    common::log INFO "Fetching image manifest list"
    CURL_IGNORE="401 404" common::curl "${curl_opts[@]}" "${req_params[@]/manifest/manifest.list}" -- "${url_manifest}" \
      | jq -r "(.manifests[] | select(.platform.architecture == \"${arch}\") | .digest)? // empty" \
      | common::read -r manifest

    if [ -n "${manifest}" ]; then
        url_manifest="${curl_proto}://${registry}/v2/${image}/manifests/${manifest}"
    fi

    # Fetch the image manifest.
    common::log INFO "Fetching image manifest"
    common::curl "${curl_opts[@]}" "${req_params[@]}" -- "${url_manifest}" \
      | jq -r '(.config.digest | ltrimstr("sha256:"))? // empty, ([.layers[].digest | ltrimstr("sha256:")] | reverse | @tsv)?' \
      | { common::read -r config; IFS=$'\t' common::read -r -a layers; }

    if [ -z "${config}" ] || [ "${#layers[@]}" -eq 0 ]; then
        common::err "Could not parse digest information from ${url_manifest}"
    fi
    missing_digests=("${config}" "${layers[@]}")

    # Check which digests are already cached.
    printf "%s\n" "${config}" "${layers[@]}" \
      | sort - <(ls "${ENROOT_CACHE_PATH}") \
      | uniq -d \
      | paste -sd '|' - \
      | common::read -r cached_digests

    if [ -n "${cached_digests}" ]; then
        printf "%s\n" "${config}" "${layers[@]}" \
          | { grep -Ev "${cached_digests}" || :; } \
          | readarray -t missing_digests
    fi

    # Download digests, verify their checksums and extract them in the cache.
    if [ "${#missing_digests[@]}" -gt 0 ]; then
        common::log INFO "Downloading ${#missing_digests[@]} missing layers..." NL
        BASH_ENV="${BASH_SOURCE[0]}" parallel --plain ${TTY_ON+--bar} --shuf --retries 2 -j "${ENROOT_MAX_CONNECTIONS}" -q \
          docker::_download_extract "{}" "${curl_opts[@]}" -f "${req_params[@]}" -- "${url_digest}sha256:{}" ::: "${missing_digests[@]}"
        common::log
    else
        common::log INFO "Found all layers in cache"
    fi

    # Return the container configuration along with all the layers.
    printf "%s\n" "${config}" "${layers[*]}"
}

docker::configure() {
    local -r rootfs="$1" config="$2" arch="${3-}"
    local -r fstab="${rootfs}/etc/fstab" initrc="${rootfs}/etc/rc" rclocal="${rootfs}/etc/rc.local" environ="${rootfs}/etc/environment"
    local entrypoint=() cmd=() workdir= platform=

    mkdir -p "${fstab%/*}" "${initrc%/*}" "${environ%/*}"

    if [ -n "${arch}" ]; then
        # Check if the config architecture matches what we expect.
        jq -r '(.architecture // .Architecture)? // empty' "${config}" | common::read -r platform
        if [ "${arch}" != "${platform}" ]; then
            common::log WARN "Image architecture doesn't match the requested one: ${platform} != ${arch}"
        fi
    fi

    # Configure volumes as simple rootfs bind mounts.
    jq -r '(.config.Volumes)? // empty | keys[] | "${ENROOT_ROOTFS}\(.) \(.) none x-create=dir,bind,rw,nosuid,nodev"' "${config}" > "${fstab}"

    # Configure environment variables.
    jq -r '(.config.Env[])? // empty' "${config}" > "${environ}"

    # Configure labels as comments.
    jq -r '(.config.Labels)? // empty | to_entries[] | "# \(.key) \(.value)"' "${config}" > "${initrc}"
    [ -s "${initrc}" ] && echo >> "${initrc}"

    # Generate the rc script with the working directory, the entrypoint and the command.
    jq -r '(.config.WorkingDir)? // empty' "${config}" | common::read -r workdir
    jq -r '(.config.Entrypoint[])? // empty' "${config}" | readarray -t entrypoint
    jq -r '(.config.Cmd[])? // empty' "${config}" | readarray -t cmd
    if [ "${#entrypoint[@]}" -eq 0 ] && [ "${#cmd[@]}" -eq 0 ]; then
        cmd=("/bin/sh")
    fi

    # Create the working directory if it doesn't exist.
    mkdir -p "${rootfs}${workdir:-/}"

    cat >> "${initrc}" <<- EOF
	mkdir -p "${workdir:-/}" 2> /dev/null
	cd "${workdir:-/}" && unset OLDPWD || exit 1
	
	if [ -s /etc/rc.local ]; then
	    . /etc/rc.local
	fi
	
	if [ \$# -gt 0 ]; then
	    exec ${entrypoint[@]+${entrypoint[@]@Q}} "\$@"
	else
	    exec ${entrypoint[@]+${entrypoint[@]@Q}} ${cmd[@]+${cmd[@]@Q}}
	fi
	EOF

    # Generate an empty rc.local script.
    cat > "${rclocal}" <<- EOF
	# This file is sourced by /etc/rc when the container starts.
	# It can be used to manipulate the entrypoint or the command of the container.
	EOF
}

docker::import() (
    local -r uri="$1"
    local filename="$2" arch="$3"
    local layers=() config= image= registry= tag= user= tmpdir=

    common::checkcmd curl grep awk jq parallel tar "${ENROOT_GZIP_PROGRAM}" find mksquashfs zstd

    # Parse the image reference of the form 'docker://[<user>@][<registry>#]<image>[:<tag>]'.
    local -r reg_user="[[:alnum:]_.!~*\'()%\;:\&=+$,-@]+"
    local -r reg_registry="[^#]+"
    local -r reg_image="[[:lower:][:digit:]/._-]+"
    local -r reg_tag="[[:alnum:]._:-]+"

    if [[ "${uri}" =~ ^docker://((${reg_user})@)?((${reg_registry})#)?(${reg_image})(:(${reg_tag}))?$ ]]; then
        user="${BASH_REMATCH[2]}"
        registry="${BASH_REMATCH[4]}"
        image="${BASH_REMATCH[5]}"
        tag="${BASH_REMATCH[7]}"
    else
        common::err "Invalid image reference: ${uri}"
    fi

    # Convert the architecture to the debian format.
    if [ -n "${arch}" ]; then
        arch=$(common::debarch "${arch}")
    fi

    # XXX Try to infer the user and the registry from the credential file.
    # This is especially useful if the registry has been mistakenly specified as part of the image (i.e. nvcr.io/nvidia/cuda).
    if [ -s "${creds_file}" ]; then
        if [ -n "${registry}" ] && [ -z "${user}" ]; then
            user="$(awk "/^[[:space:]]*machine[[:space:]]+${registry}[[:space:]]+login[[:space:]]+.+/ { print \$4; exit }" "${creds_file}")"
        elif [ -z "${registry}" ] && [ -z "${user}" ] && [[ "${image}" == */* ]]; then
            user="$(awk "/^[[:space:]]*machine[[:space:]]+${image%%/*}[[:space:]]+login[[:space:]]+.+/ { print \$4; exit }" "${creds_file}")"
            if [ -n "${user}" ]; then
                registry="${image%%/*}"
                image="${image#*/}"
            fi
        fi
    fi

    # Generate an absolute filename if none was specified.
    if [ -z "${filename}" ]; then
        filename="${image////+}${tag:++${tag}}.sqsh"
    fi
    filename=$(common::realpath "${filename}")
    if [ -e "${filename}" ]; then
        common::err "File already exists: ${filename}"
    fi

    # Create a temporary directory and chdir to it.
    trap 'common::rmall "${tmpdir}" 2> /dev/null; rm -f "${token_dir}"/*.$$ 2> /dev/null' EXIT
    tmpdir=$(common::mktmpdir enroot)
    common::chdir "${tmpdir}"

    # Download the image digests and store them in cache.
    docker::_download "${user}" "${registry}" "${image}" "${tag}" "${arch}" \
      | { common::read -r config; IFS=' ' common::read -r -a layers; }

    # Extract all the layers locally.
    common::log INFO "Extracting image layers..." NL
    parallel --plain ${TTY_ON+--bar} -j "${ENROOT_MAX_PROCESSORS}" mkdir {\#}\; tar -C {\#} --warning=no-timestamp --anchored --exclude='dev/*' \
      --use-compress-program=zstd -pxf \'"${ENROOT_CACHE_PATH}/{}"\' ::: "${layers[@]}"
    common::fixperms .
    common::log

    # Convert the AUFS whiteouts to the OVLFS ones.
    common::log INFO "Converting whiteouts..." NL
    parallel --plain ${TTY_ON+--bar} -j "${ENROOT_MAX_PROCESSORS}" enroot-aufs2ovlfs {\#} ::: "${layers[@]}"
    common::log

    # Configure the rootfs.
    mkdir 0
    zstd -q -d -o config "${ENROOT_CACHE_PATH}/${config}"
    docker::configure "${PWD}/0" config "${arch}"

    # Create the final squashfs filesystem by overlaying all the layers.
    common::log INFO "Creating squashfs filesystem..." NL
    mkdir rootfs
    MOUNTPOINT="${PWD}/rootfs" \
    enroot-mksquashovlfs "0:$(seq -s: 1 "${#layers[@]}")" "${filename}" -all-root ${TTY_OFF+-no-progress} -processors "${ENROOT_MAX_PROCESSORS}" ${ENROOT_SQUASH_OPTIONS} >&2
)

docker::daemon::import() (
    local -r uri="$1"
    local filename="$2" arch="$3"
    local image= tmpdir=

    common::checkcmd jq docker mksquashfs tar

    # Parse the image reference of the form 'dockerd://<image>[:<tag>]'.
    local -r reg_image="[[:alnum:]/._:-]+"

    if [[ "${uri}" =~ ^dockerd://(${reg_image})$ ]]; then
        image="${BASH_REMATCH[1]}"
    else
        common::err "Invalid image reference: ${uri}"
    fi

    # Convert the architecture to the debian format.
    if [ -n "${arch}" ]; then
        arch=$(common::debarch "${arch}")
    fi

    # Generate an absolute filename if none was specified.
    if [ -z "${filename}" ]; then
        filename="${image//[:\/]/+}.sqsh"
    fi
    filename=$(common::realpath "${filename}")
    if [ -e "${filename}" ]; then
        common::err "File already exists: ${filename}"
    fi

    # Create a temporary directory and chdir to it.
    trap 'common::rmall "${tmpdir}" 2> /dev/null; docker rm -f -v "${tmpdir##*/}" > /dev/null 2>&1' EXIT
    tmpdir=$(common::mktmpdir enroot)
    common::chdir "${tmpdir}"

    # Download the image (if necessary) and create a container for extraction.
    common::log INFO "Fetching image" NL
    # TODO Use --platform once it comes out of experimental.
    docker create --name "${PWD##*/}" "${image}" >&2
    common::log

    # Extract and configure the rootfs.
    common::log INFO "Extracting image content..."
    mkdir rootfs
    docker export "${PWD##*/}" | tar -C rootfs --warning=no-timestamp --anchored --exclude='dev/*' --exclude='.dockerenv' -px
    common::fixperms rootfs
    docker inspect "${image}" | jq '.[] | with_entries(.key|=ascii_downcase)' > config
    docker::configure rootfs config "${arch}"

    # Create the final squashfs filesystem.
    common::log INFO "Creating squashfs filesystem..." NL
    mksquashfs rootfs "${filename}" -all-root ${TTY_OFF+-no-progress} -processors "${ENROOT_MAX_PROCESSORS}" ${ENROOT_SQUASH_OPTIONS} >&2
)
