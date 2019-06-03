# Usage
```
Usage: enroot batch [options] [--] CONFIG [COMMAND] [ARG...]

Shorthand version of "enroot start -c CONFIG" where the root filesystem is
taken from the configuration file using the special directive ENROOT_ROOTFS.
```

# Description

Start a container from a [configuration script](start.md#configuration-script) similar to the [start](start.md) command with the `--conf` option.  
Configuration parameters are passed through special comment directives. The `ENROOT_ROOTFS` directive is mandatory and specifies the root filesystem of the container.
For example:
```bash
#ENROOT_ROOTFS=ubuntu
#ENROOT_REMAP_ROOT=y

mounts() {
    echo "${PWD} /mnt none bind"
}
```

# Configuration

| Setting | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_ROOTFS` | | Root filesystem of the container (required) |
| `ENROOT_LOGIN_SHELL` | `/bin/sh` | Login shell used to run the container initialization |
| `ENROOT_ROOTFS_WRITABLE` | `no` |  Make the container root filesystem writable (same as `--rw`) |
| `ENROOT_REMAP_ROOT` | `no` | Remap the current user to root inside containers (same as `--root`) |

See also [Standard Hooks](../standard-hooks.md) for additional configuration.

# Example

```bash
# Import Ubuntu from DockerHub and create a container out of it
$ enroot import docker://ubuntu
$ enroot create ubuntu.sqsh

# Write a batch script to start the ubuntu container
$ cat << EOF > ubuntu.batch && chmod +x ubuntu.batch
#! /usr/bin/enroot batch
#ENROOT_ROOTFS=ubuntu
EOF

# Start the container
$ ./ubuntu.batch
