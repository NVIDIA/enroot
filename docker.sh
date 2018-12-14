# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

readonly TOKEN_DIR="${ENROOT_CACHE_PATH}/.token"
readonly PASSWD_FILE="${ENROOT_CONFIG_PATH}/.credentials"

docker::authenticate() {
    local -r user="$1"
    local -r registry="$2"
    local -r url="$3"

    local realm=""
    local token=""
    local -a req_params=()
    local resp_headers=""

    # Reuse our previous token if we already got one.
    if [ -f "${TOKEN_DIR}/${registry}" ]; then
        req_params+=("-K" "${TOKEN_DIR}/${registry}")
    fi

    # Query the registry to see if we're authorized.
    log INFO "Querying registry for permission grant"
    resp_headers=$(XCURL_IGNORE=401 xcurl -SsL -I ${req_params[@]+"${req_params[@]}"} -- "${url}")

    # If our token is still valid, we're done.
    if ! grep -q '^Www-Authenticate:' <<< "${resp_headers}"; then
        log INFO "Found valid credentials in cache"
        return
    fi

    # Otherwise, craft a new token request from the Www-Authenticate header.
    echo "${resp_headers}" | awk -F '="|",' '($1 ~ "^Www-Authenticate"){
        sub(/"\r/, "", $0)
        print $2
        for (i=3; i<=NF; i+=2) print "--data-urlencode\n" $i"="$(i+1)
    }' | { xread -r realm; readarray -t req_params; }

    if [ -z "${realm}" ]; then
        err "Could not parse authentication realm from ${url}"
    fi
    # FIXME Hack for NVIDIA GPU Cloud.
    realm="${realm/nvcr.io\/proxy_auth/authn.nvidia.com\/token}"

    # If a user was specified, lookup his credentials.
    log INFO "Authenticating with user: ${user:-<anonymous>}"
    if [ -n "${user}" ]; then
        if grep -qs "login ${user}" "${PASSWD_FILE}"; then
            log INFO "Using credentials from file: ${PASSWD_FILE}"
            req_params+=("--netrc-file" "${PASSWD_FILE}")
        else
            req_params+=("-u" "${user}")
        fi
    fi

    # Request a new token.
    xcurl -SsL -G ${req_params[@]+"${req_params[@]}"} -- "${realm}" \
      | jq -r '.token? // .access_token? // empty' \
      | xread -r token

    # Store the new token.
    if [ -n "${token}" ]; then
        mkdir -m 0700 -p "${TOKEN_DIR}"
        (umask 077 && echo "header \"Authorization: Bearer ${token}"\" > "${TOKEN_DIR}/${registry}")
        log INFO "Authentication succeeded"
    fi
}

docker::download() {
    local -r user="$1"
    local -r registry="${2:-registry-1.docker.io}"
    local image="$3"
    local -r tag="${4:-latest}"

    if  [[ "${image}" != */* ]]; then
        image="library/${image}"
    fi

    local -a layers=()
    local -a missing_digests=()
    local -a req_params=("-H" "Accept: application/vnd.docker.distribution.manifest.v2+json")
    local -r url_digest="https://${registry}/v2/${image}/blobs/"
    local -r url_manifest="https://${registry}/v2/${image}/manifests/${tag}"
    local cached_digests=""
    local config=""

    # Authenticate with the registry.
    docker::authenticate "${user}" "${registry}" "${url_manifest}"
    if [ -f "${TOKEN_DIR}/${registry}" ]; then
        req_params+=("-K" "${TOKEN_DIR}/${registry}")
    fi

    # Fetch the image manifest.
    log INFO "Fetching image manifest"
    xcurl -SsL "${req_params[@]}" -- "${url_manifest}" \
      | jq -r '(.config.digest | ltrimstr("sha256:"))? // empty, ([.layers[].digest | ltrimstr("sha256:")] | reverse | @tsv)?' \
      | { xread -r config; IFS=$'\t' xread -r -a layers; }

    if [ -z "${config}" ] || [ "${#layers[@]}" -eq 0 ]; then
        err "Could not parse digest information from ${url_manifest}"
    fi
    missing_digests=("${config}" "${layers[@]}")

    # Check which digests are already cached.
    printf "%s\n" "${config}" "${layers[@]}" \
      | sort - <(ls "${ENROOT_CACHE_PATH}") \
      | uniq -d \
      | paste -sd '|' - \
      | xread -r cached_digests

    if [ -n "${cached_digests}" ]; then
        printf "%s\n" "${config}" "${layers[@]}" \
          | { grep -Ev "${cached_digests}" || :; } \
          | readarray -t missing_digests
    fi

    # Download digests, verify their checksums and put them in cache.
    if [ "${#missing_digests[@]}" -gt 0 ]; then
        log INFO "Downloading ${#missing_digests[@]} missing digests..."; logln
        parallel ${LOG_TTY+--bar} -q curl -fsSL -o {} "${req_params[@]}" -- "${url_digest}sha256:{}" ::: "${missing_digests[@]}"; logln
        log INFO "Validating digest checksums..."; logln
        parallel 'sha256sum -c <<< "{} {}"' ::: "${missing_digests[@]}" >&2; logln
        mv "${missing_digests[@]}" "${ENROOT_CACHE_PATH}"
    else
        log INFO "Found all digests in cache"
    fi

    # Return the container configuration along with all the layers.
    printf "%s\n" "${config}" "${layers[*]}"
}

docker::configure() {
    local -r rootfs="$1"
    local -r config="$2"

    local -r fstab="${rootfs}/etc/fstab"
    local -r initrc="${rootfs}/etc/rc"
    local -r rclocal="${rootfs}/etc/rc.local"
    local -r environ="${rootfs}/etc/environment"
    local -a entrypoint=()
    local -a cmd=()
    local workdir=""

    mkdir -p "${fstab%/*}" "${initrc%/*}" "${environ%/*}"

    # Configure volumes as tmpfs mounts.
    jq -r '(.config.Volumes)? // empty | keys[] | "tmpfs \(.) tmpfs x-create=dir,rw,nosuid,nodev"' "${config}" > "${fstab}"

    # Configure environment variables.
    jq -r '(.config.Env[])? // empty' "${config}" > "${environ}"

    # Configure labels as comments.
    jq -r '(.config.Labels)? // empty | to_entries[] | "# \(.key) \(.value)"' "${config}" > "${initrc}"
    [ -s "${initrc}" ] && echo >> "${initrc}"

    # Generate the rc script with the working directory, the entrypoint and the command.
    jq -r '(.config.WorkingDir)? // empty' "${config}" | xread -r workdir
    jq -r '(.config.Entrypoint[])? // empty' "${config}" | readarray -t entrypoint
    jq -r '(.config.Cmd[])? // empty' "${config}" | readarray -t cmd
    if [ "${#entrypoint[@]}" -eq 0 ] && [ "${#cmd[@]}" -eq 0 ]; then
        cmd=("/bin/sh")
    fi

    cat >> "${initrc}" << EOF
cd "${workdir:-/}" || exit 1

if [ -s /etc/rc.local ]; then
    . /etc/rc.local
fi

if [ \$# -gt 0 ]; then
    exec ${entrypoint[@]+${entrypoint[@]@Q}} "\$@"
else
    exec ${entrypoint[@]+${entrypoint[@]@Q}} ${cmd[@]@Q}
fi
EOF

    # Generate an empty rc.local script.
    touch "${rclocal}"
}

docker::import() (
    local -r uri="$1"
    local filename="$2"

    local -a layers=()
    local config=""
    local image=""
    local registry=""
    local tag=""
    local user=""
    local tmpdir=""

    # Parse the image reference of the form 'docker://[<user>@][<registry>#]<image>[:<tag>]'.
    if [[ "${uri}" =~ ^docker://(([a-zA-Z0-9$._-]+)@)?(([^#]+)#)?([a-z0-9/._-]+)(:([a-zA-Z0-9._-]+))?$ ]]; then
        user="${BASH_REMATCH[2]}"
        registry="${BASH_REMATCH[4]}"
        image="${BASH_REMATCH[5]}"
        tag="${BASH_REMATCH[7]}"
    else
        err "Invalid image reference: ${uri}"
    fi

    # Generate an absolute filename if none was specified.
    if [ -z "${filename}" ]; then
        filename="${image////+}${tag:++${tag}}.squashfs"
    fi
    filename=$(xrealpath "${filename}")
    if [ -e "${filename}" ]; then
        err "File already exists: ${filename}"
    fi

    # Create a temporary directory under /tmp and chdir to it.
    tmpdir=$(xmktemp -d)
    trap "rmrf '${tmpdir}' 2> /dev/null" EXIT
    xcd "${tmpdir}"

    # Download the image digests and store them in cache.
    docker::download "${user}" "${registry}" "${image}" "${tag}" \
      | { xread -r config; IFS=' ' xread -r -a layers; }

    # Extract all the layers locally.
    log INFO "Extracting image layers..."; logln
    parallel ${LOG_TTY+--bar} mkdir {}\; tar -C {} --exclude='dev/*' --use-compress-program=\'"${ENROOT_GZIP_PROG}"\' \
      -pxf \'"${ENROOT_CACHE_PATH}/{}"\' ::: "${layers[@]}"; logln

    # Convert the AUFS whiteouts to the OVLFS ones.
    log INFO "Converting whiteouts..."; logln
    parallel ${LOG_TTY+--bar} aufs2ovlfs {} ::: "${layers[@]}"; logln

    # Configure the rootfs.
    mkdir rootfs
    docker::configure "${PWD}/rootfs" "${ENROOT_CACHE_PATH}/${config}"

    # Create the final squashfs filesystem by overlaying all the layers.
    log INFO "Creating squashfs filesystem..."; logln
    mksquashovlfs "$(IFS=':'; echo "rootfs:${layers[*]}")" "${filename}" \
      -all-root ${LOG_NO_TTY+-no-progress} ${ENROOT_SQUASH_OPTS}
)
