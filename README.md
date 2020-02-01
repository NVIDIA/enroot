# ENROOT

A simple, yet powerful tool to turn traditional container/OS images into unprivileged sandboxes.

Enroot can be thought of as an enhanced unprivileged `chroot(1)`. It uses the same underlying technologies as containers but removes much of the isolation they inherently provide while preserving filesystem separation.

This approach is generally preferred in high-performance environments or virtualized environments where portability and reproducibility is important, but extra isolation is not warranted.

Enroot is also similar to other tools like `proot(1)` or `fakeroot(1)` but instead relies on more recent features from the Linux kernel (i.e. user and mount namespaces), and provides facilities to import well known container image formats (e.g. [Docker](https://www.docker.com/)).

Usage example:

```sh
# Import and start an Ubuntu image from DockerHub
$ enroot import docker://ubuntu
$ enroot create ubuntu.sqsh
$ enroot start ubuntu
```

## Key Concepts

* Adheres to the [KISS principle](https://en.wikipedia.org/wiki/KISS_principle) and [Unix philosophy](https://en.wikipedia.org/wiki/Unix_philosophy)
* Standalone (no daemon)
* Fully unprivileged and multi-user capable (no setuid binary, cgroup inheritance, per-user configuration/container store...)
* Easy to use (simple image format, scriptable, root remapping...)
* Little to no isolation (no performance overhead, simplifies HPC deployements)
* Entirely composable and extensible (system-wide and user-specific configurations)
* Fast Docker image import (3x to 5x speedup on large images)
* Built-in GPU support with [libnvidia-container](https://github.com/nvidia/libnvidia-container)
* Facilitate collaboration and development workflows (bundles, in-memory containers...)

## Documentation

1. [Requirements](doc/requirements.md)
1. [Installation](doc/installation.md)
1. [Image format](doc/image-format.md)
1. [Configuration](doc/configuration.md)
1. [Standard Hooks](doc/standard-hooks.md)
1. [Usage](doc/usage.md)


## Copyright and License

This project is released under the [Apache License 2.0](https://github.com/NVIDIA/enroot/blob/master/LICENSE).

## Issues and Contributing

* Please let us know by [filing a new issue](https://github.com/NVIDIA/enroot/issues/new)
* You can contribute by opening a [pull request](https://help.github.com/articles/using-pull-requests/), please make sure you read [CONTRIBUTING](CONTRIBUTING.md) first.

## Reporting Security Issues

When reporting a security issue, do not create an issue or file a pull request.  
Instead, disclose the issue responsibly by sending an email to `psirt<at>nvidia.com`.
