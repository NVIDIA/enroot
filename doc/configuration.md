# Configuration

The runtime can be configured through the file `enroot.conf` (under `/etc/enroot` by default) or by using environment variables.
Environment variables take precedence over the configuration file.

The following table describes standard paths used by the runtime:

| Setting | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_LIBRARY_PATH` | `/usr/lib/enroot` | Path to library sources |
| `ENROOT_SYSCONF_PATH` | `/etc/enroot` | Path to system configuration files |
| `ENROOT_RUNTIME_PATH` | `${XDG_RUNTIME_DIR}/enroot` | Path to the runtime working directory |
| `ENROOT_CONFIG_PATH` | `${XDG_CONFIG_HOME}/enroot` | Path to user configuration files |
| `ENROOT_CACHE_PATH` | `${XDG_CACHE_HOME}/enroot` | Path to user image/credentials cache |
| `ENROOT_DATA_PATH` | `${XDG_DATA_HOME}/enroot` | Path to user container storage |
| `ENROOT_TEMP_PATH` | `${TMPDIR}` | Path to temporary directory |


Common configurations can be applied to all containers by leveraging the following directories under `ENROOT_SYSCONF_PATH` (system-wide) and/or `ENROOT_CONFIG_PATH` (user-specific).

| Directory | Description |
| ------ | ------ |
| `environ.d` | Environment configuration files |
| `mounts.d` | Mount configuration files |
| `hooks.d` | Pre-start hook scripts |

### Environment configuration files
Environment files are used to export environment variables inside containers.  
They have the `.env` extension and follow the same format as described in [Image format (/etc/environment)](image-format.md).

### Mount configuration files
Mount files are used to mount filesystems, files or directories inside containers.  
They have the `.fstab` extension and follow the same format as described in [Image format (/etc/fstab)](image-format.md).

### Pre-start hook scripts
Pre-start hooks are used to perform specific actions before the container starts.  
They are standard bash scripts with the `.sh` extension and run with full capabilities before the container has switched to its final root.  

---

The host environment as well as the following environment variables is made available to hooks and configuration files: 

| Environment | Description |
| ------ | ------ |
| `ENROOT_PID` | PID of the container |
| `ENROOT_ROOTFS` | Path to the container root filesystem |
| `ENROOT_ENVIRON` | Path to the container environment file to be read at startup |
