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
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
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
#ifndef SYS_pidfd_open
# ifdef __NR_pidfd_open
#  define SYS_pidfd_open __NR_pidfd_open
# else
#  define SYS_pidfd_open 434
# endif
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

static volatile sig_atomic_t child_pid;

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
forward_signal(int sig)
{
        if (child_pid > 0)
                (void)kill((pid_t)child_pid, sig);
}

static int
pidfd_open(pid_t pid)
{
        return ((int)syscall(SYS_pidfd_open, pid, 0));
}

static void
wait_child(pid_t pid)
{
        sigset_t sigset;
        int status, sig;
        pid_t ret;

        for (;;) {
                do {
                        ret = waitpid(pid, &status, WUNTRACED);
                } while (ret < 0 && errno == EINTR);

                if (ret < 0)
                        err(EXIT_FAILURE, "failed to wait for child process");
                if (!WIFSTOPPED(status))
                        break;

                (void)kill(getpid(), SIGSTOP);
                (void)kill(pid, SIGCONT);
        }

        if (WIFEXITED(status))
                exit(WEXITSTATUS(status));
        if (WIFSIGNALED(status)) {
                sig = WTERMSIG(status);
                if (sig != SIGKILL && signal(sig, SIG_DFL) == SIG_ERR)
                        err(EXIT_FAILURE, "failed to reset signal handler");
                if (sigemptyset(&sigset) < 0)
                        err(EXIT_FAILURE, "failed to initialize signal mask");
                if (sigaddset(&sigset, sig) < 0)
                        err(EXIT_FAILURE, "failed to update signal mask");
                if (sigprocmask(SIG_UNBLOCK, &sigset, NULL) < 0)
                        err(EXIT_FAILURE, "failed to unblock signal");
                (void)kill(getpid(), sig);
                exit(128 + sig);
        }
        errx(EXIT_FAILURE, "child process terminated unexpectedly");
}

static void
fork_child(void)
{
        char buf[32];
        sigset_t oldsigset;
        struct sigaction sa;
        struct pollfd pfd;
        ssize_t n;
        size_t len;
        int fds[2], parentfd;
        pid_t pid;

        if (pipe(fds) < 0)
                err(EXIT_FAILURE, "failed to create pipe");
        if ((parentfd = pidfd_open(getpid())) < 0)
                err(EXIT_FAILURE, "failed to open pidfd");

        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = forward_signal;
        sa.sa_flags = SA_RESTART;
        if (sigemptyset(&sa.sa_mask) < 0)
                err(EXIT_FAILURE, "failed to initialize signal mask");
        if (sigaction(SIGTERM, &sa, NULL) < 0)
                err(EXIT_FAILURE, "failed to set signal handler");
        if (sigaction(SIGINT, &sa, NULL) < 0)
                err(EXIT_FAILURE, "failed to set signal handler");
        if (sigprocmask(SIG_SETMASK, NULL, &oldsigset) < 0)
                err(EXIT_FAILURE, "failed to get signal mask");

        switch ((pid = fork())) {
        case -1:
                err(EXIT_FAILURE, "failed to fork");
        case 0:
                child_pid = 0;
                if (sigprocmask(SIG_SETMASK, &oldsigset, NULL) < 0)
                        err(EXIT_FAILURE, "failed to restore signal mask");
                if (prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) < 0)
                        err(EXIT_FAILURE, "failed to set parent death signal");
                pfd = (struct pollfd){.fd = parentfd, .events = POLLIN};
                switch (poll(&pfd, 1, 0)) {
                case -1:
                        err(EXIT_FAILURE, "failed to poll pidfd");
                case 0:
                        break;
                default:
                        exit(EXIT_FAILURE);
                }
                if (close(parentfd) < 0)
                        err(EXIT_FAILURE, "failed to close pidfd");
                if (close(fds[1]) < 0)
                        err(EXIT_FAILURE, "failed to close pipe");
                if ((n = read(fds[0], buf, sizeof(buf) - 1)) < 0)
                        err(EXIT_FAILURE, "failed to read pipe");
                buf[n] = '\0';
                if (n > 0 && setenv("ENROOT_NSENTER_PID", buf, 1) < 0)
                        err(EXIT_FAILURE, "failed to set environment");
                if (close(fds[0]) < 0)
                        err(EXIT_FAILURE, "failed to close pipe");
                return;
        default:
                child_pid = pid;
                if (close(parentfd) < 0)
                        err(EXIT_FAILURE, "failed to close pidfd");
                if (close(fds[0]) < 0)
                        err(EXIT_FAILURE, "failed to close pipe");
                len = (size_t)snprintf(buf, sizeof(buf), "%jd", (intmax_t)pid);
                if (len >= sizeof(buf)) {
                        errno = EOVERFLOW;
                        err(EXIT_FAILURE, "failed to format child PID");
                }
                n = write(fds[1], buf, len);
                if (n < 0 || (size_t)n != len) {
                        if (n >= 0)
                                errno = EIO;
                        err(EXIT_FAILURE, "failed to write pipe");
                }
                if (close(fds[1]) < 0)
                        err(EXIT_FAILURE, "failed to close pipe");
                wait_child(pid);
        }
}

static void
create_namespaces(bool user, bool pid, bool mountns, bool network, bool ipc, bool uts, bool remap_root)
{
        if (user) {
                if (!remap_root && prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_IS_SET, 0, 0, 0) < 0 && errno == EINVAL)
                        errx(EXIT_FAILURE, "kernel lacks support for ambient capabilities, consider using --remap-root instead");
                if (unshare_userns(remap_root) < 0)
                        err(EXIT_FAILURE, "failed to create user namespace");
                if (!remap_root)
                        raise_capabilities();
        }
        if (pid) {
                if (unshare(CLONE_NEWPID) < 0)
                        err(EXIT_FAILURE, "failed to create PID namespace");
                fork_child();
        }
        if (mountns) {
                if (unshare(CLONE_NEWNS) < 0)
                        err(EXIT_FAILURE, "failed to create mount namespace");
                /* Prevent privileged mounts from propagating back to the parent namespace. */
                if (!user && mount(NULL, "/", NULL, MS_REC|MS_SLAVE, NULL) < 0)
                        err(EXIT_FAILURE, "failed to set mount propagation");
        }
        if (network) {
                if (unshare(CLONE_NEWNET) < 0)
                        err(EXIT_FAILURE, "failed to create network namespace");
                loopback_up();
        }
        if (ipc) {
                if (unshare(CLONE_NEWIPC) < 0)
                        err(EXIT_FAILURE, "failed to create IPC namespace");
        }
        if (uts) {
                if (unshare(CLONE_NEWUTS) < 0)
                        err(EXIT_FAILURE, "failed to create UTS namespace");
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
join_namespaces(pid_t pid, bool user, bool pidns, bool mount, bool network, bool ipc, bool uts)
{
        int user_fd = -1, pid_fd = -1, mount_fd = -1, network_fd = -1;
        int ipc_fd = -1, uts_fd = -1, cgroup_fd = -1;

        /* Open namespace fds first since joining the mount namespace can change /proc visibility. */
        if (user && (user_fd = open_namespace(pid, "user")) < 0)
                err(EXIT_FAILURE, "failed to open user namespace");
        if (pidns && (pid_fd = open_namespace(pid, "pid")) < 0)
                err(EXIT_FAILURE, "failed to open PID namespace");
        if (mount && (mount_fd = open_namespace(pid, "mnt")) < 0)
                err(EXIT_FAILURE, "failed to open mount namespace");
        if (network && (network_fd = open_namespace(pid, "net")) < 0)
                err(EXIT_FAILURE, "failed to open network namespace");
        if (ipc && (ipc_fd = open_namespace(pid, "ipc")) < 0)
                err(EXIT_FAILURE, "failed to open IPC namespace");
        if (uts && (uts_fd = open_namespace(pid, "uts")) < 0)
                err(EXIT_FAILURE, "failed to open UTS namespace");
        if ((cgroup_fd = open_namespace(pid, "cgroup")) < 0 && errno != ENOENT)
                err(EXIT_FAILURE, "failed to open cgroup namespace");

        if (user) {
                if (do_setns(user_fd, CLONE_NEWUSER, "user") < 0)
                        err(EXIT_FAILURE, "failed to join user namespace");
        }
        if (pidns) {
                switch (do_setns(pid_fd, CLONE_NEWPID, "pid")) {
                case -1:
                        err(EXIT_FAILURE, "failed to join PID namespace");
                case 1:
                        fork_child();
                        break;
                }
        }
        if (mount) {
                if (do_setns(mount_fd, CLONE_NEWNS, "mnt") < 0)
                        err(EXIT_FAILURE, "failed to join mount namespace");
        }
        if (network) {
                if (do_setns(network_fd, CLONE_NEWNET, "net") < 0)
                        err(EXIT_FAILURE, "failed to join network namespace");
        }
        if (ipc) {
                if (do_setns(ipc_fd, CLONE_NEWIPC, "ipc") < 0)
                        err(EXIT_FAILURE, "failed to join IPC namespace");
        }
        if (uts) {
                if (do_setns(uts_fd, CLONE_NEWUTS, "uts") < 0)
                        err(EXIT_FAILURE, "failed to join UTS namespace");
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
        bool user = false, pid = false, mount = false, network = false, ipc = false, uts = false, remap_root = false;
        char *envfile = NULL, *workdir = NULL;
        pid_t target = -1;
        int e, workdir_fd = -1, envfd = -1;

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
                if (argc >= 3 && !strcmp(argv[1], "--envfd")) {
                        envfd = (int)strtoi(argv[2], NULL, 10, STDERR_FILENO + 1, INT_MAX, &e);
                        if (e != 0)
                                errx(EXIT_FAILURE, "invalid argument: %s", argv[2]);
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
                if (argc >= 2 && !strcmp(argv[1], "--pid")) {
                        pid = true;
                        SHIFT_ARGS(1);
                        continue;
                }
                if (argc >= 2 && !strcmp(argv[1], "--net")) {
                        network = true;
                        SHIFT_ARGS(1);
                        continue;
                }
                if (argc >= 2 && !strcmp(argv[1], "--ipc")) {
                        ipc = true;
                        SHIFT_ARGS(1);
                        continue;
                }
                if (argc >= 2 && !strcmp(argv[1], "--uts")) {
                        uts = true;
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
                printf("Usage: %s [--target PID] [--user] [--mount] [--pid] [--net] [--ipc] [--uts] [--remap-root] [--envfile FILE] [--envfd FD] [--workdir DIR] COMMAND [ARG...]\n", argv[0]);
                return (0);
        }
        if (workdir != NULL && target >= 0 && pid) {
                workdir_fd = open(workdir, O_PATH|O_DIRECTORY|O_CLOEXEC);
                if (workdir_fd < 0)
                        err(EXIT_FAILURE, "failed to open directory: %s", workdir);
        }

        if (target < 0)
                create_namespaces(user, pid, mount, network, ipc, uts, remap_root);
        else
                join_namespaces(target, user, pid, mount, network, ipc, uts);

        if (user) {
                if (seccomp_set_filter() < 0)
                        err(EXIT_FAILURE, "failed to register seccomp filter");
        }
        if (envfd >= 0) {
                if (load_environment_fd(envfd) < 0)
                        err(EXIT_FAILURE, "failed to load environment");
        } else if (envfile != NULL) {
                if (load_environment(envfile) < 0)
                        err(EXIT_FAILURE, "failed to load environment: %s", envfile);
        }
        if (workdir != NULL) {
                if ((workdir_fd >= 0 ? fchdir(workdir_fd) : chdir(workdir)) < 0)
                        err(EXIT_FAILURE, "failed to change directory: %s", workdir);
                if (workdir_fd >= 0 && close(workdir_fd) < 0)
                        err(EXIT_FAILURE, "failed to close directory: %s", workdir);
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
