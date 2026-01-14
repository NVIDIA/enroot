# Copyright (c) 2018-2025, NVIDIA CORPORATION. All rights reserved.
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
    readonly curl_opts=("--proto" "=http,https" "--retry" "${ENROOT_TRANSFER_RETRIES}" "--connect-timeout" "${ENROOT_CONNECT_TIMEOUT}" "--max-time" "${ENROOT_TRANSFER_TIMEOUT}" "-SsL")
else
    readonly curl_proto="https"
    readonly curl_opts=("--proto" "=https" "--retry" "${ENROOT_TRANSFER_RETRIES}" "--connect-timeout" "${ENROOT_CONNECT_TIMEOUT}" "--max-time" "${ENROOT_TRANSFER_TIMEOUT}" "-SsL")
fi

docker::_authenticate() {
    local -r user="$1" registry="$2" url="$3"
    local realm= token= req_params=() resp_headers=

    # Query the registry to see if we're authorized.
    common::log INFO "Querying registry for permission grant"
    resp_headers=$(CURL_IGNORE=401 common::curl "${curl_opts[@]}" -I -- "${url}")

    # If we don't need to authenticate, we're done.
    if ! grep -qi '^www-authenticate:' <<< "${resp_headers}"; then
        common::log INFO "Permission granted"
        return
    fi

    # Otherwise, craft a new token request from the WWW-Authenticate header.
    printf "%s" "${resp_headers}" | awk '(tolower($1) ~ "^www-authenticate:"){
        sub(/"\r/, "", $0)
        for (i = 1; i <= split($3, params, /="|",/); i += 2)
            tolower(params[i]) == "realm" ?  realm = params[i+1] : data[params[i]] = params[i+1]

        print $2; print realm; for (i in data) print "--data-urlencode\n" i"="data[i]
    }' | { common::read -r auth; common::read -r realm; readarray -t req_params; }

    if [ -z "${realm}" ]; then
        common::err "Could not parse authentication realm from ${url}"
    fi

    # If a user was specified, lookup his credentials.
    common::log INFO "Authenticating with user: ${user:-<anonymous>}"
    if [ -n "${user}" ]; then
        if grep -qs "^machine[[:space:]]\+${registry%:*}[[:space:]]\+login[[:space:]]\+${user}[[:space:]]" "${creds_file}"; then
            common::log INFO "Using credentials from file: ${creds_file}"
            exec {fd}< <(common::evalnetrc "${creds_file}" 2> /dev/null)
            req_params+=("--netrc-file" "/proc/self/fd/${fd}")
        else
            req_params+=("-u" "${user}")
        fi
    fi

    case "${auth}" in
    Bearer)
        # Request a new token.
        common::curl "${curl_opts[@]}" -G ${req_params[@]+"${req_params[@]}"} -- "${realm}" \
          | common::jq -r '.token? // .access_token? // empty' \
          | common::read -r token
        ;;
    Basic)
        # Check that we have valid credentials and save them if successful.
        common::curl "${curl_opts[@]}" -G -v ${req_params[@]+"${req_params[@]}"} -- "${url}" 2>&1 > /dev/null \
          | awk '/Authorization: Basic/ { sub(/\r/, "", $4); print $4 }' \
          | common::read -r token
        ;;
    *)
        common::err "Unsupported authentication method ${auth}" ;;
    esac

    [ -v fd ] && exec {fd}>&-

    # Store the new token.
    if [ -n "${token}" ]; then
        mkdir -m 0700 -p "${token_dir}"
        (umask 077 && printf 'header "Authorization: %s %s"' "${auth}" "${token}" > "${token_dir}/${registry}.$$")
        common::log INFO "Authentication succeeded"
    fi
}

docker::_download_extract() (
    local -r digest="$1" media_type="$2"; shift 2
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
        if [ "${media_type}" = "application/vnd.oci.image.layer.v1.tar+zstd" ]; then
            curl "${curl_args[@]}" | tee "/proc/self/fd/${stdout}" > "${tmpfile}"
        else
            curl "${curl_args[@]}" | tee "/proc/self/fd/${stdout}" \
              | "${ENROOT_GZIP_PROGRAM}" -d -f -c \
              | zstd -T"$(expr "${ENROOT_MAX_PROCESSORS}" / "${ENROOT_MAX_CONNECTIONS}" \| 1)" -q -f -o "${tmpfile}" ${ENROOT_ZSTD_OPTIONS}
        fi
    } {stdout}>&1 | sha256sum | common::read -r checksum x
    exec {stdout}>&-

    if [ "${digest}" != "${checksum}" ]; then
        printf "Checksum mismatch: %s\n" "${digest}" >&2
        exit 1
    fi

    chmod 640 "${tmpfile}"
    mv -n "${tmpfile}" "${ENROOT_CACHE_PATH}/${digest}"
)

docker::_download() {
    local -r user="$1" registry="$2" tag="$4" arch="$5"
    local image="$3"

    local req_params=() layers=() missing_digests=() cached_digests= manifest= config= media_type=
    local accept_manifest_list=("-H" "Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json")
    local accept_manifest=("-H" "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json")
    local url_manifest="${curl_proto}://${registry}/v2/${image}/manifests/${tag}"
    local -r url_digest="${curl_proto}://${registry}/v2/${image}/blobs/"

    # Authenticate with the registry.
    docker::_authenticate "${user}" "${registry}" "${url_manifest}"
    if [ -f "${token_dir}/${registry}.$$" ]; then
        req_params+=("-K" "${token_dir}/${registry}.$$")
    fi

    # Attempt to use the image manifest list if it exists.
    common::log INFO "Fetching image manifest list"
    CURL_IGNORE="401 404" common::curl "${curl_opts[@]}" "${accept_manifest_list[@]}" "${req_params[@]}" -- "${url_manifest}" \
      | common::jq -R -s -r "(fromjson | .manifests[] | select(.platform.architecture == \"${arch}\") | .digest)? // empty" \
      | common::read -r manifest

    if [ -n "${manifest}" ]; then
        url_manifest="${curl_proto}://${registry}/v2/${image}/manifests/${manifest}"
    fi

    # Fetch the image manifest.
    common::log INFO "Fetching image manifest"
    common::curl "${curl_opts[@]}" "${accept_manifest[@]}" "${req_params[@]}" -- "${url_manifest}" \
      | common::jq -r '(.config.digest | ltrimstr("sha256:"))? // empty, (.layers[0].mediaType)? // empty, ([.layers[].digest | ltrimstr("sha256:")] | reverse | @tsv)?' \
      | { common::read -r config; common::read -r media_type; IFS=$'\t' common::read -r -a layers; }

    if [ -z "${config}" ] || [ "${#layers[@]}" -eq 0 ]; then
        common::err "Could not parse digest information from ${url_manifest}"
    fi
    missing_digests=("${layers[@]}")

    if [ ! -e "${ENROOT_CACHE_PATH}/${config}" ]; then
        BASH_ENV="${BASH_SOURCE[0]}" docker::_download_extract "${config}" "application/vnd.oci.image.config.v1+json" "${curl_opts[@]}" -f "${req_params[@]}" -- "${url_digest}sha256:${config}"
    fi

    # Check which digests are already cached.
    printf "%s\n" "${layers[@]}" \
      | sort -u \
      | sort - <(ls "${ENROOT_CACHE_PATH}") \
      | uniq -d \
      | paste -sd '|' - \
      | common::read -r cached_digests

    if [ -n "${cached_digests}" ]; then
        printf "%s\n" "${layers[@]}" \
          | { grep -Ev "${cached_digests}" || :; } \
          | readarray -t missing_digests
    fi

    # Download digests, verify their checksums and extract them in the cache.
    if [ "${#missing_digests[@]}" -gt 0 ]; then
        common::log INFO "Downloading ${#missing_digests[@]} missing layers..." NL
        BASH_ENV="${BASH_SOURCE[0]}" parallel --plain ${TTY_ON+--bar} --shuf --retries 2 -j "${ENROOT_MAX_CONNECTIONS}" -q \
          docker::_download_extract "{}" "${media_type}" "${curl_opts[@]}" -f "${req_params[@]}" -- "${url_digest}sha256:{}" ::: "${missing_digests[@]}"
        common::log
    else
        common::log INFO "Found all layers in cache"
    fi

    # Return the container configuration along with all the layers.
    printf "%s\n" "${config}" "${layers[*]}"
}

docker::_parse_uri() {
    local -r uri="$1"
    local -r reg_user="[[:alnum:]_.!~*\'()%\;:\&=+$,-@]+"
    local -r reg_image="[[:lower:][:digit:]/._-]+"
    local -r reg_tag="[[:alnum:]._:-]+"
    local -r reg_digest="sha256:[[:alnum:]]+"
    local user= registry= image= tag=

    # Try Docker standard syntax with registry: docker://[USER@]REGISTRY/IMAGE[@DIGEST|:TAG]
    # Registry must be FQDN (contains ".") or have port (contains ":"), otherwise it's a Docker Hub namespace
    if [[ "${uri}" =~ ^docker://((${reg_user})@)?([^/#]+)/(${reg_image}):(${reg_tag})@(${reg_digest})$ ]]; then
        local match_registry="${BASH_REMATCH[3]}"
        local match_image="${BASH_REMATCH[4]}"
        user="${BASH_REMATCH[2]}"
        # Ignore tag, use digest
        tag="${BASH_REMATCH[6]}"
        if [[ "${match_registry}" =~ \.|: ]]; then
            # docker://[USER@]REGISTRY/IMAGE:TAG@DIGEST
            registry="${match_registry}"
            image="${match_image}"
        else
            # docker://[USER@]NAMESPACE/IMAGE:TAG@DIGEST
            registry="registry-1.docker.io"
            image="${match_registry}/${match_image}"
        fi
    elif [[ "${uri}" =~ ^docker://((${reg_user})@)?([^/#]+)/(${reg_image})@(${reg_digest})$ ]]; then
        local match_registry="${BASH_REMATCH[3]}"
        local match_image="${BASH_REMATCH[4]}"
        user="${BASH_REMATCH[2]}"
        tag="${BASH_REMATCH[5]}"
        if [[ "${match_registry}" =~ \.|: ]]; then
            # docker://[USER@]REGISTRY/IMAGE@DIGEST
            registry="${match_registry}"
            image="${match_image}"
        else
            # docker://[USER@]NAMESPACE/IMAGE@DIGEST
            registry="registry-1.docker.io"
            image="${match_registry}/${match_image}"
        fi
    elif [[ "${uri}" =~ ^docker://((${reg_user})@)?([^/#]+)/(${reg_image})(:(${reg_tag}))?$ ]]; then
        local match_registry="${BASH_REMATCH[3]}"
        local match_image="${BASH_REMATCH[4]}"
        user="${BASH_REMATCH[2]}"
        tag="${BASH_REMATCH[6]}"
        if [[ "${match_registry}" =~ \.|: ]]; then
            # docker://[USER@]REGISTRY/IMAGE[:TAG]
            registry="${match_registry}"
            image="${match_image}"
        else
            # docker://[USER@]NAMESPACE/IMAGE[:TAG]
            registry="registry-1.docker.io"
            image="${match_registry}/${match_image}"
        fi
    elif [[ "${uri}" =~ ^docker://((${reg_user})@)?([^/@#:]+):(${reg_tag})@(${reg_digest})$ ]]; then
        # docker://[USER@]IMAGE:TAG@DIGEST
        user="${BASH_REMATCH[2]}"
        registry="registry-1.docker.io"
        image="library/${BASH_REMATCH[3]}"
        # Ignore tag, use digest
        tag="${BASH_REMATCH[5]}"
    elif [[ "${uri}" =~ ^docker://((${reg_user})@)?([^/@#:]+)@(${reg_digest})$ ]]; then
        # docker://[USER@]IMAGE@DIGEST
        user="${BASH_REMATCH[2]}"
        registry="registry-1.docker.io"
        image="library/${BASH_REMATCH[3]}"
        tag="${BASH_REMATCH[4]}"
    elif [[ "${uri}" =~ ^docker://((${reg_user})@)?([^/@#:]+)(:(${reg_tag}))?$ ]]; then
        # docker://[USER@]IMAGE[:TAG]
        user="${BASH_REMATCH[2]}"
        registry="registry-1.docker.io"
        image="library/${BASH_REMATCH[3]}"
        tag="${BASH_REMATCH[5]}"
    # enroot format with '#' as the separator between registry and image
    elif [[ "${uri}" =~ ^docker://((${reg_user})@)?([^#/@]+)#(${reg_image}):(${reg_tag})@(${reg_digest})$ ]]; then
        # docker://[USER@]REGISTRY#IMAGE:TAG@DIGEST
        user="${BASH_REMATCH[2]}"
        registry="${BASH_REMATCH[3]}"
        image="${BASH_REMATCH[4]}"
        # Ignore tag, use digest
        tag="${BASH_REMATCH[6]}"
    elif [[ "${uri}" =~ ^docker://((${reg_user})@)?([^#/@]+)#(${reg_image})@(${reg_digest})$ ]]; then
        # docker://[USER@]REGISTRY#IMAGE@DIGEST
        user="${BASH_REMATCH[2]}"
        registry="${BASH_REMATCH[3]}"
        image="${BASH_REMATCH[4]}"
        tag="${BASH_REMATCH[5]}"
    elif [[ "${uri}" =~ ^docker://((${reg_user})@)?([^#/@]+)#(${reg_image})(:(${reg_tag}))?$ ]]; then
        # docker://[USER@]REGISTRY#IMAGE[:TAG]
        user="${BASH_REMATCH[2]}"
        registry="${BASH_REMATCH[3]}"
        image="${BASH_REMATCH[4]}"
        tag="${BASH_REMATCH[6]}"
    else
        common::err "Invalid image reference: ${uri}"
    fi

    if [ -z "${tag}" ]; then
        tag="latest"
    fi

    # Try to infer the user from the credential file.
    if [ -s "${creds_file}" ] && [ -n "${registry}" ] && [ -z "${user}" ]; then
        user="$(awk "/^[[:space:]]*machine[[:space:]]+${registry%:*}[[:space:]]+login[[:space:]]+.+/ { print \$4; exit }" "${creds_file}")"
    fi

    printf "%s\n%s\n%s\n%s\n" "${user}" "${registry}" "${image}" "${tag}"
}

docker::_prepare_layers() (
    local -r user="$1" registry="$2" image="$3" tag="$4" arch="$5"
    local -r convert_whiteouts="${6:-yes}"
    local layers=() config=

    set -euo pipefail

    docker::_download "${user}" "${registry}" "${image}" "${tag}" "${arch}" \
      | { common::read -r config; IFS=' ' common::read -r -a layers; }

    common::log INFO "Extracting image layers..." NL
    parallel --plain ${TTY_ON+--bar} -j "${ENROOT_MAX_PROCESSORS}" mkdir {\#}\; tar -C {\#} --warning=no-timestamp --anchored --exclude='dev/*' --exclude='./dev/*' \
      --use-compress-program=zstd --delay-directory-restore -pxf \'"${ENROOT_CACHE_PATH}/{}"\' ::: "${layers[@]}"
    common::fixperms .
    common::log

    if [ "${convert_whiteouts}" = "yes" ]; then
        common::log INFO "Converting whiteouts..." NL
        parallel --plain ${TTY_ON+--bar} -j "${ENROOT_MAX_PROCESSORS}" enroot-aufs2ovlfs {\#} ::: "${layers[@]}"
        common::log
    fi

    mkdir 0
    zstd -q -d -o config "${ENROOT_CACHE_PATH}/${config}"
    docker::configure "${PWD}/0" config "${arch}"

    printf "%s\n%s\n" "${config}" "${#layers[@]}"
)

docker::configure() {
    local -r rootfs="$1" config="$2" arch="${3-}"
    local -r fstab="${rootfs}/etc/fstab" initrc="${rootfs}/etc/rc" rclocal="${rootfs}/etc/rc.local" environ="${rootfs}/etc/environment"
    local entrypoint=() cmd=() workdir= platform=

    mkdir -p "${fstab%/*}" "${initrc%/*}" "${environ%/*}"

    if [ -n "${arch}" ]; then
        # Check if the config architecture matches what we expect.
        common::jq -r '(.architecture // .Architecture)? // empty' "${config}" | common::read -r platform
        if [ "${arch}" != "${platform}" ]; then
            common::log WARN "Image architecture doesn't match the requested one: ${platform} != ${arch}"
        fi
    fi

    # Configure volumes as simple rootfs bind mounts.
    common::jq -r '(.config.Volumes)? // empty | keys[] | "${ENROOT_ROOTFS}\(.) \(.) none x-create=dir,bind,rw,nosuid,nodev"' "${config}" > "${fstab}"

    # Configure environment variables.
    common::jq -r '(.config.Env[])? // empty' "${config}" > "${environ}"

    # Configure labels as comments.
    common::jq -r '(.config.Labels)? // empty | to_entries[] | "# \(.key) \(.value)"' "${config}" > "${initrc}"
    [ -s "${initrc}" ] && echo >> "${initrc}"

    # Generate the rc script with the working directory, the entrypoint and the command.
    common::jq -r '(.config.WorkingDir)? // empty' "${config}" | common::read -r workdir
    common::jq -r '(.config.Entrypoint[])? // empty' "${config}" | readarray -t entrypoint
    common::jq -r '(.config.Cmd[])? // empty' "${config}" | readarray -t cmd
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

docker::digest() (
    local -r uri="$1"
    local arch="$2"
    local user= registry= image= tag=

    common::checkcmd curl grep awk jq

    docker::_parse_uri "${uri}" \
      | { common::read -r user; common::read -r registry; common::read -r image; common::read -r tag; }

    # Convert the architecture to the debian format.
    if [ -n "${arch}" ]; then
        arch=$(common::debarch "${arch}")
    fi

    local req_params=() manifest= manifest_digest=
    local accept_manifest_list=("-H" "Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json")
    local accept_manifest=("-H" "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json")
    local url_manifest="${curl_proto}://${registry}/v2/${image}/manifests/${tag}"

    # Authenticate with the registry.
    docker::_authenticate "${user}" "${registry}" "${url_manifest}"
    if [ -f "${token_dir}/${registry}.$$" ]; then
        req_params+=("-K" "${token_dir}/${registry}.$$")
	trap 'rm -f "${token_dir}/${registry}.$$" 2> /dev/null' EXIT
    fi

    # Attempt to use the image manifest list if it exists.
    CURL_IGNORE="401 404" common::curl "${curl_opts[@]}" "${accept_manifest_list[@]}" "${req_params[@]}" -- "${url_manifest}" \
      | common::jq -R -s -r "(fromjson | .manifests[] | select(.platform.architecture == \"${arch}\") | .digest)? // empty" \
      | common::read -r manifest

    if [ -n "${manifest}" ]; then
        url_manifest="${curl_proto}://${registry}/v2/${image}/manifests/${manifest}"
    fi

    # Fetch the image manifest and get the digest from response headers.
    manifest_digest=$(common::curl "${curl_opts[@]}" "${accept_manifest[@]}" "${req_params[@]}" -I -- "${url_manifest}" \
      | grep -i '^docker-content-digest:' \
      | awk '{print $2}' \
      | tr -d '\r')

    if [ -z "${manifest_digest}" ]; then
        common::err "Could not retrieve digest from ${url_manifest}"
    fi

    printf "%s\n" "${manifest_digest}"
)

docker::import() (
    local -r uri="$1"
    local filename="$2" arch="$3"
    local user= registry= image= tag= tmpdir= timestamp=() config= layer_count=

    common::checkcmd curl grep awk jq parallel tar "${ENROOT_GZIP_PROGRAM}" find mksquashfs zstd

    docker::_parse_uri "${uri}" \
      | { common::read -r user; common::read -r registry; common::read -r image; common::read -r tag; }

    # Convert the architecture to the debian format.
    if [ -n "${arch}" ]; then
        arch=$(common::debarch "${arch}")
    fi

    # Generate an absolute filename if none was specified.
    if [ -z "${filename}" ]; then
        # Remove "library/" prefix for Docker Hub images when generating default filename
        local display_image="${image}"
        if [[ "${registry}" == "registry-1.docker.io" && "${image}" == library/* ]]; then
            display_image="${image#library/}"
        fi
        filename="${display_image////+}${tag:++${tag}}.sqsh"
    fi
    filename=$(common::realpath "${filename}")
    if [ -e "${filename}" ]; then
        common::err "File already exists: ${filename}"
    fi

    # Create a temporary directory and chdir to it.
    trap 'common::rmall "${tmpdir}" 2> /dev/null; rm -f "${token_dir}"/*.$$ 2> /dev/null' EXIT
    tmpdir=$(common::mktmpdir enroot)
    common::chdir "${tmpdir}"

    # Prepare layers and configure rootfs.
    # Skip whiteout conversion because overlayfs handles whiteouts automatically
    docker::_prepare_layers "${user}" "${registry}" "${image}" "${tag}" "${arch}" "no" \
      | { common::read -r config; common::read -r layer_count; }

    if [ -n "${SOURCE_DATE_EPOCH-}" ]; then
        timestamp=("-mkfs-time" "${SOURCE_DATE_EPOCH}" "-all-time" "${SOURCE_DATE_EPOCH}")
    fi

    # Create the final squashfs filesystem by overlaying all the layers.
    common::log INFO "Creating squashfs filesystem..." NL
    mkdir rootfs
    MOUNTPOINT="${PWD}/rootfs" \
    enroot-mksquashovlfs "0:$(seq -s: 1 "${layer_count}")" "${filename}" ${timestamp[@]+"${timestamp[@]}"} -all-root ${TTY_OFF+-no-progress} -processors "${ENROOT_MAX_PROCESSORS}" ${ENROOT_SQUASH_OPTIONS} >&2
)

docker::load() (
    local -r uri="$1"
    local name="$2" arch="$3"
    local user= registry= image= tag= tmpdir= config= layer_count=

    if [ -z "${ENROOT_NATIVE_OVERLAYFS-}" ]; then
        common::err "ENROOT_NATIVE_OVERLAYFS=y is required for enroot load"
    fi

    common::checkcmd curl grep awk jq parallel tar "${ENROOT_GZIP_PROGRAM}" find zstd

    docker::_parse_uri "${uri}" \
      | { common::read -r user; common::read -r registry; common::read -r image; common::read -r tag; }

    # Convert the architecture to the debian format.
    if [ -n "${arch}" ]; then
        arch=$(common::debarch "${arch}")
    fi

    # Generate a rootfs name if none was specified.
    if [ -z "${name}" ]; then
        # Remove "library/" prefix for Docker Hub images when generating default name
        local display_image="${image}"
        if [[ "${registry}" == "registry-1.docker.io" && "${image}" == library/* ]]; then
            display_image="${image#library/}"
        fi
        name="${display_image////+}${tag:++${tag}}"
    fi

    name=$(common::realpath "${ENROOT_DATA_PATH}/${name}")
    if [ -e "${name}" ]; then
        if [ -z "${ENROOT_FORCE_OVERRIDE-}" ]; then
            common::err "File already exists: ${name}"
        else
            common::rmall "${name}"
        fi
    fi

    # Create a temporary directory and chdir to it.
    trap 'common::rmall "${tmpdir}" 2> /dev/null; rm -f "${token_dir}"/*.$$ 2> /dev/null' EXIT
    tmpdir=$(common::mktmpdir enroot)
    common::chdir "${tmpdir}"

    # Prepare layers and configure rootfs.
    docker::_prepare_layers "${user}" "${registry}" "${image}" "${tag}" "${arch}" "yes" \
      | { common::read -r config; common::read -r layer_count; }

    # Create the final filesystem by overlaying all the layers and copying to target rootfs.
    common::log INFO "Loading container root filesystem..." NL

    # Check if we're running unprivileged.
    if [ "${EUID}" -ne 0 ]; then
        unpriv=y
    fi

    # Create a mount namespace and overlay mount
    mkdir -p rootfs "${name}"
    enroot-nsenter ${unpriv:+--user} --mount --remap-root \
            bash -c "mount --make-rprivate / && mount -t overlay overlay -o lowerdir=0:$(seq -s: 1 "${layer_count}") rootfs &&
                     tar --numeric-owner -C rootfs/ --mode=u-s,g-s -cpf - . | tar --numeric-owner -C '${name}/' -xpf -"
)

docker::daemon::import() (
    local -r uri="$1"
    local filename="$2" arch="$3"
    local image= tmpdir= engine=

    case "${uri}" in
    dockerd://*)
        engine="docker" ;;
    podman://*)
        engine="podman" ;;
    esac

    common::checkcmd jq "${engine}" mksquashfs tar

    # Parse the image reference of the form 'dockerd://<image>[:<tag>]'.
    local -r reg_image="[[:alnum:]/._:-]+"

    if [[ "${uri}" =~ ^[[:alpha:]]+://(${reg_image})$ ]]; then
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
    "${engine}" create --name "${PWD##*/}" "${image}" >&2
    common::log

    # Extract and configure the rootfs.
    common::log INFO "Extracting image content..."
    mkdir rootfs
    "${engine}" export "${PWD##*/}" | tar -C rootfs --warning=no-timestamp --anchored --exclude='dev/*' --exclude='.dockerenv' -px
    common::fixperms rootfs
    "${engine}" inspect "${image}" | common::jq '.[] | with_entries(.key|=ascii_downcase)' > config
    docker::configure rootfs config "${arch}"

    # Create the final squashfs filesystem.
    common::log INFO "Creating squashfs filesystem..." NL
    mksquashfs rootfs "${filename}" -all-root ${TTY_OFF+-no-progress} -processors "${ENROOT_MAX_PROCESSORS}" ${ENROOT_SQUASH_OPTIONS} >&2
)
