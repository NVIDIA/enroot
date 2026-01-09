# Usage

```
Usage: enroot load [options] [--] URI

Load a container root filesystem directly from a container image.

 Schemes:
   docker://[USER@][REGISTRY#]IMAGE[:TAG]  Load a Docker image from a registry

 Options:
   -a, --arch    Architecture of the image (defaults to host architecture)
   -n, --name    Name of the container (defaults to "URI")
   -f, --force   Overwrite an existing root filesystem
```

# Description

Load and extract a container image directly to a root filesystem.
This is faster than using [import](import.md) followed by [create](create.md) since it avoids creating and extracting a squashfs file.  

The resulting root filesystem can be started with the [start](start.md) command or removed with the [remove](remove.md) command.  

See the [import](import.md) command documentation for credential configuration examples and supported schemes.

# Configuration

| Setting | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_GZIP_PROGRAM` | `pigz` _or_ `gzip` | Gzip program used to uncompress digest layers |
| `ENROOT_ZSTD_OPTIONS` | `-1` | Options passed to zstd to compress digest layers |
| `ENROOT_NATIVE_OVERLAYFS` | `yes` | **Required** - Use native overlayfs to merge image layers |
| `ENROOT_SQUASH_OPTIONS` | `-comp lzo -noD -exit-on-error` | Options passed to mksquashfs to produce container images |
| `ENROOT_MAX_PROCESSORS` | `$(nproc)` | Maximum number of processors to use for parallel tasks (0 means unlimited) |
| `ENROOT_MAX_CONNECTIONS` | `10` | Maximum number of concurrent connections (0 means unlimited) |
| `ENROOT_CONNECT_TIMEOUT` | `30` | Maximum time in seconds to wait for connections establishment (0 means unlimited) |
| `ENROOT_TRANSFER_TIMEOUT` | `0` | Maximum time in seconds to wait for network operations to complete (0 means unlimited) |
| `ENROOT_TRANSFER_RETRIES` | `0` | Number of times network operations should be retried |
| `ENROOT_ALLOW_HTTP` | `no` | Use HTTP for outgoing requests instead of HTTPS **(UNSECURE!)** |
| `ENROOT_FORCE_OVERRIDE` | `no` | Overwrite the container if it already exists (same as `--force`) |

**Note:** This command requires `ENROOT_NATIVE_OVERLAYFS` to be enabled (the default, typically requires Linux 5.11+). If this option is disabled, the command will fail with an error.

# Example

```sh
# Load PyTorch 25.12 from NVIDIA GPU Cloud (NGC)
$ enroot load --name pytorch docker://nvcr.io#nvidia/pytorch:25.12-py3

# Start the container
$ enroot start mpytorch
```

# See Also

- [import](import.md) - Import a container image to a squashfs file
- [create](create.md) - Create a container from a squashfs file
- [start](start.md) - Start a container
