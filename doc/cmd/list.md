# Usage
```
Usage: enroot list [options]

List all the container root filesystems on the system.

 Options:
   -f, --fancy  Display more information in tabular format
```

# Description

List all the containers on the system and optionally their size on disk.

# Example

```sh
$ enroot list --fancy
SIZE    NAME
5.9M    alpine
391M    centos
208M    centos+6
131M    debian+8-slim
```
