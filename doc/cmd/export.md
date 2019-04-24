# Usage

```
Usage: enroot export [options] [--] NAME

Create a container image from a container root filesystem.

 Options:
   -o, --output  Name of the output image file (defaults to "NAME.sqsh")
```

# Description

Export a container root filesystem from under `$ENROOT_DATA_PATH/` to a container image.  
The resulting image can be unpacked using the [create](create.md) command.

# Configuration

| Setting | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_SQUASH_OPTIONS` | `-comp lzo -noD` | Options passed to mksquashfs to produce container images |

# Example

```sh
# Create an Alpine linux container image
$ cd ~/.local/share/enroot && mkdir alpine
$ curl -fSsL http://dl-cdn.alpinelinux.org/[...] | tar -C alpine -xz
$ enroot export --output alpine.sqsh alpine
```

