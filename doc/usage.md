# Usage

```
Usage: enroot COMMAND [ARG...]

Command line utility for manipulating container sandboxes.

 Commands:
   batch  [options] [--] CONFIG [COMMAND] [ARG...]
   bundle [options] [--] IMAGE
   create [options] [--] IMAGE
   exec   [options] [--] PID COMMAND [ARG...]
   export [options] [--] NAME
   import [options] [--] URI
   list   [options]
   remove [options] [--] NAME...
   start  [options] [--] NAME|IMAGE [COMMAND] [ARG...]
   version
```

## Commands

Refer to the documentation below for details on each command usage:

* [batch](cmd/batch.md)
* [bundle](cmd/bundle.md)
* [create](cmd/create.md)
* [exec](cmd/exec.md)
* [export](cmd/export.md)
* [import](cmd/import.md)
* [list](cmd/list.md)
* [remove](cmd/remove.md)
* [start](cmd/start.md)
* [version](cmd/version.md)

## Example

```sh
# Import the CUDA 12.9.1 image from NVIDIA GPU Cloud (NGC)
$ enroot import docker://nvcr.io#nvidia/cuda:12.9.1-devel-ubuntu24.04

# Create a container out of it
$ enroot create --name cuda nvidia+cuda+12.9.1-devel-ubuntu24.04.sqsh
$ enroot list
cuda

# Compile the vectorAdd sample inside the container
$ enroot start --root --rw cuda sh -c 'apt update && apt install --no-install-recommends -y git cmake'
$ enroot start --root --rw cuda sh -c 'git clone --branch=v12.9 https://github.com/NVIDIA/cuda-samples.git /usr/local/cuda/samples'
$ enroot start --rw cuda sh -c 'cd /usr/local/cuda/samples/Samples/0_Introduction/vectorAdd && cmake . && make -j'

# Run vectorAdd
$ enroot start --rw cuda /usr/local/cuda/samples/Samples/0_Introduction/vectorAdd/vectorAdd

# Export the modified container as a container image
$ enroot export --output cuda-vecadd.sqsh cuda

# Remove the container
$ enroot remove cuda
```
