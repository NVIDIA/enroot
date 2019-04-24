# Usage
```
Usage: enroot start [options] [--] NAME|IMAGE [COMMAND] [ARG...]

Start a container and invoke the command script within its root filesystem.
Command and arguments are passed to the script as input parameters.

In the absence of a command script and if a command was given, it will be executed direcly.
Otherwise, an interactive shell will be started within the container.

 Options:
   -c, --conf CONFIG    Specify a configuration script to run before the container starts
   -e, --env KEY[=VAL]  Export an environment variable inside the container
   -r, --root           Ask to be remapped to root inside the container
   -w, --rw             Make the container root filesystem writable
   -m, --mount FSTAB    Perform a mount from the host inside the container (colon-separated)
```

# Description

Start a container by invoking its command script (or entrypoint), refer to [Image format (/etc/rc)](../image-format.md).  

By default the root filesystem of the container is made read-only unless the `--rw` option has been provided.  
The `--root` option can also be provided in order to remap the current user to be root inside the container.

A configuration script can be specified with `--conf` to perform specific actions before the container starts like mounting files or setting environment variables.

Mounts and environment variables can also be specified on the command line with `--mount` and `--env`. They follow the same format as described in [Image format (/etc/fstab)](../image-format.md) and [Image format (/etc/environment)](../image-format.md)
with the exception that fstab fields are colon-separated.


### Configuration script

Configuration scripts are standard bash scripts called before any containerization happened with the command and arguments of the container passed as input parameters.

One or more of the following functions can be defined:

| Function | Description |
| ------ | ------ |
| `environ()` | Outputs [environment configuration](../configuration.md#environment-configuration-files) |
| `mounts()` | Outputs [mount configuration](../configuration.md#mount-configuration-files) |
| `hooks()` | A specific instance of [pre-start hook scripts](../configuration.md#pre-start-hook-scripts) |

Here is an example of such configuration:

```sh
environ() {
    # Keep all the environment from the host
    env
}

mounts() {
    # Mount the X11 unix-domain socket
    echo "/tmp/.X11-unix /tmp/.X11-unix none x-create=dir,bind"
    
    # Mount the current working directory to /mnt
    echo "${PWD} /mnt none bind"
}

hooks() {
    # Set the DISPLAY environment variable if not set
    [ -z "${DISPLAY-}" ] && echo "DISPLAY=:0.0" >> ${ENROOT_ENVIRON}
    
    # Record the date when the container was last started
    date > ${ENROOT_ROOTFS}/last_started
}
```

### Starting container images

Since Linux 4.18, it is now possible to start container images directly without the need to create containers first.
Enroot will attempt to do so if the following programs are installed on the host:
* [fuse-overlayfs](https://github.com/containers/fuse-overlayfs)
* [squashfuse](https://github.com/vasi/squashfuse)

Note that all changes will be stored in memory and will not persist after the container terminates.

# Configuration

| Setting | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_LOGIN_SHELL` | `/bin/sh` | Login shell used to run the container initialization |
| `ENROOT_ROOTFS_WRITABLE` | `no` |  Make the container root filesystem writable (same as `--rw`) |
| `ENROOT_REMAP_ROOT` | `no` | Remap the current user to root inside containers (same as `--root`) |

See also [Standard Hooks](../standard-hooks.md) for additional configuration.

# Example

```sh
# Edit a file from the current directory within a CentOS container
$ echo Hello World > foo
$ enroot start --root --rw --env EDITOR --mount .:mnt centos sudoedit /mnt/foo
```

```sh
# Import a CUDA development image from DockerHub and compile a program locally (Linux >= 4.18)
$ enroot import docker://nvidia/cuda:10.0-devel
$ enroot start --mount .:mnt cuda+devel.sqsh nvcc /mnt/hello-world.cu
```
