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

# shellcheck disable=SC2148,SC2030,SC2031

readonly token_dir="${ENROOT_CACHE_PATH}/.tokens.${EUID}"
readonly creds_file="${ENROOT_CONFIG_PATH}/.credentials"

if [ -n "${ENROOT_ALLOW_HTTP-}" ]; then
    readonly curl_proto="http"
    readonly curl_opts=("--proto" "=http,https" "--connect-timeout" "${ENROOT_CONNECT_TIMEOUT}" "-SsL")
else
    readonly curl_proto="https"
    readonly curl_opts=("--proto" "=https" "--connect-timeout" "${ENROOT_CONNECT_TIMEOUT}" "-SsL")
fi

docker::_authenticate() {
    local -r user="$1"
    local -r registry="$2"
    local -r url="$3"

    local realm=""
    local token=""
    local -a req_params=()
    local resp_headers=""

    # Reuse our previous token if we already got one.
    if [ -f "${token_dir}/${registry}" ]; then
        req_params+=("-K" "${token_dir}/${registry}")
    fi

    # Query the registry to see if we're authorized.
    common::log INFO "Querying registry for permission grant"
    resp_headers=$(CURL_IGNORE=401 common::curl "${curl_opts[@]}" -I ${req_params[@]+"${req_params[@]}"} -- "${url}")

    # If our token is still valid, we're done.
    if ! grep -qi '^www-authenticate:' <<< "${resp_headers}"; then
        common::log INFO "Found valid credentials in cache"
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
            req_params+=("--netrc-file" "${creds_file}")
        else
            req_params+=("-u" "${user}")
        fi
    fi

    # Request a new token.
    common::curl "${curl_opts[@]}" -G ${req_params[@]+"${req_params[@]}"} -- "${realm}" \
      | jq -r '.token? // .access_token? // empty' \
      | common::read -r token

    # Store the new token.
    if [ -n "${token}" ]; then
        # shellcheck disable=SC2174
        mkdir -m 0700 -p "${token_dir}"
        (umask 077 && printf 'header "Authorization: Bearer %s"' "${token}" > "${token_dir}/${registry}")
        common::log INFO "Authentication succeeded"
    fi
}

docker::_download() {
    local -r user="$1"
    local -r registry="${2:-registry-1.docker.io}"
    local image="$3"
    local -r tag="${4:-latest}"
    local -r arch="$5"

    if  [[ "${image}" != */* ]]; then
        image="library/${image}"
    fi

    local -a layers=()
    local -a missing_digests=()
    local -a req_params=("-H" "Accept: application/vnd.docker.distribution.manifest.v2+json")
    local -r url_digest="${curl_proto}://${registry}/v2/${image}/blobs/"
    local url_manifest="${curl_proto}://${registry}/v2/${image}/manifests/${tag}"
    local cached_digests=""
    local manifest=""
    local config=""

    # Authenticate with the registry.
    docker::_authenticate "${user}" "${registry}" "${url_manifest}"
    if [ -f "${token_dir}/${registry}" ]; then
        req_params+=("-K" "${token_dir}/${registry}")
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

    # Download digests, verify their checksums and put them in cache.
    if [ "${#missing_digests[@]}" -gt 0 ]; then
        common::log INFO "Downloading ${#missing_digests[@]} missing digests..." NL
        parallel --plain ${TTY_ON+--bar} -q curl "${curl_opts[@]}" -f -o {} "${req_params[@]}" -- \
          "${url_digest}sha256:{}" ::: "${missing_digests[@]}"
        common::log

        common::log INFO "Validating digest checksums..." NL
        parallel --plain 'sha256sum -c <<< "{} {}"' ::: "${missing_digests[@]}" >&2
        common::log
        chmod 640 "${missing_digests[@]}"
        mv "${missing_digests[@]}" "${ENROOT_CACHE_PATH}"
    else
        common::log INFO "Found all digests in cache"
    fi

    # Return the container configuration along with all the layers.
    printf "%s\n" "${config}" "${layers[*]}"
}

docker::_configure() {
    local -r rootfs="$1"
    local -r config="$2"
    local -r arch="$3"

    local -r fstab="${rootfs}/etc/fstab"
    local -r initrc="${rootfs}/etc/rc"
    local -r rclocal="${rootfs}/etc/rc.local"
    local -r environ="${rootfs}/etc/environment"
    local -a entrypoint=()
    local -a cmd=()
    local workdir=""
    local platform=""

    mkdir -p "${fstab%/*}" "${initrc%/*}" "${environ%/*}"

    # Check if the config architecture matches what we expect.
    jq -r '(.architecture)? // empty' "${config}" | common::read -r platform
    if [ "${arch}" != "${platform}" ]; then
        common::log WARN "Image architecture doesn't match the requested one: ${platform} != ${arch}"
    fi

    # Configure volumes as tmpfs mounts.
    jq -r '(.config.Volumes)? // empty | keys[] | "tmpfs \(.) tmpfs x-create=dir,rw,nosuid,nodev"' "${config}" > "${fstab}"

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

    cat >> "${initrc}" <<- EOF
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
    local filename="$2"
    local arch="$3"

    local -a layers=()
    local config=""
    local image=""
    local registry=""
    local tag=""
    local user=""
    local tmpdir=""

    # Parse the image reference of the form 'docker://[<user>@][<registry>#]<image>[:<tag>]'.
    local reg_user="[[:alnum:]_.!~*\'()%\;:\&=+$,-]+"
    local reg_registry="[^#]+"
    local reg_image="[[:lower:][:digit:]/._-]+"
    local reg_tag="[[:alnum:]._-]+"

    common::checkcmd curl grep awk jq parallel tar "${ENROOT_GZIP_PROGRAM}" find mksquashfs

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
    tmpdir=$(common::mktmpdir enroot)
    # shellcheck disable=SC2064
    trap "common::rmall '${tmpdir}' 2> /dev/null" EXIT
    common::chdir "${tmpdir}"

    # Download the image digests and store them in cache.
    docker::_download "${user}" "${registry}" "${image}" "${tag}" "${arch}" \
      | { common::read -r config; IFS=' ' common::read -r -a layers; }

    # Extract all the layers locally.
    common::log INFO "Extracting image layers..." NL
    # shellcheck disable=SC1083
    parallel --plain ${TTY_ON+--bar} mkdir {\#}\; tar -C {\#} --warning=no-timestamp --exclude='dev/*' \
      --use-compress-program=\'"${ENROOT_GZIP_PROGRAM}"\' -pxf \'"${ENROOT_CACHE_PATH}/{}"\' ::: "${layers[@]}"
    common::fixperms .
    common::log

    # Convert the AUFS whiteouts to the OVLFS ones.
    common::log INFO "Converting whiteouts..." NL
    # shellcheck disable=SC1083
    parallel --plain ${TTY_ON+--bar} enroot-aufs2ovlfs {\#} ::: "${layers[@]}"
    common::log

    # Configure the rootfs.
    mkdir 0
    docker::_configure "${PWD}/0" "${ENROOT_CACHE_PATH}/${config}" "${arch}"

    # Create the final squashfs filesystem by overlaying all the layers.
    common::log INFO "Creating squashfs filesystem..." NL
    mkdir rootfs
    # shellcheck disable=SC2086
    MOUNTPOINT="${PWD}/rootfs" \
    enroot-mksquashovlfs "0:$(seq -s: 1 "${#layers[@]}")" "${filename}" -all-root ${TTY_OFF+-no-progress} ${ENROOT_SQUASH_OPTIONS}
)
