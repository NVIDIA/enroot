/*
 * Copyright (c) 2018-2023, NVIDIA CORPORATION. All rights reserved.
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
#include <inttypes.h>
#include <libgen.h>
#include <limits.h>
#include <mntent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <unistd.h>

#include "common.h"
#include "compat.h"

#ifndef FSTAB_LINE_MAX
# define FSTAB_LINE_MAX 4096
#endif

#define MS_PROPAGATION (unsigned long)(MS_PRIVATE|MS_SHARED|MS_SLAVE|MS_UNBINDABLE)

struct mount_opt {
        const char *name;
        unsigned long flag;
        int clear;
};

static struct capabilities_v3 caps;

static const struct mount_opt mount_opts[] = {
        {"async",         MS_SYNCHRONOUS, 1},
        {"atime",         MS_NOATIME, 1},
        {"bind",          MS_BIND, 0},
        {"dev",           MS_NODEV, 1},
        {"diratime",      MS_NODIRATIME, 1},
        {"dirsync",       MS_DIRSYNC, 0},
        {"exec",          MS_NOEXEC, 1},
        {"iversion",      MS_I_VERSION, 0},
        {"loud",          MS_SILENT, 1},
        {"mand",          MS_MANDLOCK, 0},
        {"noatime",       MS_NOATIME, 0},
        {"nodev",         MS_NODEV, 0},
        {"nodiratime",    MS_NODIRATIME, 0},
        {"noexec",        MS_NOEXEC, 0},
        {"noiversion",    MS_I_VERSION, 1},
        {"nomand",        MS_MANDLOCK, 1},
        {"norelatime",    MS_RELATIME, 1},
        {"nostrictatime", MS_STRICTATIME, 1},
        {"nosuid",        MS_NOSUID, 0},
        {"private",       MS_PRIVATE, 0},
        {"rbind",         MS_BIND|MS_REC, 0},
        {"relatime",      MS_RELATIME, 0},
        {"remount",       MS_REMOUNT, 0},
        {"ro",            MS_RDONLY, 0},
        {"rprivate",      MS_PRIVATE|MS_REC, 0},
        {"rshared",       MS_SHARED|MS_REC, 0},
        {"rslave",        MS_SLAVE|MS_REC, 0},
        {"runbindable",   MS_UNBINDABLE|MS_REC, 0},
        {"rw",            MS_RDONLY, 1},
        {"shared",        MS_SHARED, 0},
        {"silent",        MS_SILENT, 0},
        {"slave",         MS_SLAVE, 0},
        {"strictatime",   MS_STRICTATIME, 0},
        {"suid",          MS_NOSUID, 1},
        {"sync",          MS_SYNCHRONOUS, 0},
        {"unbindable",    MS_UNBINDABLE, 0},
#ifdef MS_LAZYTIME
        {"lazytime",      MS_LAZYTIME, 0},
        {"nolazytime",    MS_LAZYTIME, 1},
#endif

        {"auto", 0, 0},
        {"defaults", 0, 0},
        {"group", 0, 0},
        {"noauto", 0, 0},
        {"nofail", 0, 0},
        {"nogroup", 0, 0},
        {"noowner", 0, 0},
        {"nouser", 0, 0},
        {"nousers", 0, 0},
        {"owner", 0, 0},
        {"user", 0, 0},
        {"users", 0, 0},
        {"x-create=dir", 0, 0},
        {"x-create=file", 0, 0},
        {"x-create=auto", 0, 0},
        {"x-move", MS_MOVE, 0},
        {"x-detach", MNT_DETACH, 0},
};

static void
init_capabilities(void)
{
        CAP_INIT_V3(&caps);

        if (capget(&caps.hdr, caps.data) < 0)
                err(EXIT_FAILURE, "failed to get capabilities");

        CAP_FOREACH(&caps, n) {
                if (n == CAP_DAC_READ_SEARCH || n == CAP_DAC_OVERRIDE)
                        continue;
                CAP_CLR(&caps, permitted, n);
                CAP_CLR(&caps, effective, n);
                CAP_CLR(&caps, inheritable, n);
        }
        CAP_SET(&caps, permitted, CAP_SYS_ADMIN);

        if (capset(&caps.hdr, caps.data) < 0)
                err(EXIT_FAILURE, "failed to set capabilities");
}

static int
detect_userns(void)
{
        static int rv = -1;
        FILE *fs;
        uint32_t eid, mid, n;
        char buf[5];

        if (rv >= 0)
                return (rv);

        if ((fs = fopen("/proc/self/uid_map", "r")) == NULL)
                return (errno != ENOENT ? -1 : (rv = 0));
        if (fscanf(fs, "%"PRIu32" %"PRIu32" %"PRIu32, &eid, &mid, &n) != 3)
                goto inns;
        if (eid != 0 || mid != 0 || n != UINT32_MAX)
                goto inns;
        if ((fs = freopen("/proc/self/gid_map", "r", fs)) == NULL)
                return (errno != ENOENT ? -1 : (rv = 0));
        if (fscanf(fs, "%"PRIu32" %"PRIu32" %"PRIu32, &eid, &mid, &n) != 3)
                goto inns;
        if (eid != 0 || mid != 0 || n != UINT32_MAX)
                goto inns;
        if ((fs = freopen("/proc/self/setgroups", "r", fs)) == NULL)
                return (errno != ENOENT ? -1 : (rv = 0));
        if (fgets(buf, sizeof(buf), fs) != NULL && !strcmp(buf, "deny"))
                goto inns;
        return (fclose(fs) < 0 ? -1 : (rv = 0));

 inns:
        return (fclose(fs) < 0 ? -1 : (rv = 1));
}

static bool
ismntopt(const char *str)
{
        if (strchr(str, ',') != NULL)
                return (true);
        for (size_t i = 0; i < ARRAY_SIZE(mount_opts); ++i) {
                if (!strcmp(str, mount_opts[i].name))
                        return (true);
        }
        return (false);
}

static ssize_t
xreadlinkat(int fd, const char *path, char *buf, size_t bufsize)
{
        ssize_t n;

        if ((n = readlinkat(fd, path, buf, bufsize)) < 0)
                return (-1);
        if ((size_t)n >= bufsize) {
                errno = ENAMETOOLONG;
                return (-1);
        }
        buf[n] = '\0';
        return (n);
}

static int
reopenat(int *dirfd, const char *path, int flags)
{
        int fd;

        if ((fd = openat(*dirfd, path, flags)) < 0)
                return (-1);
        if (close(*dirfd) < 0) {
                SAVE_ERRNO(close(fd));
                return (-1);
        }
        *dirfd = fd;
        return (0);
}

static int
realpathat(const char *dir, const char *path, char *resolved_path)
{
        int fd;
        int rv = -1;
        char res[PATH_MAX];
        char buf[2][PATH_MAX];
        char *comp, *next, *link, *p;
        unsigned int noent_depth = 0;
        unsigned int link_depth = 0;

        *res = '\0';
        link = buf[0];
        next = buf[1];

        if ((fd = open(dir, O_PATH|O_DIRECTORY)) < 0)
                goto err;

        if (strlcpy(next, path, PATH_MAX) >= PATH_MAX)
                goto err_toolong;
        while ((comp = strsep(&next, "/")) != NULL) {

                /* Component is empty or points to the current directory. */
                if (*comp == '\0' || !strcmp(comp, "."))
                        continue;

                /*
                 * Component points to the previous directory.
                 * Remove the last component from the resolved path and restore the previous file descriptor if applicable.
                 */
                if (!strcmp(comp, "..")) {
                        if ((p = strrchr(res, '/')) == NULL) {
                                errno = EXDEV;
                                goto err;
                        }
                        *p = '\0';
                        if (noent_depth > 0)
                                --noent_depth;
                        else {
                                if (reopenat(&fd, "..", O_PATH|O_NOFOLLOW|O_DIRECTORY) < 0)
                                        goto err;
                        }
                        continue;
                }

                /* Component is under a directory which does not exist. */
                if (noent_depth > 0)
                        goto enoent;

                /*
                 * Component is not a symbolic link or does not exist.
                 * Append the component to the resolved path and update our file descriptor if applicable.
                 */
                if (xreadlinkat(fd, comp, link, PATH_MAX) < 0) {
                        switch (errno) {
                        case EINVAL:
                                if (reopenat(&fd, comp, O_PATH|O_NOFOLLOW) < 0)
                                        goto err;
                                break;
                        case ENOENT:
                        enoent:
                                ++noent_depth;
                                break;
                        default:
                                goto err;
                        }
                        if (strlcat(res, "/", PATH_MAX) >= PATH_MAX ||
                            strlcat(res, comp, PATH_MAX) >= PATH_MAX)
                                goto err_toolong;
                        continue;
                }

                /*
                 * Component is a symbolic link.
                 * Append the rest of the path to it and proceed with the resulting buffer.
                 * If it is absolute, also clear the resolved path and restore our file descriptor to the initial directory.
                 */
                if (link_depth++ >= MAXSYMLINKS) {
                        errno = ELOOP;
                        goto err;
                }
                if (*link == '/') {
                        if (close(fd) < 0)
                                goto err;
                        if ((fd = open(dir, O_PATH|O_DIRECTORY)) < 0)
                                goto err;
                        *res = '\0';
                }
                if (next != NULL) {
                        if (strlcat(link, "/", PATH_MAX) >= PATH_MAX ||
                            strlcat(link, next, PATH_MAX) >= PATH_MAX)
                                goto err_toolong;
                }
                next = link;
                link = buf[link_depth % 2];
        }

        if (realpath(dir, resolved_path) == NULL)
                goto err;
        if (!strcmp(resolved_path, "/") && strlen(res) > 0)
                *resolved_path = '\0';
        if (strlcat(resolved_path, res, PATH_MAX) >= PATH_MAX)
                goto err_toolong;
        rv = 0;

 err_toolong:
        errno = rv ? ENAMETOOLONG : 0;
 err:
        SAVE_ERRNO(close(fd));
        return (rv);
}

static int
create_file(const char *path, mode_t mode)
{
        int rv = -1;
        char *dup = NULL, *dir = NULL, *next;

        if ((dup = strdup(path)) == NULL)
                goto err;
        if ((next = dir = strdup(dirname(dup))) == NULL)
                goto err;

        while (strsep(&next, "/") != NULL) {
                if (*dir != '\0') {
                        if (mkdir(dir, 0755) < 0 && errno != EEXIST)
                                goto err;
                }
                if (next != dir && next != NULL)
                        next[-1] = '/';
        }
        if (S_ISDIR(mode)) {
                if (mkdir(path, mode & (mode_t) ~S_IFMT) < 0 && errno != EEXIST)
                        goto err;
        } else {
                if (mknod(path, mode, 0) < 0 && errno != EEXIST)
                        goto err;
        }
        rv = 0;

 err:
        free(dup);
        free(dir);
        return (rv);
}

static int
parse_mount_opts(const char *opts, char **data, unsigned long *flags)
{
        int rv = -1;
        char *next, *buf, *opt;

        if ((next = buf = strdup(opts)) == NULL)
                goto err;
        if ((*data = malloc(strlen(opts) + 1)) == NULL)
                goto err;

        **data = '\0';
        *flags = 0;

        while ((opt = strsep(&next, ",")) != NULL) {
                if (*opt == '\0')
                        continue;
                for (size_t i = 0; i < ARRAY_SIZE(mount_opts); ++i) {
                        if (strcmp(opt, mount_opts[i].name))
                                continue;
                        if (mount_opts[i].clear)
                                *flags &= ~mount_opts[i].flag;
                        else
                                *flags |= mount_opts[i].flag;
                        goto outer;
                }
                if (strlen(*data) > 0)
                        strcat(*data, ",");
                strcat(*data, opt);
         outer:;
        }
        rv = 0;

 err:
        free(buf);
        return (rv);
}

static int
do_mount(const char *src, const char *dst, const char *type, unsigned long flags, const void *data)
{
        CAP_SET(&caps, effective, CAP_SYS_ADMIN);
        if (capset(&caps.hdr, caps.data) < 0)
                return (-1);

        if (mount(src, dst, type, flags, data) < 0)
                return (-1);

        CAP_CLR(&caps, effective, CAP_SYS_ADMIN);
        if (capset(&caps.hdr, caps.data) < 0)
                return (-1);
        return (0);
}

static int
do_umount(const char *target, int flags)
{
        CAP_SET(&caps, effective, CAP_SYS_ADMIN);
        if (capset(&caps.hdr, caps.data) < 0)
                return (-1);

        if (umount2(target, flags) < 0)
                return (-1);

        CAP_CLR(&caps, effective, CAP_SYS_ADMIN);
        if (capset(&caps.hdr, caps.data) < 0)
                return (-1);
        return (0);
}

static int
mount_generic(const char *dst, const struct mntent *mnt, unsigned long flags, const char *data)
{
        int userns;
        struct statvfs s;
        const struct { unsigned long sflag; unsigned long mflag; } s2mflag[] = {
                {ST_NOSUID, MS_NOSUID},
                {ST_NODEV, MS_NODEV},
                {ST_NOEXEC, MS_NOEXEC},
                {ST_RDONLY, MS_RDONLY},
                {ST_NOATIME, MS_NOATIME},
                {ST_NODIRATIME, MS_NODIRATIME},
                {ST_RELATIME, MS_RELATIME},
        };

        if (hasmntopt(mnt, "x-detach"))
                return (do_umount(dst, MNT_DETACH));

        if (!hasmntopt(mnt, "rbind"))
                flags &= (unsigned long)~MS_REC;

        if ((flags & MS_REMOUNT) || (flags & MS_BIND)) {
                if ((userns = detect_userns()) < 0)
                        return (-1);
                if (userns && statvfs((flags & MS_REMOUNT) ? dst : mnt->mnt_fsname, &s) == 0) {
                        for (size_t i = 0; i < ARRAY_SIZE(s2mflag); ++i) {
                                if (s.f_flag & s2mflag[i].sflag)
                                        flags |= s2mflag[i].mflag;
                        }
                }
        }

        if (do_mount(mnt->mnt_fsname, dst, mnt->mnt_type, flags, data) < 0)
                return (-1);

        if ((flags & MS_BIND) && !(flags & MS_REMOUNT)) {
                /* FIXME It might not be what we want here, consider "/foo /foo bind,dev" vs "/foo /foo bind" */
                if (!(flags & (unsigned long)~(MS_BIND|MS_REC)) && strlen(data) == 0)
                        return (0);
                if (do_mount(NULL, dst, NULL, flags|MS_REMOUNT, data) < 0)
                        return (-1);
        }
        return (0);
}

static int
mount_propagate(const char *dst, const struct mntent *mnt, unsigned long flags)
{
        const struct { unsigned long flag; const char *ropt; } propagation[] = {
                {MS_SHARED, "rshared"},
                {MS_SLAVE, "rslave"},
                {MS_PRIVATE, "rprivate"},
                {MS_UNBINDABLE, "runbindable"},
        };

        for (size_t i = 0; i < ARRAY_SIZE(propagation); ++i) {
                unsigned long tmp = flags;

                if (tmp & propagation[i].flag) {
                        tmp &= propagation[i].flag|MS_SILENT;
                        tmp |= hasmntopt(mnt, propagation[i].ropt) ? MS_REC : 0;
                        if (do_mount(NULL, dst, NULL, tmp, NULL) < 0)
                                return (-1);
                }
        }
        return (0);
}

static void
mount_entry(const char *root, const struct mntent *mnt)
{
        int rv = -1;
        bool fatal, verbose;
        char path[PATH_MAX];
        char errmsg[256 + PATH_MAX] = {0};
        char *data = NULL;
        unsigned long flags = 0;
        struct stat s;
        mode_t mode = 0;

        fatal = !hasmntopt(mnt, "nofail");
        verbose = !hasmntopt(mnt, "silent") || hasmntopt(mnt, "loud");

        if (realpathat(root, mnt->mnt_dir, path) < 0) {
                SAVE_ERRNO(snprintf(errmsg, sizeof(errmsg), "failed to resolve path: %s%s%s",
                    root, (*mnt->mnt_dir == '/') ? "" : "/", mnt->mnt_dir));
                goto err;
        }
        if (parse_mount_opts(mnt->mnt_opts, &data, &flags) < 0) {
                SAVE_ERRNO(snprintf(errmsg, sizeof(errmsg), "failed to parse mount entry"));
                goto err;
        }

        if (hasmntopt(mnt, "x-create=file"))
                mode |= S_IFREG;
        else if (hasmntopt(mnt, "x-create=dir"))
                mode |= S_IFDIR;
        else if (hasmntopt(mnt, "x-create=auto")) {
                if (!(flags & MS_BIND))
                        mode |= S_IFDIR;
                else if (stat(mnt->mnt_fsname, &s) == 0)
                        mode |= S_ISDIR(s.st_mode) ? S_IFDIR : S_IFREG;
        }
        if (mode != 0) {
                if (create_file(path, mode) < 0) {
                        SAVE_ERRNO(snprintf(errmsg, sizeof(errmsg), "failed to create %s: %s",
                            S_ISREG(mode) ? "file" : "directory", path));
                        goto err;
                }
        }

        if ((!strnull(mnt->mnt_type) && strcmp(mnt->mnt_type, "none")) || flags & ~(MS_PROPAGATION|MS_REC|MS_SILENT)) {
                if (mount_generic(path, mnt, flags & ~MS_PROPAGATION, data) < 0) {
                        SAVE_ERRNO(snprintf(errmsg, sizeof(errmsg), "failed to %smount: %s at %s",
                            hasmntopt(mnt, "x-detach") ? "un" : "", mnt->mnt_fsname, path));
                        goto err;
                }
        }
        if (flags & MS_PROPAGATION) {
                if (mount_propagate(path, mnt, flags & (MS_PROPAGATION|MS_REC|MS_SILENT)) < 0) {
                        SAVE_ERRNO(snprintf(errmsg, sizeof(errmsg), "failed to set mount propagation: %s", path));
                        goto err;
                }
        }
        rv = 0;

 err:
        free(data);
        if (rv < 0) {
                if (fatal)
                        err(EXIT_FAILURE, "%s", errmsg);
                if (verbose)
                        warn("%s", errmsg);
        }
}

static void
mount_fstab(const char *root, const char *fstab, int passno)
{
        FILE *fs;
        struct mntent mnt;
        char buf[FSTAB_LINE_MAX];

        if ((fs = setmntent(fstab, "r")) == NULL)
                err(EXIT_FAILURE, "failed to open: %s", fstab);
        while (compat_getmntent_r(fs, &mnt, buf, sizeof(buf)) != NULL) {
                /* Use fs_freq as fs_passno if it wasn't specified. */
                if (mnt.mnt_freq != 0 && mnt.mnt_passno == 0)
                        mnt.mnt_passno = mnt.mnt_freq;
                if (passno != mnt.mnt_passno)
                        continue;

                /* Try to guess the mount entry if it's missing components, for example
                 * tmpfs /dst        -> tmpfs /dst tmpfs  ""
                 * /src              -> /src  /src none   rbind,x-create=auto
                 * /src  bind        -> /src  /src none   bind
                 * /src  /dst        -> /src  /dst none   rbind,x-create=auto
                 * /src  /dst bind   -> /src  /dst none   bind
                 * none  /dst devpts -> none  /dst devpts ""
                 */
                if (!strnull(mnt.mnt_dir) && strnull(mnt.mnt_type) && strnull(mnt.mnt_opts) && ismntopt(mnt.mnt_dir)) {
                        mnt.mnt_opts = mnt.mnt_dir;
                        mnt.mnt_type = (char *)"none";
                        mnt.mnt_dir = (char *)"";
                }
                if (!strnull(mnt.mnt_type) && strnull(mnt.mnt_opts) && ismntopt(mnt.mnt_type)) {
                        mnt.mnt_opts = mnt.mnt_type;
                        mnt.mnt_type = (char *)"none";
                        if (!strcmp(mnt.mnt_dir, "none"))
                                mnt.mnt_dir = (char *)"";
                }
                if (!strnull(mnt.mnt_fsname)) {
                        if (!strcmp(mnt.mnt_fsname, "tmpfs")) {
                                if (strnull(mnt.mnt_type) || !strcmp(mnt.mnt_type, "none"))
                                        mnt.mnt_type = (char *)"tmpfs";
                        } else {
                                if (strnull(mnt.mnt_dir))
                                        mnt.mnt_dir = mnt.mnt_fsname;
                                if (strnull(mnt.mnt_type) || !strcmp(mnt.mnt_type, "none")) {
                                        mnt.mnt_type = (char *)"none";
                                        if (strnull(mnt.mnt_opts))
                                                mnt.mnt_opts = (char *)"rbind,x-create=auto";
                                }
                        }
                }
                if (mnt.mnt_opts == NULL)
                        mnt.mnt_opts = (char *)"";
                if (strnull(mnt.mnt_fsname) || strnull(mnt.mnt_dir) || strnull(mnt.mnt_type))
                        errx(EXIT_FAILURE, "invalid fstab entry: \"%s\" at %s", buf, fstab);

                mount_entry(root, &mnt);
        }
        endmntent(fs);
}

int
main(int argc, char *argv[])
{
        const char *root = "/";
        int e, passno = 0;

        for (;;) {
                if (argc >= 3 && !strcmp(argv[1], "--root")) {
                        root = argv[2];
                        SHIFT_ARGS(2);
                        continue;
                }
                if (argc >= 3 && !strcmp(argv[1], "--pass")) {
                        passno = (int)strtoi(argv[2], NULL, 10, INT_MIN, INT_MAX, &e);
                        if (e != 0)
                                errx(EXIT_FAILURE, "invalid argument: %s", argv[2]);
                        SHIFT_ARGS(2);
                        continue;
                }
                break;
        }
        if (argc < 2) {
                printf("Usage: %s [--root DIR] [--pass NUM] FSTAB...\n", argv[0]);
                return (0);
        }

        init_capabilities();

        if (argc == 2 && !strcmp(argv[1], "-"))
                mount_fstab(root, "/proc/self/fd/0", passno);
        else {
                for (int i = 1; i < argc; ++i)
                        mount_fstab(root, argv[i], passno);
        }
        return (0);
}
