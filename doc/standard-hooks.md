# Standard Hooks

Several [pre-start hook scripts](configuration.md#pre-start-hook-scripts) are provided by default.  
Some of them can be turned on or off by using the following configuration settings:

| Hook | Setting | Default | Description |
| ---- | ------ | ------ | ------ |
| [10-devices.sh](#10-devicessh) | `ENROOT_RESTRICT_DEV` | `no` | Restrict `/dev` inside the container to a minimal set of devices |
| [10-home.sh](#10-homesh) | `ENROOT_MOUNT_HOME` | `no` |  Mount the current user's home directory |
| [98-nvidia.sh](#98-nvidiash) | `NVIDIA_[...]` | | Control NVIDIA GPU support |
| [99-mellanox.sh](#99-mellanoxsh) | `MELLANOX_[...]` | | Control MELLANOX HCA support |

---

### 10-cgroups.sh

Automatically mount the cgroup subsytems inside the container within a new cgroup namespace (if supported).

This hook is always enabled.

### 10-devices.sh

Restrict `/dev` inside the container to a minimal set of devices.

To enable it, one needs to set `ENROOT_RESTRICT_DEV`.

### 10-home.sh

Mount the current user's home directory inside the container and set the `HOME` environment variable accordingly.

To enable it, one needs to set `ENROOT_MOUNT_HOME`.

### 10-shadow.sh

Add new user and group entries to the container shadow databases `/etc/passwd` and `/etc/group`, these entries reflect the current user on the host.  
Additionally, create home and mail directories as defined by `/etc/login.defs` and `/etc/default/useradd` inside the container.

This hook is always enabled.

### 20-autorc.sh

Search the current directory for a file named `enroot.rc` or `<container_prefix>.rc` (where prefix matches `[A-Za-z0-9_]+`), and use it as the command script (or entrypoint) for the container.  
Refer to [Image format (/etc/rc)](image-format.md) for more information.

This hook is always enabled.

### 98-nvidia.sh
Provide GPU support to the container using [libnvidia-container](https://github.com/NVIDIA/libnvidia-container).  
Refer to [nvidia-container-runtime (Environment variables)](https://github.com/NVIDIA/nvidia-container-runtime/#environment-variables-oci-spec)
for the list of supported settings and how to enable them.

### 99-mellanox.sh
Provide IB HCA support to the container by injecting MOFED from the host inside the container.  
Devices are controlled with the `MELLANOX_VISIBLE_DEVICES` environment variable similar to how [98-nvidia.sh](#98-nvidiash) exposes GPUs.
