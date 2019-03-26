/*
 * Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.
 */

#define _GNU_SOURCE
#include <err.h>
#include <errno.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sched.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "common.h"

#ifndef __x86_64__
# error "unsupported architecture"
#endif

#ifndef PR_CAP_AMBIENT
# define PR_CAP_AMBIENT 47
#endif
#ifndef PR_CAP_AMBIENT_IS_SET
# define PR_CAP_AMBIENT_IS_SET 1
#endif
#ifndef PR_CAP_AMBIENT_RAISE
# define PR_CAP_AMBIENT_RAISE 2
#endif

static struct capabilities_v3 caps;

static struct sock_filter filter[] = {
        /* Check for the syscall architecture (x86_64 and x32 ABIs). */
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, AUDIT_ARCH_X86_64, 1, 0),
        BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_KILL),

        /* Load the syscall number. */
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, nr)),

        /* Return success on all the following syscalls. */
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setuid,    15, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setgid,    14, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setreuid,  13, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setregid,  12, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setresuid, 11, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setresgid, 10, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setgroups, 9,  0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_fchownat,  8,  0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_chown,     7,  0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_fchown,    6,  0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_lchown,    5,  0),

        /* For setfsuid/setfsgid we only return success if the uid/gid argument is not -1. */
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setfsuid, 1, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setfsgid, 0, 2),
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, args[0])),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, (uint32_t)-1, 0, 1),

        /* Execute the syscall as usual otherwise. */
        BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_RET_DATA & 0x0)),
};

int
main(int argc, char *argv[])
{
        bool map_root = false;

        CAP_INIT_V3(&caps);

        if (argc >= 2 && !strcmp(argv[1], "--root")) {
                argv[1] = argv[0];
                ++argv; --argc;
                map_root = true;
        }
        if (argc < 2)
                errx(EXIT_FAILURE, "usage: %s [--root] program [arguments]", argv[0]);
        if (!map_root && prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_IS_SET, 0, 0, 0) < 0 && errno == EINVAL)
                errx(EXIT_FAILURE, "kernel lacks support for ambient capabilities, consider using --root instead");

        if (unshare_userns(map_root) < 0)
                err(EXIT_FAILURE, "failed to unshare user namespace");
        if (unshare(CLONE_NEWNS) < 0)
                err(EXIT_FAILURE, "failed to unshare mount namespace");

        if (!map_root) {
                /* Raise ambient capabilities. */
                if (capget(&caps.hdr, caps.data) < 0)
                        err(EXIT_FAILURE, "failed to get capabilities");

                CAP_COPY(&caps, inheritable, effective);
                if (capset(&caps.hdr, caps.data) < 0)
                        err(EXIT_FAILURE, "failed to set capabilities");

                CAP_FOREACH(&caps, n) {
                        if (CAP_ISSET(&caps, inheritable, n)) {
                                if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_RAISE, n, 0, 0) < 0)
                                        err(EXIT_FAILURE, "failed to set capabilities");
                        }
                }
        }

        if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &(const struct sock_fprog){ARRAY_SIZE(filter), filter}) < 0)
                err(EXIT_FAILURE, "failed to register seccomp filter");

        if (execvp(argv[1], &argv[1]) < 0)
                err(EXIT_FAILURE, "failed to execute: %s", argv[1]);
        return (0);
}
