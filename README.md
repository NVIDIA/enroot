# ENROOT

A set of scripts and utilities to run container images as unprivileged "chroot" (or what some people refer to as HPC containers).

Example:
```bash
enroot import docker://alpine
enroot create alpine.squashfs
enroot start alpine
```

## Prerequisites

Kernel settings:
```bash
# Make sure your kernel supports what's required
grep -E '(CONFIG_NAMESPACES|CONFIG_USER_NS|CONFIG_OVERLAY_FS)=' /boot/config-$(uname -r)

# Configure namespace limits appropriately if necessary
sudo tee -a /etc/sysctl.d/10-namespace.conf <<< "user.max_user_namespaces = 65536"
sudo tee -a /etc/sysctl.d/10-namespace.conf <<< "user.max_mnt_namespaces = 65536"

# Debian distributions
sudo tee -a /etc/sysctl.d/10-namespace.conf <<< "kernel.unprivileged_userns_clone = 1"

# RHEL distributions
sudo grubby --args="namespace.unpriv_enable=1 user_namespace.enable=1" --update-kernel="$(grubby --default-kernel)"

sudo reboot
```

Dependencies:
```bash
# Debian distributions
sudo apt install -y gcc make libcap2-bin libbsd-dev
sudo apt install -y file curl tar pigz jq gettext squashfs-tools parallel

# RHEL distributions
sudo yum install -y epel-release
sudo yum install -y gcc make libcap libbsd-devel
sudo yum install -y file curl tar pigz jq gettext squashfs-tools parallel
````

## Installation

```bash
sudo make install

# In order to allow unprivileged users to import images
sudo make setcap
```

Environment settings:

| Environment | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_LIBEXEC_PATH` | `/usr/local/libexec/enroot` | Path to sources and utilities |
| `ENROOT_SYSCONF_PATH` | `/usr/local/etc/enroot` | Path to system configuration files |
| `ENROOT_CONFIG_PATH` | `$XDG_CONFIG_HOME/enroot` | Path to user configuration files |
| `ENROOT_CACHE_PATH` | `$XDG_CACHE_HOME/enroot` | Path to user image/credentials cache |
| `ENROOT_DATA_PATH` | `$XDG_DATA_HOME/enroot` | Path to user container storage |
| `ENROOT_RUNTIME_PATH` | `$XDG_RUNTIME_DIR/enroot` | Path to user working directories |

## Usage
```
Usage: enroot COMMAND [ARG...]

 Commands:
    version
    import [--output|-o IMAGE] URI
    create [--name|-n NAME] IMAGE
    start [--root|-r] [--rw|-w] [--conf|-c CONFIG] NAME [COMMAND] [ARG...]
    list
    remove NAME
```

## Commands

### version
Show the version of Enroot.

### import
Import and convert a Docker container image to an [Enroot image](#image-format) where the URI is of the form  
`docker://[<user>@][<registry>#]<image>[:<tag>]`. Digests will be cached under `$ENROOT_CACHE_PATH`.

Credentials can be configured by writing to the file `$ENROOT_CONFIG_PATH/.credentials` following the netrc file format. For example:
```
# NVIDIA GPU Cloud
machine authn.nvidia.com login $oauthtoken password <TOKEN>
# Docker Hub
machine auth.docker.io login <LOGIN> password <PASSWORD>
```

Environment settings:

| Environment | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_GZIP_PROG` | `pigz` _or_ `gzip` | Gzip program used to uncompress digest layers |
| `ENROOT_SQUASH_OPTS` | `-comp lzo -noD` | Options passed to `mksquashfs` to produce the image |

### create
Take a container image and unpack its root filesystem under `$ENROOT_DATA_PATH` with the given name (optional).  
The resulting artifact can then be started using the [start](#start) command.

### start
Start a previously [created](#create) container by executing its init script (or entrypoint), refer to [Image format (/etc/rc.local)](#image-format).  
By default the root filesystem of the container is made read-only unless the `--rw` option has been provided.  
The `--root` option can also be provided in order to remap your current user to be root inside the container.

Additionally, a configuration script can be provided with `--conf` to perform specific actions before the container starts.  
This script is a  standard bash script which includes one or more of the following functions:

| Function | Description |
| ------ | ------ |
| `environ()` | Outputs [environment configuration](#environment-configuration-files) |
| `mounts()` | Outputs [mount configuration](#mount-configuration-files) |
| `hooks()` | A specific instance of [pre-start hook scripts](#pre-start-hook-scripts) |

Here is an example of such configuration:

```bash
environ() {
    # Keep all the environment from the host
    env
}

mounts() {
    # Mount the X11 unix-domain socket
    echo "/tmp/.X11-unix /tmp/.X11-unix none x-create=dir,bind"
    # Mount the current working directory to /mnt
    echo "$PWD /mnt none bind"
}

hooks() {
    # Set the DISPLAY environment variable if not set
    [ -z "${DISPLAY-}" ] && echo "DISPLAY=:0.0" >> $ENROOT_ENVIRON
    # Record the date when the container was last started
    date > $ENROOT_ROOTFS/last_started
}
```

Environment settings:

| Environment | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_INIT_SHELL` | `/bin/sh` | Shell used to run the init script (entrypoint) |
| `ENROOT_ROOTFS_RW` | | Equivalent to `--rw` if set |
| `ENROOT_REMAP_ROOT` | | Equivalent to `--root` if set |

### list
List all the  containers along with their size on disk.

### remove
Remove a container, deleting its root filesystem from disk.

## Image format
Enroot images are standard squashfs images with the following configuration files influencing runtime behaviors.

| File | Description |
| ------ | ------ |
| `/etc/fstab` | Mount configuration of the container |
| `/etc/rc.local` | Init script of the container (entrypoint) |
| `/etc/environment` | Environment of the container |

These files follow the same format as the standard Linux/Unix ones (see _fstab(5)_, _rc(8)_, _pam_env(8)_) with the exceptions listed below.

`/etc/fstab`:
  - Adds two additional mount options, `x-create=dir` or `x-create=file` to create an empty directory or file before performing the mount.

```
# Example mounting the home directory of user foobar from the host
/home/foobar /home/foobar none x-create=dir,bind
```

`/etc/rc.local`:
  - The command and arguments of the [start](#start) command are passed as input parameters.


`/etc/environment`:
  - Variables can be substituted with host environment variables

 ```bash
 # Example preserving the DISPLAY environment variable from the host
 DISPLAY=$DISPLAY
 ```

## Configuration

Common configurations can be applied to all containers by leveraging the following directories under `$ENROOT_SYSCONF_PATH` (system-wide) and/or `$ENROOT_CONFIG_PATH` (user-specific).

| Directory | Description |
| ------ | ------ |
| `environ.d` | Environment configuration files |
| `mounts.d` | Mount configuration files |
| `hooks.d` | Pre-start hook scripts |

### Environment configuration files
Environment files have the `.env` extension and follow the same format as described in [Image format (/etc/environment)](#image-format)

### Mount configuration files
Mount files have the `.fstab` extension and follow the same format as described in [Image format (/etc/fstab)](#image-format)

### Pre-start hook scripts
Pre-start hooks are standard bash scripts with the `.sh` extension.  
They run with full capabilities before the container has switched to its final root.  
Scripts are started with the container environment (excluding PATH and LD_LIBRARY_PATH) as well as the following environment variables:

| Environment | Description |
| ------ | ------ |
| `ENROOT_PID` | PID of the container |
| `ENROOT_ROOTFS` | Path to the container rootfs |
| `ENROOT_ENVIRON` | Path to the container environment file to be read at startup |
| `ENROOT_WORKDIR` | Temporary working directory |
