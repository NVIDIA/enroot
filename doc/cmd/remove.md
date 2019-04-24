# Usage
```
Usage: enroot remove [options] [--] NAME...

Delete one or multiple container root filesystems.

 Options:
   -f, --force  Do not prompt for confirmation
```

# Description

Remove one or multiple containers, deleting their root filesystem from disk.

# Example

```sh
# Force remove all the containers from the system
$ enroot remove --force $(enroot list)
```
