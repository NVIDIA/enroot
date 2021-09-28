# Usage

```
Usage: enroot import [options] [--] URI

Import a container image from a specific location.

 Schemes:
   docker://[USER@][REGISTRY#]IMAGE[:TAG]  Import a Docker image from a registry
   dockerd://IMAGE[:TAG]                   Import a Docker image from the Docker daemon
   podman://IMAGE[:TAG]                    Import a Docker image from a local podman repository

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
machine auth.docker.io login <login> password <passord>

# Google Container Registry with OAuth
machine gcr.io login oauth2accesstoken password $(gcloud auth print-access-token)
# Google Container Registry with JSON
machine gcr.io login _json_key password $(jq -c '.' $GOOGLE_APPLICATION_CREDENTIALS | sed 's/ /\\u0020/g')

# Amazon Elastic Container Registry
machine 12345.dkr.ecr.eu-west-2.amazonaws.com login AWS password $(aws ecr get-login-password --region eu-west-2)
```

### Supported schemes
#### [Docker (docker://)](https://www.docker.com/)

Docker image manifest version 2, schema 2.  
Digests are cached under `$ENROOT_CACHE_PATH/`.

#### [Docker Daemon (dockerd://)](https://www.docker.com/)

Docker image manifest version 2, schema 2.  
Requires the Docker CLI to communicate with the Docker daemon.

# Configuration

| Setting | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_GZIP_PROGRAM` | `pigz` _or_ `gzip` | Gzip program used to uncompress digest layers |
| `ENROOT_ZSTD_OPTIONS` | `-1` | Options passed to zstd to compress digest layers |
| `ENROOT_SQUASH_OPTIONS` | `-comp lzo -noD` | Options passed to mksquashfs to produce container images |
| `ENROOT_MAX_PROCESSORS` | `$(nproc)` | Maximum number of processors to use for parallel tasks (0 means unlimited) |
| `ENROOT_MAX_CONNECTIONS` | `10` | Maximum number of concurrent connections (0 means unlimited) |
| `ENROOT_CONNECT_TIMEOUT` | `30` | Maximum time in seconds to wait for connections establishment (0 means unlimited) |
| `ENROOT_TRANSFER_TIMEOUT` | `0` | Maximum time in seconds to wait for network operations to complete (0 means unlimited) |
| `ENROOT_TRANSFER_RETRIES` | `0` | Number of times network operations should be retried |
| `ENROOT_ALLOW_HTTP` | `no` | Use HTTP for outgoing requests instead of HTTPS **(UNSECURE!)** |

# Example

```sh
# Import Tensorflow 19.01 from NVIDIA GPU Cloud
$ enroot import --output tensorflow.sqsh 'docker://$oauthtoken@nvcr.io#nvidia/tensorflow:19.01-py3'
```

# Known issues

* Older versions of curl (< 7.61) do not support more than 256 characters passwords.
