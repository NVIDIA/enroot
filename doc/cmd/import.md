# Usage

```
Usage: enroot import [options] [--] URI

Import a container image from a specific location.

 Schemes:
   docker://[USER@][REGISTRY#]IMAGE[:TAG]  Import a Docker image from a registry
   dockerd://IMAGE[:TAG]                   Import a Docker image from the Docker daemon
   podman://IMAGE[:TAG]                    Import a Docker image from a local Podman repository

 Options:
   -a, --arch    Architecture of the image (defaults to host architecture)
   -o, --output  Name of the output image file (defaults to "URI.sqsh")
```

# Description

Import and convert (if necessary) a container image from a specific location to an [Enroot image](../image-format.md).  
The resulting image can be unpacked using the [create](create.md) command.

Credentials can be configured through the file `$ENROOT_CONFIG_PATH/.credentials` following the netrc file format.  
If the password field starts with a `$` sign, it will be substituted. For example:
```sh
# NVIDIA GPU Cloud (both endpoints are required)
machine nvcr.io login $oauthtoken password <token>
machine authn.nvidia.com login $oauthtoken password <token>

# DockerHub
machine registry-1.docker.io login <login> password <password>

# Google Artifact Registry:
# Where us-docker.pkg.dev is the hostname for the container images stored in Artifact Registry. This should be replaced with the hostname you are using (i.e. us-west1-docker.pkg.dev).
# If using multiple hostnames, add one line per hostname
# Google Artifact Registry with OAuth
machine us-docker.pkg.dev login oauth2accesstoken password $(gcloud auth print-access-token)
# Google Artifact Registry with JSON
machine us-docker.pkg.dev login _json_key password $(jq -c '.' $GOOGLE_APPLICATION_CREDENTIALS | sed 's/ /\\u0020/g')

# Amazon Elastic Container Registry
machine 12345.dkr.ecr.eu-west-2.amazonaws.com login AWS password $(aws ecr get-login-password --region eu-west-2)

# Azure Container Registry with ACR refresh token
machine myregistry.azurecr.io login 00000000-0000-0000-0000-000000000000 password $(az acr login --name myregistry --expose-token --query accessToken  | tr -d '"')
# Azure Container Registry with ACR admin user
machine myregistry.azurecr.io login myregistry password $(az acr credential show --name myregistry --subscription mysub --query passwords[0].value | tr -d '"')
```

### Supported schemes
#### [Docker (docker://)](https://www.docker.com/)

Docker image manifest version 2, schema 2.  
Digests are cached under `$ENROOT_CACHE_PATH/`.

#### [Docker Daemon (dockerd://)](https://www.docker.com/)

Docker image manifest version 2, schema 2.  
Requires the Docker CLI to communicate with the Docker daemon.

#### [Podman (podman://)](https://www.podman.io/)

Docker image manifest version 2, schema 2.  
Requires the Podman CLI to communicate with the local Podman repository.

# Configuration

| Setting | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_GZIP_PROGRAM` | `pigz` _or_ `gzip` | Gzip program used to uncompress digest layers |
| `ENROOT_ZSTD_OPTIONS` | `-1` | Options passed to zstd to compress digest layers |
| `ENROOT_SQUASH_OPTIONS` | `-comp lzo -noD -exit-on-error` | Options passed to mksquashfs to produce container images |
| `ENROOT_MAX_PROCESSORS` | `$(nproc)` | Maximum number of processors to use for parallel tasks (0 means unlimited) |
| `ENROOT_MAX_CONNECTIONS` | `10` | Maximum number of concurrent connections (0 means unlimited) |
| `ENROOT_CONNECT_TIMEOUT` | `30` | Maximum time in seconds to wait for connections establishment (0 means unlimited) |
| `ENROOT_TRANSFER_TIMEOUT` | `0` | Maximum time in seconds to wait for network operations to complete (0 means unlimited) |
| `ENROOT_TRANSFER_RETRIES` | `0` | Number of times network operations should be retried |
| `ENROOT_ALLOW_HTTP` | `no` | Use HTTP for outgoing requests instead of HTTPS **(UNSECURE!)** |

# Example

```sh
# Import PyTorch 25.06 from NVIDIA GPU Cloud (NGC)
$ enroot import --output pytorch.sqsh docker://nvcr.io#nvidia/pytorch:25.06-py3
```

# Known issues

* Older versions of curl (< 7.61) do not support more than 256 characters passwords.
