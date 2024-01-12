# Usage

```
Usage: enroot create [options] [--] IMAGE

Create a container root filesystem from a container image.

 Options:
   -n, --name   Name of the container (defaults to "IMAGE")
   -f, --force  Overwrite an existing root filesystem
   ```
   
# Description

Take a container image and unpack its root filesystem under `$ENROOT_DATA_PATH/`.  
The resulting root filesystem can be started with the [start](start.md) command or removed with the [remove](remove.md) command.

# Configuration

| Setting | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_MAX_PROCESSORS` | `$(nproc)` | Maximum number of processors to use for parallel tasks (0 means unlimited) |
| `ENROOT_FORCE_OVERRIDE` | `no` | Overwrite the root filesystem if it already exists (same as `--force`) |

# Example

```sh
# Import Ubuntu 18.04 from DockerHub and create a container out of it
$ enroot import docker://ubuntu:18.04
$ enroot create --name ubuntu ubuntu+18.04.sqsh
```
