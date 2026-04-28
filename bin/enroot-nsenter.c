/*
 * Copyright (c) 2018-2026, NVIDIA CORPORATION. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if !defined(__x86_64__) && !defined(__aarch64__) && !defined(__powerpc64__)
# error "unsupported architecture"
#endif

#ifdef __aarch64__
#define __ARCH_WANT_SYSCALL_NO_AT
#endif

#define _GNU_SOURCE
#include <elf.h>
#include <err.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <net/if.h>
#include <sched.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#include <bsd/inttypes.h>
#include <bsd/unistd.h>

#include "common.h"

#ifndef PR_CAP_AMBIENT
# define PR_CAP_AMBIENT 47
#endif
#ifndef PR_CAP_AMBIENT_IS_SET
# define PR_CAP_AMBIENT_IS_SET 1
#endif
#ifndef PR_CAP_AMBIENT_RAISE
# define PR_CAP_AMBIENT_RAISE 2
#endif

#ifndef CLONE_NEWCGROUP
# define CLONE_NEWCGROUP 0x02000000
#endif

#ifndef SECCOMP_FILTER_FLAG_SPEC_ALLOW
# define SECCOMP_FILTER_FLAG_SPEC_ALLOW 4
#endif

#ifndef PR_GET_SPECULATION_CTRL
# define PR_GET_SPECULATION_CTRL 52
#endif
#ifndef PR_SET_SPECULATION_CTRL
# define PR_SET_SPECULATION_CTRL 53
#endif
#ifndef PR_SPEC_PRCTL
# define PR_SPEC_PRCTL 1
#endif
#ifndef PR_SPEC_ENABLE
# define PR_SPEC_ENABLE 2
#endif
#ifndef PR_SPEC_DISABLE
# define PR_SPEC_DISABLE 4
#endif
#ifndef PR_SPEC_DISABLE_NOEXEC
# define PR_SPEC_DISABLE_NOEXEC 16
#endif
#ifndef PR_SPEC_STORE_BYPASS
# define PR_SPEC_STORE_BYPASS 0
#endif
#ifndef PR_SPEC_INDIRECT_BRANCH
# define PR_SPEC_INDIRECT_BRANCH 1
#endif
#ifndef PR_SPEC_L1D_FLUSH
# define PR_SPEC_L1D_FLUSH 2
#endif

#ifndef AUDIT_ARCH_AARCH64
#define AUDIT_ARCH_AARCH64 (EM_AARCH64|__AUDIT_ARCH_64BIT|__AUDIT_ARCH_LE)
#endif

static struct sock_filter filter[] = {
        /* Check for the syscall architecture (x86_64 and aarch64 ABIs). */
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, AUDIT_ARCH_X86_64,  3, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, AUDIT_ARCH_AARCH64, 2, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, AUDIT_ARCH_PPC64LE, 1, 0),
        /* FIXME We do not support x86, x32 and aarch32, allow all syscalls for now. */
        BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),

        /* Load the syscall number. */
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, nr)),

        /* Return success on all the following syscalls. */
#if defined(SYS_chown) && defined(SYS_lchown)
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_chown,     15, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_lchown,    14, 0),
#endif
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_setuid,    13, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_setgid,    12, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_setreuid,  11, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_setregid,  10, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_setresuid, 9,  0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_setresgid, 8,  0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_setgroups, 7,  0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_fchownat,  6,  0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_fchown,    5,  0),

        /* For setfsuid/setfsgid we only return success if the uid/gid argument is not -1. */
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_setfsuid, 1, 0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_setfsgid, 0, 2),
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, args[0])),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, (uint32_t)-1, 0, 1),

        /* Execute the syscall as usual. */
        BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        /* Return success. */
        BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_RET_DATA & 0x0)),
};

static void
raise_capabilities(void)
{
        struct capabilities_v3 caps;

        CAP_INIT_V3(&caps);

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

static void
loopback_up(void)
{
        int sock;
        struct ifreq ifr;

        memset(&ifr, 0, sizeof(ifr));
        strncpy(ifr.ifr_name, "lo", IFNAMSIZ - 1);

        if ((sock = socket(AF_INET, SOCK_DGRAM|SOCK_CLOEXEC, 0)) < 0)
                err(EXIT_FAILURE, "failed to create socket");

        if (ioctl(sock, SIOCGIFFLAGS, &ifr) < 0)
                err(EXIT_FAILURE, "failed to get loopback interface flags");
        ifr.ifr_flags |= IFF_UP;
        if (ioctl(sock, SIOCSIFFLAGS, &ifr) < 0)
                err(EXIT_FAILURE, "failed to bring up loopback interface");

        if (close(sock) < 0)
                err(EXIT_FAILURE, "failed to close socket");
}

static void
create_namespaces(bool user, bool mount, bool network, bool remap_root)
{
        if (user) {
                if (!remap_root && prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_IS_SET, 0, 0, 0) < 0 && errno == EINVAL)
                        errx(EXIT_FAILURE, "kernel lacks support for ambient capabilities, consider using --remap-root instead");
                if (unshare_userns(remap_root) < 0)
                        err(EXIT_FAILURE, "failed to create user namespace");
                if (!remap_root)
                        raise_capabilities();
        }
        if (mount) {
                if (unshare(CLONE_NEWNS) < 0)
                        err(EXIT_FAILURE, "failed to create mount namespace");
        }
        if (network) {
                if (unshare(CLONE_NEWNET) < 0)
                        err(EXIT_FAILURE, "failed to create network namespace");
                loopback_up();
        }
}

static int
open_namespace(pid_t pid, const char *nsstr)
{
        char path[PATH_MAX];

        if ((size_t)snprintf(path, sizeof(path), "/proc/%d/ns/%s", pid, nsstr) >= sizeof(path)) {
                errno = ENAMETOOLONG;
                return (-1);
        }
        return open(path, O_RDONLY | O_CLOEXEC);
}

/* Return -1 on error, 0 when already in the target namespace, 1 after setns. */
static int
do_setns(int fd, int nstype, const char *nsstr)
{
        char self_path[64];
        struct stat target_stat, self_stat;

        if (fd < 0)
                return (0);
        if ((size_t)snprintf(self_path, sizeof(self_path), "/proc/self/ns/%s", nsstr) >= sizeof(self_path)) {
                errno = ENAMETOOLONG;
                SAVE_ERRNO(close(fd));
                return (-1);
        }

        /* Skip setns if the target is already in the same namespace as us. */
        if (fstat(fd, &target_stat) < 0)
                goto err;
        if (stat(self_path, &self_stat) < 0)
                goto err;
        if (target_stat.st_dev == self_stat.st_dev && target_stat.st_ino == self_stat.st_ino) {
                (void)close(fd);
                return (0);
        }

        if (setns(fd, nstype) < 0)
                goto err;
        if (close(fd) < 0)
                return (-1);
        return (1);

 err:
        SAVE_ERRNO(close(fd));
        return (-1);
}

static void
join_namespaces(pid_t pid, bool user, bool mount, bool network)
{
        int user_fd = -1, mount_fd = -1, network_fd = -1, cgroup_fd = -1;

        /* Open namespace fds first since joining the mount namespace can change /proc visibility. */
        if (user && (user_fd = open_namespace(pid, "user")) < 0)
                err(EXIT_FAILURE, "failed to open user namespace");
        if (mount && (mount_fd = open_namespace(pid, "mnt")) < 0)
                err(EXIT_FAILURE, "failed to open mount namespace");
        if (network && (network_fd = open_namespace(pid, "net")) < 0)
                err(EXIT_FAILURE, "failed to open network namespace");
        if ((cgroup_fd = open_namespace(pid, "cgroup")) < 0 && errno != ENOENT)
                err(EXIT_FAILURE, "failed to open cgroup namespace");

        if (user) {
                if (do_setns(user_fd, CLONE_NEWUSER, "user") < 0)
                        err(EXIT_FAILURE, "failed to join user namespace");
        }
        if (mount) {
                if (do_setns(mount_fd, CLONE_NEWNS, "mnt") < 0)
                        err(EXIT_FAILURE, "failed to join mount namespace");
        }
        if (network) {
                if (do_setns(network_fd, CLONE_NEWNET, "net") < 0)
                        err(EXIT_FAILURE, "failed to join network namespace");
        }
        if (do_setns(cgroup_fd, CLONE_NEWCGROUP, "cgroup") < 0)
                err(EXIT_FAILURE, "failed to join cgroup namespace");
}

MAYBE_UNUSED static int
disable_mitigation(int spec)
{
        switch (prctl(PR_GET_SPECULATION_CTRL, spec, 0, 0, 0)) {
        case PR_SPEC_PRCTL|PR_SPEC_DISABLE:
        case PR_SPEC_PRCTL|PR_SPEC_DISABLE_NOEXEC:
                if (prctl(PR_SET_SPECULATION_CTRL, spec, PR_SPEC_ENABLE, 0, 0) < 0)
                        return (-1);
                break;
        case -1:
                if (errno != EINVAL && errno != ENODEV)
                        return (-1);
                break;
        }
        return (0);
}

static int
seccomp_set_filter(void)
{
#ifdef ALLOW_SPECULATION
        if ((int)syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_SPEC_ALLOW, &(const struct sock_fprog){ARRAY_SIZE(filter), filter}) == 0)
                return (0);
        else if (errno != EINVAL)
                return (-1);
#endif
        return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &(const struct sock_fprog){ARRAY_SIZE(filter), filter});
}

int
main(int argc, char *argv[])
{
        bool user = false, mount = false, network = false, remap_root = false;
        char *envfile = NULL, *workdir = NULL;
        pid_t target = -1;
        int e;

        for (;;) {
                if (argc >= 3 && !strcmp(argv[1], "--target")) {
                        target = (int)strtoi(argv[2], NULL, 10, 1, INT_MAX, &e);
                        if (e != 0)
                                errx(EXIT_FAILURE, "invalid argument: %s", argv[2]);
                        SHIFT_ARGS(2);
                        continue;
                }
                if (argc >= 3 && !strcmp(argv[1], "--envfile")) {
                        envfile = argv[2];
                        SHIFT_ARGS(2);
                        continue;
                }
                if (argc >= 3 && !strcmp(argv[1], "--workdir")) {
                        workdir = argv[2];
                        SHIFT_ARGS(2);
                        continue;
                }
                if (argc >= 2 && !strcmp(argv[1], "--user")) {
                        user = true;
                        SHIFT_ARGS(1);
                        continue;
                }
                if (argc >= 2 && !strcmp(argv[1], "--mount")) {
                        mount = true;
                        SHIFT_ARGS(1);
                        continue;
                }
                if (argc >= 2 && !strcmp(argv[1], "--net")) {
                        network = true;
                        SHIFT_ARGS(1);
                        continue;
                }
                if (argc >= 2 && !strcmp(argv[1], "--remap-root")) {
                        remap_root = true;
                        SHIFT_ARGS(1);
                        continue;
                }
                break;
        }
        if (argc < 2) {
                printf("Usage: %s [--target PID] [--user] [--mount] [--net] [--remap-root] [--envfile FILE] [--workdir DIR] COMMAND [ARG...]\n", argv[0]);
                return (0);
        }

        if (target < 0)
                create_namespaces(user, mount, network, remap_root);
        else
                join_namespaces(target, user, mount, network);

        if (user) {
                if (seccomp_set_filter() < 0)
                        err(EXIT_FAILURE, "failed to register seccomp filter");
        }
        if (envfile != NULL) {
                if (load_environment(envfile) < 0)
                        err(EXIT_FAILURE, "failed to load environment: %s", envfile);
        }
        if (workdir != NULL) {
                if (chdir(workdir) < 0)
                        err(EXIT_FAILURE, "failed to change directory: %s", workdir);
        }

#ifdef ALLOW_SPECULATION
        if (disable_mitigation(PR_SPEC_STORE_BYPASS) < 0)
                err(EXIT_FAILURE, "failed to disable SSBD mitigation");
        if (disable_mitigation(PR_SPEC_INDIRECT_BRANCH) < 0)
                err(EXIT_FAILURE, "failed to disable IBPB/STIBP mitigation");
        if (disable_mitigation(PR_SPEC_L1D_FLUSH) < 0)
                err(EXIT_FAILURE, "failed to disable L1TF mitigation");
#endif
#ifndef INHERIT_FDS
        closefrom(STDERR_FILENO + 1);
#endif

        if (execvp(argv[1], &argv[1]) < 0)
                err(EXIT_FAILURE, "failed to execute: %s", argv[1]);
        return (0);
}
