# Usage
```
Usage: enroot remove [options] [--] NAME...

Delete one or multiple container root filesystems.

 Options:
   -f, --force  Do not prompt for confirmation
```

# Description

Remove one or multiple containers, deleting their root filesystem from disk.

# Configuration

| Setting | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_FORCE_OVERRIDE` | `no` | Remove container root filesystems without prompting for confirmation (same as `--force`) |

# Example

```sh
# Force remove all the containers from the system
$ enroot remove --force $(enroot list)
```
