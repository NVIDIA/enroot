# Usage
```
Usage: enroot bundle [options] [--] IMAGE

Create a self-extracting bundle from a container image.

 Options:
   -a, --all            Include user configuration files in the bundle
   -c, --checksum       Generate an embedded checksum
   -d, --desc TEXT      Provide a description of the bundle
   -o, --output BUNDLE  Name of the output bundle file (defaults to "IMAGE.run")
   -t, --target DIR     Target directory used by --keep (defaults to "$PWD/BUNDLE")
```
```
Usage: bundle.run [options] [--] [COMMAND] [ARG...]

 Options:
   -i, --info           Display the information about this bundle
   -k, --keep           Keep the bundle extracted in the target directory
   -q, --quiet          Supress the progress bar output
   -v, --verify         Verify that the host configuration is compatible with the bundle
   -x, --extract        Extract the bundle in the target directory and exit (implies --keep)

   -c, --conf CONFIG    Specify a configuration script to run before the container starts
   -e, --env KEY[=VAL]  Export an environment variable inside the container
       --rc SCRIPT      Override the command script inside the container
   -m, --mount FSTAB    Perform a mount from the host inside the container (colon-separated)
   -r, --root           Ask to be remapped to root inside the container
   -w, --rw             Make the container root filesystem writable
```

# Description

Create a self-extracting bundle from a container image which can be used to start a container on most Linux distributions with no external dependencies.  
The resulting bundle takes the same arguments as the [start](start.md) command.

The target directory used to keep the container filesystem can be defined using the `--target` option and defaults to `$PWD/<bundle>`.  
By default when generating a bundle, only system-wide configuration is copied to the bundle unless `--all` is specified, in which case user-specified configuration is copied as well.  

Before executing a bundle, `--verify` can be used to check whether or not the host meets the necessary requirements.

If `--keep` is not provided at launch, `$ENROOT_TEMP_PATH` will be used for extraction.

# Configuration

| Environment | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_BUNDLE_ALL` | `no` | Include user-specific configuration inside bundles (same as `--all`) |
| `ENROOT_BUNDLE_CHECKSUM` | `no` | Generate an embedded checksum inside bundles (same as `--checksum`) |

# Example

```sh
# Import Ubuntu from DockerHub and generate a bundle from it
$ enroot import docker://ubuntu
$ enroot bundle --target '${HOME}/.local/share/enroot/hello-world' ubuntu.sqsh

# Execute the bundle by writing a message at the root of its filesystem and keep it extracted
$ ./ubuntu.run --keep --rw tee /message <<< "Hello World"

# Display the message inside the bundle root filesystem
$ enroot start hello-world cat /message
```
