/*
 * Copyright (c) 2018-2019, NVIDIA CORPORATION. All rights reserved.
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

#define _GNU_SOURCE
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <inttypes.h>
#include <limits.h>
#include <linux/securebits.h>
#include <paths.h>
#include <pwd.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/queue.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <utmp.h>

#include "common.h"
#include "compat.h"

#ifndef CLONE_NEWCGROUP
# define CLONE_NEWCGROUP 0x02000000
#endif

#ifndef PATH_SHELL
# define PATH_SHELL _PATH_BSHELL
#endif

#ifndef PATH_LOGIN_DEFS
# define PATH_LOGIN_DEFS "/etc/login.defs"
#endif
#ifndef PATH_LOCALE_CONF
# define PATH_LOCALE_CONF "/etc/locale.conf"
#endif
#ifndef PATH_RC_SCRIPT
# define PATH_RC_SCRIPT "/etc/rc"
#endif

SLIST_HEAD(config, param);

struct param {
        char *name, *value;
        SLIST_ENTRY(param) params;
};

static int
map_file(const char *file, int prot, void **buf, size_t *len)
{
        int fd;
        struct stat s;
        void *anon;

        *buf = NULL;
        *len = 0;

        if ((fd = open(file, O_RDONLY)) < 0)
                goto err;
        if (fstat(fd, &s) < 0)
                goto err;
        *len = (size_t)s.st_size;

        if (*len > 0) {
                anon = mmap(NULL, *len + 1, PROT_READ, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
                if (anon == MAP_FAILED)
                        goto err;
                *buf = mmap(anon, *len, prot, MAP_PRIVATE|MAP_FIXED, fd, 0);
                if (*buf == MAP_FAILED) {
                        SAVE_ERRNO(munmap(anon, *len + 1));
                        goto err;
                }
                *len += 1;
        }
        if (close(fd) < 0) {
                if (*buf != MAP_FAILED && *len > 0)
                        SAVE_ERRNO(munmap(*buf, *len));
                goto err;
        }
        return (0);

 err:
        SAVE_ERRNO(close(fd));
        return (-1);
}

static int
map_fd(void *buf, size_t len)
{
        int fd;
        char name[] = "XXXXXX";
        ssize_t n;

        if (strnull(mktemp(name)))
                return (-1);
        if ((fd = memfd_create(name, 0)) < 0)
                return (-1);
        if (buf == NULL || len == 0)
                return (fd);
        n = write(fd, buf, len);
        if (n < 0 || (size_t)n != len) {
                SAVE_ERRNO(close(fd));
                if (n >= 0)
                        errno = EIO;
                return (-1);
        }
        return (fd);
}

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
read_uid_map(uid_t *euid, uid_t *muid)
{
        FILE *fs;

        if ((fs = fopen("/proc/self/uid_map", "r")) == NULL)
                return (-1);
        if (fscanf(fs, "%"PRIu32" %"PRIu32" %*"PRIu32, euid, muid) != 2) {
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
        if (mount(NULL, ".", NULL, MS_REC|MS_SLAVE, NULL) < 0)
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

static void
free_config(struct config *conf)
{
        struct param *p;

        while (!SLIST_EMPTY(conf)) {
                p = SLIST_FIRST(conf);
                SLIST_REMOVE_HEAD(conf, params);
                free(p->name);
                free(p->value);
                free(p);
        }
}

static int
load_config(struct config *conf, const char *path)
{
        FILE *fp;
        char *buf, *name, *value;
        struct param *p;

        if ((fp = fopen(path, "r")) == NULL)
                return (errno == ENOENT ? 0 : -1);

        for (; (buf = fparseln(fp, NULL, NULL, NULL, FPARSELN_UNESCALL)) != NULL; free(buf)) {
                /* Remove leading whitespaces. */
                name = buf + strspn(buf, " \t");
                if (*name == '\0' || *name == '#')
                        continue;
                /* Look for a delimiter. */
                value = name + strcspn(name, " \t=");
                if (*value == '\0')
                        continue;
                *value++ = '\0';
                /* Remove leading and trailing delimiters. */
                value += strspn(value, " \t\"=");
                value[strcspn(value, " \t\"")] = '\0';
                if (*value == '\0')
                        continue;

                if ((p = calloc(1, sizeof(struct param))) == NULL)
                        goto err;
                SLIST_INSERT_HEAD(conf, p, params);
                if ((p->name = strdup(name)) == NULL || (p->value = strdup(value)) == NULL)
                        goto err;
        }
        if (feof(fp) && fclose(fp) == 0)
                return (0);

 err:
        free(buf);
        free_config(conf);
        SAVE_ERRNO(fclose(fp));
        return (-1);
}

static const char *
get_param(struct config *conf, const char *name)
{
        struct param *p;

        SLIST_FOREACH(p, conf, params) {
                if (!strcmp(name, p->name))
                        return (p->value);
        }
        return (NULL);
}

static bool
has_param(struct config *conf, const char *name)
{
        const char *str;

        str = get_param(conf, name);
        return (str != NULL && (!strcasecmp(str, "true") || !strcasecmp(str, "yes")));
}

static int
print_file(const char *file)
{
        FILE *fs;
        int c;

        if ((fs = fopen(file, "r")) == NULL)
                return (-1);
        while ((c = getc(fs)) != EOF)
                putchar (c);
        fclose(fs);
        fflush(stdout);
        return (0);
}

static int
print_motd(const char *motd, const char *hushlogin)
{
        char *buf, *ptr, *file;

        if (strnull(motd))
                return (0);
        if (!strnull(hushlogin)) {
                /* TODO If the path is absolute we need to check for the user/shell. */
                if (!access(hushlogin, F_OK))
                        return (0);
        }
        if ((buf = ptr = strdup(motd)) == NULL)
                return (-1);
        while ((file = strsep(&ptr, ":")) != NULL) {
                if (*file == '\0')
                        continue;
                print_file(file);
        }
        free(buf);
        return (0);
}

static int
set_mailbox(const char *dir, const char *file)
{
        char path[PATH_MAX];

        if (strnull(dir) || strnull(file))
                return (0);
        if ((size_t)snprintf(path, sizeof(path), "%s/%s", dir, file) >= sizeof(path)) {
                errno = ENAMETOOLONG;
                return (-1);
        }
        if (setenv("MAIL", path, 0) < 0)
                return (-1);
        return (0);
}

static int
set_timezone(const char *tz)
{
        FILE *fs;
        char *ptr, *buf = NULL;
        size_t n = 0;
        int rv = -1;

        if (strnull(tz))
                return (0);
        if (*tz == '/') {
                if ((fs = fopen(tz, "r")) == NULL)
                        return (errno == ENOENT ? 0 : -1);
                if (getline(&buf, &n, fs) < 0 && !feof(fs)) {
                        SAVE_ERRNO(fclose(fs));
                        goto err;
                }
                if (fclose(fs) < 0)
                        goto err;
                buf[strcspn(buf, "\n")] = '\0';
        } else {
                if ((buf = strdup(tz)) == NULL)
                        goto err;
        }
        ptr = strtrim(buf, "TZ=");
        if (!strnull(ptr) && setenv("TZ", ptr, 0) < 0)
                goto err;
        rv = 0;

 err:
        free(buf);
        return (rv);
}

static int
set_locale(void)
{
        struct config conf = SLIST_HEAD_INITIALIZER(conf);
        struct param *p;
        const char *vars[] = {
                "LANG",
                "LANGUAGE",
                "LC_CTYPE",
                "LC_NUMERIC",
                "LC_TIME",
                "LC_COLLATE",
                "LC_MONETARY",
                "LC_MESSAGES",
                "LC_PAPER",
                "LC_NAME",
                "LC_ADDRESS",
                "LC_TELEPHONE",
                "LC_MEASUREMENT",
                "LC_IDENTIFICATION",
        };

        if (load_config(&conf, PATH_LOCALE_CONF) < 0)
                return (-1);
        SLIST_FOREACH(p, &conf, params) {
                for (size_t i = 0; i < ARRAY_SIZE(vars); ++i) {
                        if (strcmp(vars[i], p->name))
                                continue;
                        if (setenv(p->name, p->value, 0) < 0) {
                                free_config(&conf);
                                return (-1);
                        }
                        break;
                }
        }
        free_config(&conf);
        return (0);
}

static int
set_umask(const char *mask, const struct passwd *pw)
{
        int e;
        mode_t m;
        struct group *gr;

        if (!strnull(mask)) {
                m = (mode_t)strtou(mask, NULL, 0, 0, (mode_t)-1, &e);
                if (e != 0) {
                        errno = e;
                        return (-1);
                }
                umask(m);
        }
        if (pw != NULL) {
                if (pw->pw_uid == 0 || pw->pw_uid != pw->pw_gid)
                        return (0);
                if ((gr = getgrgid(pw->pw_gid)) == NULL)
                        return (-1);
                if (!strcmp(pw->pw_name, gr->gr_name)) {
                        m = umask(0777);
                        m = (m & ~070u) | ((m >> 3) & 070u);
                        umask(m);
                }
        }
        return (0);
}

static int
set_ulimit(const char *blocks)
{
        int e;
        rlim_t l;

        if (strnull(blocks))
                return (0);
        if (!strcmp(blocks, "-1"))
                l = RLIM_INFINITY;
        else {
                l = (rlim_t)strtou(blocks, NULL, 10, 0, (rlim_t)-1 / 512, &e) * 512;
                if (e != 0) {
                        errno = e;
                        return (-1);
                }
        }
        if (setrlimit(RLIMIT_FSIZE, &(struct rlimit){l, l}) < 0)
                return (-1);
        return (0);
}

static int
set_lastlog(uid_t uid)
{
        int fd;
        struct compat_lastlog log;
        time_t t;
        char buf[PATH_MAX - TTY_NAME_MAX];
        char *ptr = buf;
        int rv = -1;

        if ((fd = open(_PATH_LASTLOG, O_RDWR|O_CREAT, 0664)) < 0)
                return (-1);
        if (pread(fd, &log, sizeof(log), (off_t)(uid * sizeof(log))) != sizeof(log))
                memset(&log, 0, sizeof(log));

        if (time(&t) == (time_t)-1)
                goto err;
        log.ll_time = (__typeof__(log.ll_time))t;

        if (isatty(STDIN_FILENO)) {
                if (ttyname_r(STDIN_FILENO, buf, sizeof(buf)) != 0)
                        goto err;
                ptr = strtrim(ptr, "/dev/");
                if (strlcpy(log.ll_line, ptr, sizeof(log.ll_line)) >= sizeof(log.ll_line)) {
                        errno = ENAMETOOLONG;
                        goto err;
                }
        }

        if (strlcpy(log.ll_host, "localhost", sizeof(log.ll_host)) >= sizeof(log.ll_host)) {
                errno = ENAMETOOLONG;
                goto err;
        }

        if (pwrite(fd, &log, sizeof(log), (off_t)(uid * sizeof(log))) != sizeof(log)) {
                errno = EIO;
                goto err;
        }
        rv = 0;
 err:
        close(fd);
        return (rv);
}

static int
set_utmp(const char *user)
{
        struct utmp ut = {.ut_type = USER_PROCESS};
        char buf[PATH_MAX - TTY_NAME_MAX];
        char *ptr = buf;
        struct timeval tv;

        ut.ut_pid = getpid();

        if (isatty(STDIN_FILENO)) {
                if (ttyname_r(STDIN_FILENO, buf, sizeof(buf)) != 0)
                        return (-1);
                ptr = strtrim(ptr, "/dev/");
                if (strlcpy(ut.ut_line, ptr, sizeof(ut.ut_line)) >= sizeof(ut.ut_line))
                        goto err_toolong;
                if ((ptr = strstr(buf, "tty")) != NULL || (ptr = strstr(buf, "pts")) != NULL) {
                        ptr += (ptr[3] == '/') ? 4 : 3;
                        if (strlcpy(ut.ut_id, ptr, sizeof(ut.ut_id)) >= sizeof(ut.ut_id))
                                goto err_toolong;
                }
        }

        if (!strnull(user)) {
                if (strlcpy(ut.ut_user, user, sizeof(ut.ut_user)) >= sizeof(ut.ut_user))
                        goto err_toolong;
        }

        if (gettimeofday(&tv, NULL) < 0)
                return (-1);
        ut.ut_tv.tv_sec = (__typeof__(ut.ut_tv.tv_sec))tv.tv_sec;
        ut.ut_tv.tv_usec = (__typeof__(ut.ut_tv.tv_usec))tv.tv_usec;

        if (utmpname(_PATH_UTMP) == 0) {
                setutent();
                pututline(&ut);
                endutent();
        }
        updwtmp(_PATH_WTMP, &ut);
        return (0);

 err_toolong:
        errno = ENAMETOOLONG;
        return (-1);
}

static int
sys_login(char **fakeshell, char **hushlogin, char **motd)
{
        struct config conf = SLIST_HEAD_INITIALIZER(conf);
        uid_t euid, muid;
        struct passwd *pw;
        char *logname = NULL;
        const char *ptr;

        if (read_uid_map(&euid, &muid) < 0)
                return (-1);
        if (load_config(&conf, PATH_LOGIN_DEFS) < 0)
                return (-1);

        if (euid != 0) {
                if ((ptr = get_param(&conf, "NOLOGINS_FILE")) == NULL)
                        ptr = _PATH_NOLOGIN;
                if (!access(ptr, F_OK)) {
                        if (print_file(ptr) < 0)
                                warndbg("failed to read: %s", ptr);
                        exit(EXIT_SUCCESS);
                }
        }

        if ((pw = getpwuid(muid)) != NULL)
                logname = strdup(pw->pw_name);
        if ((pw = getpwuid(euid)) == NULL)
                warndbg("failed to read shadow database");

        setenv("TERM", "dumb", 0);
        if (pw != NULL && !strnull(pw->pw_dir))
                setenv("HOME", pw->pw_dir, 0);
        if (pw != NULL && !strnull(pw->pw_shell))
                setenv("SHELL", pw->pw_shell, 0);
        if (pw != NULL && !strnull(pw->pw_name))
                setenv("USER", pw->pw_name, 0);
        if (!strnull(logname))
                setenv("LOGNAME", logname, 0);

        if ((ptr = get_param(&conf, euid == 0 ? "ENV_SUPATH" : "ENV_PATH")) != NULL)
                ptr = strtrim(ptr, "PATH=");
        if (strnull(ptr))
                ptr = (euid == 0) ? _PATH_STDPATH : _PATH_DEFPATH;
        setenv("PATH", ptr, 0);

        if (has_param(&conf, "MAIL_CHECK_ENAB")) {
                if ((set_mailbox(get_param(&conf, "MAIL_DIR"), getenv("USER"))  |
                     set_mailbox(getenv("HOME"), get_param(&conf, "MAIL_FILE")) |
                     set_mailbox(_PATH_MAILDIR, getenv("USER"))) < 0)
                        warndbg("failed to set mailbox");
        }
        if (set_timezone(get_param(&conf, "ENV_TZ")) < 0)
                warndbg("failed to set timezone");
        if (set_locale() < 0)
                warndbg("failed to set locale");

        if (has_param(&conf, "USERGROUPS_ENAB")) {
                if (set_umask(get_param(&conf, "UMASK"), pw) < 0)
                        warndbg("failed to set umask");
        } else {
                if (set_umask(get_param(&conf, "UMASK"), NULL) < 0)
                        warndbg("failed to set umask");
        }
        if (set_ulimit(get_param(&conf, "ULIMIT")) < 0)
                warndbg("failed to set ulimit");

        if (has_param(&conf, "LASTLOG_ENAB")) {
                if (set_lastlog(muid) < 0)
                        warndbg("failed to record last login");
        }
        if (set_utmp(logname) < 0)
                warndbg("failed to record utmp login");

        ptr = getenv("HOME");
        if (!strnull(ptr) && chdir(ptr) < 0) {
                if (has_param(&conf, "DEFAULT_HOME"))
                        warn("failed to change directory: %s", ptr);
                else
                        err(EXIT_FAILURE, "failed to change directory: %s", ptr);
        }

        *fakeshell = ((ptr = get_param(&conf, "FAKE_SHELL")) != NULL) ? strdup(ptr) : NULL;
        *hushlogin = ((ptr = get_param(&conf, "HUSHLOGIN_FILE")) != NULL) ? strdup(ptr) : NULL;
        *motd = ((ptr = get_param(&conf, "MOTD_FILE")) != NULL) ? strdup(ptr) : NULL;

        free(logname);
        free_config(&conf);
        return (0);
}

static void NORETURN
sys_init(int argc, char *argv[], const char *rcfile, bool norc, bool login)
{
        char *fakeshell = NULL, *hushlogin = NULL, *motd = NULL, *arg0;
        const char *shell, *rc;
        char **cmd, **ptr;

        /* TODO Add support for ISSUE_FILE and ENVIRON_FILE. */
        if (login) {
                if (sys_login(&fakeshell, &hushlogin, &motd) < 0)
                        warndbg("failed to run login");
        }

        if (!strnull(fakeshell) && !access(fakeshell, R_OK|X_OK))
                shell = fakeshell;
        else {
                shell = getenv("SHELL");
                if (strnull(shell) || access(shell, R_OK|X_OK))
                        shell = PATH_SHELL;
        }
        if ((arg0 = strdup(shell)) == NULL)
                err(EXIT_FAILURE, "failed to allocate memory");

        arg0 = basename(arg0);
        rc = (rcfile != NULL) ? rcfile : PATH_RC_SCRIPT;

        if ((cmd = ptr = calloc(3 + (size_t)argc + 1, sizeof(char *))) == NULL)
                err(EXIT_FAILURE, "failed to allocate memory");
        if (asprintf(ptr++, "%s%s", login ? "-" : "", arg0) < 0)
                err(EXIT_FAILURE, "failed to allocate memory");

        if (!norc && !access(rc, F_OK))
                *ptr++ = (char *)rc;
        else if (argc > 1) {
                if (strchr(argv[1], ' ') != NULL) {
                        *ptr++ = (char *)"-c";
                        *ptr++ = argv[1];
                        *ptr++ = arg0;
                        SHIFT_ARGS(1);
                } else if (access(argv[1], F_OK) || !access(argv[1], R_OK|X_OK)) {
                        *ptr++ = (char *)"-c";
                        *ptr++ = (char *)"exec \"$@\"";
                        *ptr++ = arg0;
                }
                /* else, assume argv[1] is a shell script. */
        } else
                print_motd(motd, hushlogin);

        free(hushlogin);
        free(motd);

        memcpy(ptr, argv + 1, (size_t)(argc - 1) * sizeof(char *));
        execv(shell, cmd);
        err(EXIT_FAILURE, "failed to execute: %s", shell);
}

int
main(int argc, char *argv[])
{
        size_t len = 0;
        void *buf = MAP_FAILED;
        char *rcfile = NULL, *envfile = NULL;
        bool norc = false, login = false;
        uint32_t lastcap;
        int fd;

        for (;;) {
                if (argc >= 2 && !strcmp(argv[1], "--norc")) {
                        norc = true;
                        SHIFT_ARGS(1);
                        continue;
                }
                if (argc >= 2 && !strcmp(argv[1], "--login")) {
                        login = true;
                        SHIFT_ARGS(1);
                        continue;
                }
                if (argc >= 3 && !strcmp(argv[1], "--rcfile")) {
                        rcfile = argv[2];
                        SHIFT_ARGS(2);
                        continue;
                }
                if (argc >= 3 && !strcmp(argv[1], "--envfile")) {
                        envfile = argv[2];
                        SHIFT_ARGS(2);
                        continue;
                }
                break;
        }
        if (argc < 2) {
                printf("Usage: %s [--norc] [--login] [--rcfile FILE] [--envfile FILE] ROOTFS [COMMAND] [ARG...]\n", argv[0]);
                return (0);
        }

        if (rcfile != NULL) {
                if (map_file(rcfile, PROT_READ, &buf, &len) < 0)
                        err(EXIT_FAILURE, "failed to read file: %s", rcfile);
        }
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
#ifndef INHERIT_FDS
        closefrom(STDERR_FILENO + 1);
#endif

        if (rcfile != NULL) {
                if ((fd = map_fd(buf, len)) < 0)
                        err(EXIT_FAILURE, "failed to copy file: %s", rcfile);
                if (buf != MAP_FAILED && len > 0)
                        munmap(buf, len);
                if (asprintf(&rcfile, "/proc/self/fd/%d", fd) < 0)
                        err(EXIT_FAILURE, "failed to allocate memory");
        }

        SHIFT_ARGS(1);
        sys_init(argc, argv, rcfile, norc, login);
        return (0);
}
