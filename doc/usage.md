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
# Import the CUDA 10.0 image from NVIDIA GPU Cloud
$ enroot import 'docker://$oauthtoken@nvcr.io#nvidia/cuda:10.0-base'

# Create a container out of it
$ enroot create --name cuda nvidia+cuda+10.0-base.sqsh
$ enroot list
cuda

# Compile the nbody sample inside the container
$ enroot start --root --rw cuda sh -c 'apt update && apt install -y cuda-samples-10.0'
$ enroot start --rw cuda sh -c 'cd /usr/local/cuda/samples/5_Simulations/nbody && make -j'

# Run nbody leveraging the X server from the host
$ export ENROOT_MOUNT_HOME=y NVIDIA_DRIVER_CAPABILITIES=all
$ enroot start --env DISPLAY --env NVIDIA_DRIVER_CAPABILITIES --mount /tmp/.X11-unix:/tmp/.X11-unix cuda \
    /usr/local/cuda/samples/5_Simulations/nbody/nbody

# Remove the container
$ enroot remove cuda
```
