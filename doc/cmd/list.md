# Usage
```
Usage: enroot list [options]

List all the container root filesystems on the system.

 Options:
   -f, --fancy  Display more information in tabular format
```

# Description

List all the containers on the system and additional information like their size on disk and the processes started.

# Example

```sh
$ enroot list --fancy
NAME       SIZE  PID    STATE  STARTED   TIME   MNTNS       USERNS      COMMAND
alpine     5.9M
busybox    1.3M
centos     235M  24353  S+     05:39:23  06:54  4026533442  4026533441  -sh
                 24522  S+     05:39:31  06:46  4026533439  4026533438  -sh
ubuntu     70M   24733  S+     05:39:48  06:29  4026533445  4026533444  sleep infinity
```
