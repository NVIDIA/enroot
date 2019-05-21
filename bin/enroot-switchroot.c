/*
 * Copyright (c) 2018-2019, NVIDIA CORPORATION. All rights reserved.
 */

#define _GNU_SOURCE
#include <bsd/inttypes.h>
#include <bsd/unistd.h>
#include <ctype.h>
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/securebits.h>
#include <paths.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>

#include "common.h"

#ifndef CLONE_NEWCGROUP
# define CLONE_NEWCGROUP 0x02000000
#endif

#ifndef SHELL
# define SHELL _PATH_BSHELL
#endif

static int
read_last_cap(uint32_t *lastcap)
{
        FILE *fs;

        if ((fs = fopen("/proc/sys/kernel/cap_last_cap", "r")) == NULL)
                return (-1);
        if (fscanf(fs, "%3"PRIu32, lastcap) != 1) {
                fclose(fs);
                errno = ENOSYS;
                return (-1);
        }
        if (fclose(fs) < 0)
                return (-1);
        return (0);
}

static int
drop_privileges(uint32_t lastcap)
{
        struct capabilities_v3 caps;

        CAP_INIT_V3(&caps);

        if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0)
                return (-1);

        if (geteuid() == 0)
                return (0);

        for (uint32_t n = 0; n <= lastcap; ++n) {
                if (prctl(PR_CAPBSET_DROP, n, 0, 0, 0) < 0 && errno != EPERM)
                        return (-1);
        }
        if (capset(&caps.hdr, caps.data) < 0)
                return (-1);
        return (0);
}

static int
switch_root(const char *rootfs)
{
        int oldroot = -1, newroot = -1;

        if ((oldroot = open("/", O_PATH|O_DIRECTORY)) < 0)
                goto err;
        if ((newroot = open(rootfs, O_PATH|O_DIRECTORY)) < 0)
                goto err;

        if (fchdir(newroot) < 0)
                goto err;
        if ((int)syscall(SYS_pivot_root, ".", ".") < 0)
                goto err;
        if (fchdir(oldroot) < 0)
                goto err;
        if (umount2(".", MNT_DETACH) < 0)
                goto err;
        if (fchdir(newroot) < 0)
                goto err;
        if (chroot(".") < 0)
                goto err;
        if (unshare(CLONE_NEWCGROUP) < 0 && errno != EINVAL)
                goto err;

        if (close(oldroot) < 0)
                goto err;
        if (close(newroot) < 0)
                goto err;
        return (0);

 err:
        SAVE_ERRNO(close(oldroot));
        SAVE_ERRNO(close(newroot));
        return (-1);
}

static bool
envvar_valid(const char *str)
{
        if (strchr(str, '=') == NULL)
                return (false);
        if (!isalpha(*str) && *str != '_')
                return (false);
        while (*++str != '=') {
                if (!isalnum(*str) && *str != '_')
                        return (false);
        }
        return (true);
}

static int
load_environment(const char *envfile)
{
        int fd;
        struct stat s;
        size_t len = 0;
        void *buf = MAP_FAILED;
        char *ptr, *envvar;

        if ((fd = open(envfile, O_RDONLY)) < 0)
                goto err;
        if (fstat(fd, &s) < 0) {
                SAVE_ERRNO(close(fd));
                goto err;
        }
        len = (size_t)s.st_size;
        if ((buf = mmap(NULL, len, PROT_READ|PROT_WRITE, MAP_PRIVATE, fd, 0)) == MAP_FAILED) {
                SAVE_ERRNO(close(fd));
                goto err;
        }
        if (close(fd) < 0)
                goto err;

        ptr = buf;
        if (clearenv() < 0)
                goto err;
        while ((envvar = strsep(&ptr, "\n")) != NULL) {
                if (*envvar == '\0' || !envvar_valid(envvar))
                        continue;
                if (putenv(envvar) < 0)
                        goto err;
        }
        return (0);

 err:
        if (buf != MAP_FAILED)
                SAVE_ERRNO(munmap(buf, len));
        return (-1);
}

static int
parse_fd(const char *str)
{
        int e, fd;

        if (!strcmp(str, "-"))
                return (0);
        fd = (int)strtoi(str + 1, NULL, 10, 1, INT_MAX, &e);
        if (e != 0) {
                errno = e;
                return (-1);
        }
        return (fd);
}

int
main(int argc, char *argv[])
{
        bool login = false;
        char *envfile = NULL;
        const char *shell;
        uint32_t lastcap;
        int fd = -1;

        for (;;) {
                if (argc >= 2 && !strcmp(argv[1], "--login")) {
                        login = true;
                        SHIFT_ARGS(1);
                        continue;
                }
                if (argc >= 3 && !strcmp(argv[1], "--env")) {
                        envfile = argv[2];
                        SHIFT_ARGS(2);
                        continue;
                }
                break;
        }
        if (argc < 3) {
                printf("Usage: %s [--login] [--env FILE] ROOTFS COMMAND|-[FD] [ARG...]\n", argv[0]);
                return (0);
        }

        if (*argv[2] == '-' && (fd = parse_fd(argv[2])) < 0)
                err(EXIT_FAILURE, "invalid file descriptor: %s", argv[2] + 1);

        if ((shell = getenv("SHELL")) == NULL)
                shell = SHELL;
        if (*shell != '/')
                errx(EXIT_FAILURE, "SHELL environment variable must be an absolute path");

        if (envfile != NULL) {
                if (load_environment(envfile) < 0)
                        err(EXIT_FAILURE, "failed to load environment: %s", envfile);
        }

        if (read_last_cap(&lastcap) < 0)
                err(EXIT_FAILURE, "failed to read last capability");
        if (switch_root(argv[1]) < 0)
                err(EXIT_FAILURE, "failed to switch root: %s", argv[1]);
        if (drop_privileges(lastcap) < 0)
                err(EXIT_FAILURE, "failed to drop privileges");

        if (fd < 0)
                argv[1] = (char *)"-c";
        else {
                SHIFT_ARGS(1);
                if (asprintf(&argv[1], "/proc/self/fd/%d", fd) < 0)
                        err(EXIT_FAILURE, "failed to allocate memory");
        }
        if (asprintf(&argv[0], "%s%s", login ? "-" : "", shell) < 0)
                err(EXIT_FAILURE, "failed to allocate memory");

        for (int i = STDERR_FILENO + 1; i < fd; ++i)
                close(i);
        closefrom((fd < 0 ? STDERR_FILENO : fd) + 1);

        if (execve(shell, argv, environ) < 0)
                err(EXIT_FAILURE, "failed to execute: %s", shell);
        return (0);
}
