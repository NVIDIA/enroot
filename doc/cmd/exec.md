# Usage
```
Usage: enroot exec [options] [--] PID COMMAND [ARG...]

Execute a command inside an existing container.

 Options:
   -e, --env KEY[=VAL]  Export an environment variable inside the container
```

# Description

Execute a command inside an existing container referred to by a proccess identifier.  
The process identifier of a container can be obtained using the [list](list.md) command.

# Example

```bash
# Start an alpine container, print its process identifier and sleep forever.
$ enroot start alpine sh -c 'echo $$; sleep infinity'
12019

# Execute bash inside the running container.
$ enroot exec 12019 bash
