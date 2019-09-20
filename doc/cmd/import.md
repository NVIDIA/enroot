# Usage

```
Usage: enroot import [options] [--] URI

Import a container image from a specific location.

 Schemes:
   docker://[USER@][REGISTRY#]IMAGE[:TAG]  Import a Docker image from a registry

 Options:
   -o, --output  Name of the output image file (defaults to "URI.sqsh")
```

# Description

Import and convert (if necessary) a container image from a specific location to an [Enroot image](../image-format.md).  
The resulting image can be unpacked using the [create](create.md) command.

Credentials can be configured through the file `$ENROOT_CONFIG_PATH/.credentials` following the netrc file format. For example:
```sh
# NVIDIA GPU Cloud
machine authn.nvidia.com login $oauthtoken password <token>

# DockerHub
machine auth.docker.io login <login> password <passord>
```

### Supported schemes
#### [Docker](https://www.docker.com/)

Docker image manifest version 2, schema 2.  
Digests are cached under `$ENROOT_CACHE_PATH/`.


# Configuration

| Setting | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_GZIP_PROGRAM` | `pigz` _or_ `gzip` | Gzip program used to uncompress digest layers |
| `ENROOT_SQUASH_OPTIONS` | `-comp lzo -noD` | Options passed to mksquashfs to produce container images |
| `ENROOT_CONNECT_TIMEOUT` | `30` | Maximum time in seconds to wait for connections establishment |
| `ENROOT_ALLOW_HTTP` | `no` | Use HTTP for outgoing requests instead of HTTPS **(UNSECURE!)** |

# Example

```sh
# Import Tensorflow 19.01 from NVIDIA GPU Cloud
$ enroot import --output tensorflow.sqsh 'docker://$oauthtoken@nvcr.io#nvidia/tensorflow:19.01-py3'
# If you created .credential file following the instruction above, you use this command instead:
$ enroot import --output tensorflow.sqsh 'docker://nvcr.io#nvidia/tensorflow:19.01-py3'
```

# Known issues

* The first import from NVIDIA GPU Cloud always fail error code: 401
* Older versions of curl (< 7.61) do not support more than 256 characters passwords.
