# Requirements

The list of prerequisites for running Enroot is described below.

You can automatically check these by running the `enroot-check` bundle for a given release:
```sh
$ curl -fSsL -O https://github.com/NVIDIA/enroot/releases/download/v3.2.0/enroot-check_3.2.0_$(uname -m).run
$ chmod +x enroot-check_*.run

$ ./enroot-check_*.run --verify

$ ./enroot-check_*.run
Bundle ran successfully!
```

## Kernel version
Linux Kernel >= 3.10

## Kernel configuration
The following kernel configuration options must be enabled:
  * `CONFIG_NAMESPACES`
  * `CONFIG_USER_NS`
  * `CONFIG_SECCOMP_FILTER`
  
  * In order to import Docker images or use `enroot-mksquashovlfs`
    - `CONFIG_OVERLAY_FS`
  * In order to run containers with a glibc <= 2.13
    - `CONFIG_X86_VSYSCALL_EMULATION`
    - `CONFIG_VSYSCALL_EMULATE` (recommended) or `CONFIG_VSYSCALL_NATIVE` (or `vsycall=...` see below)

## Kernel command line
The following kernel command line parameters must be set:
* In order to run containers with a glibc <= 2.13
  - `vsyscall=emulate` (recommended) or `vsyscall=native`
  
* On RHEL-based distributions
  - `namespace.unpriv_enable=1`
  - `user_namespace.enable=1`

## Kernel settings
The following kernel settings must be set accordingly:

* Linux 4.9 onwards
  - `/proc/sys/user/max_user_namespaces` must be greater than 1
  - `/proc/sys/user/max_mnt_namespaces` must be greater than 1

* On some distributions (e.g. Archlinux-based, Debian-based)
  - `/proc/sys/kernel/unprivileged_userns_clone` must be enabled (equal to 1)

## GPU support (optional)

* GPU architecture > 2.1 (Fermi)
* [NVIDIA drivers](https://www.nvidia.com/object/unix.html) >= 361.93 (untested on older versions)
* [libnvidia-container-tools](https://nvidia.github.io/libnvidia-container/) >= 1.0
