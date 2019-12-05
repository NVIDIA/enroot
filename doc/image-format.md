# Image format

Enroot container images are standard [squashfs](https://www.kernel.org/doc/Documentation/filesystems/squashfs.txt) images with the following configuration files influencing the container runtime behavior:

| File | Description |
| ------ | ------ |
| `/etc/rc` | Command script of the container (entrypoint) |
| `/etc/fstab` | Mount configuration of the container |
| `/etc/environment` | Environment of the container |

These files follow the same format as the standard Linux/Unix ones (see _fstab(5)_, _rc(8)_, _pam_env(8)_) with the exceptions listed below.

* `/etc/rc`:
  - The command and arguments of the [start](cmd/start.md) command are passed as input parameters.


* `/etc/fstab`:
  - The target mountpoint is relative to the container rootfs.
  - Allows some fields to be omitted where it makes sense, for example `/proc /proc rbind` or `tmpfs /tmp` are valid fstab entries.
  - Adds the mount options `x-create=dir`, `x-create=file` and `x-create=auto` to create an empty directory or file before performing the mount.
  - Adds the mount options `x-move` and `x-detach` to move or detach a mountpoint respectively.
  - References to environment variables from the host of the form `${ENVVAR}` will be substituted.
  - The `fs_freq` field is ignored and the `fs_passno` is instead used to specify a specific mount order.

```sh
# Example mounting the current working directory from the host inside the container
${PWD} /mnt none x-create=dir,bind
```

* `/etc/environment`:
  - References to environment variables from the host of the form `${ENVVAR}` will be substituted.

 ```sh
 # Example preserving the DISPLAY environment variable from the host
 DISPLAY=${DISPLAY}
 ```
