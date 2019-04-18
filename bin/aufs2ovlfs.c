/*
 * Copyright (c) 2018-2019, NVIDIA CORPORATION. All rights reserved.
 */

#define _GNU_SOURCE
#include <err.h>
#include <fcntl.h>
#include <ftw.h>
#include <limits.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <unistd.h>

#include "common.h"

#define AUFS_WH_PREFIX     ".wh."
#define AUFS_WH_OPQ_SUFFIX ".opq"
#define AUFS_WH_PREFIX_LEN (sizeof(AUFS_WH_PREFIX) - 1)

static struct capabilities_v3 caps;

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
        CAP_SET(&caps, permitted, CAP_MKNOD);
        CAP_SET(&caps, permitted, CAP_SYS_ADMIN);

        if (capset(&caps.hdr, caps.data) < 0)
                err(EXIT_FAILURE, "failed to set capabilities");
}

static int
do_mknod(const char *path)
{
        CAP_SET(&caps, effective, CAP_MKNOD);
        if (capset(&caps.hdr, caps.data) < 0)
                return (-1);

        if (mknod(path, S_IFCHR|0600, makedev(0, 0)) < 0)
                return (-1);

        CAP_CLR(&caps, effective, CAP_MKNOD);
        if (capset(&caps.hdr, caps.data) < 0)
                return (-1);
        return (0);
}

static int
do_setxattr(const char *path)
{
        CAP_SET(&caps, effective, CAP_SYS_ADMIN);
        if (capset(&caps.hdr, caps.data) < 0)
                return (-1);

        if (setxattr(path, "trusted.overlay.opaque", "y", 1, XATTR_CREATE) < 0)
                return (-1);

        CAP_CLR(&caps, effective, CAP_SYS_ADMIN);
        if (capset(&caps.hdr, caps.data) < 0)
                return (-1);
        return (0);
}

static int
handle_whiteout(const char *path, MAYBE_UNUSED const struct stat *sb, int type, MAYBE_UNUSED struct FTW *ftwbuf)
{
        static bool opaque = false;

        int flag = (type == FTW_DP || type == FTW_DNR) ? AT_REMOVEDIR : 0;
        const char *filename = path + ftwbuf->base;
        char *whiteout;

        if (type == FTW_DP && opaque) {
                opaque = false;
                if (do_setxattr(path) < 0)
                        err(EXIT_FAILURE, "failed to create opaque ovlfs whiteout: %s", path);
        }
        if (!strcmp(filename, AUFS_WH_PREFIX AUFS_WH_PREFIX AUFS_WH_OPQ_SUFFIX)) {
                opaque = true;
                if (unlinkat(-1, path, flag) < 0)
                        err(EXIT_FAILURE, "failed to remove opaque aufs whiteout: %s", path);
                return (0);
        }

        if (!strncmp(filename, AUFS_WH_PREFIX AUFS_WH_PREFIX, 2 * AUFS_WH_PREFIX_LEN))
                errx(EXIT_FAILURE, "unsupported aufs whiteout: %s", path);

        if (!strncmp(filename, AUFS_WH_PREFIX, AUFS_WH_PREFIX_LEN)) {
                if (unlinkat(-1, path, flag) < 0)
                        err(EXIT_FAILURE, "failed to remove aufs whiteout: %s", path);
                if ((whiteout = strdup(path)) == NULL)
                        err(EXIT_FAILURE, "failed to allocate memory");
                strcpy(whiteout + ftwbuf->base, filename + AUFS_WH_PREFIX_LEN);
                if (do_mknod(whiteout) < 0)
                        err(EXIT_FAILURE, "failed to create ovlfs whiteout: %s", whiteout);
                free(whiteout);
        }
        return (0);
}

int
main(int argc, char *argv[])
{
        char path[PATH_MAX];

        if (argc < 2)
                errx(EXIT_FAILURE, "usage: %s dir", argv[0]);

        init_capabilities();

        /*
         * Ideally we would like to do this as an unprivileged user, however setting trusted xattrs is currently
         * gated by CAP_SYS_ADMIN in the init userns, and mknod on userns-owned filesystems (Linux 4.19) hasn't
         * been picked up by mainstream distributions.
         */
#if 0
        if (unshare_userns(false) < 0)
                err(EXIT_FAILURE, "failed to unshare user namespace");
#endif
        if (realpath(argv[1], path) == NULL)
                err(EXIT_FAILURE, "failed to resolve path: %s", argv[1]);
        if (nftw(path, handle_whiteout, FOPEN_MAX, FTW_MOUNT|FTW_PHYS|FTW_DEPTH|FTW_CHDIR) < 0)
                err(EXIT_FAILURE, "failed to walk directory: %s", path);
        return (0);
}
