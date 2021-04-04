/*
 * Copyright (c) 2018-2021, NVIDIA CORPORATION. All rights reserved.
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
        int flag = (type == FTW_DP || type == FTW_DNR) ? AT_REMOVEDIR : 0;
        const char *filename = path + ftwbuf->base;
        char *whiteout;

        if (!strcmp(filename, AUFS_WH_PREFIX AUFS_WH_PREFIX AUFS_WH_OPQ_SUFFIX)) {
                if (unlinkat(-1, path, flag) < 0)
                        err(EXIT_FAILURE, "failed to remove opaque aufs whiteout: %s", path);
                if ((whiteout = strdup(path)) == NULL)
                        err(EXIT_FAILURE, "failed to allocate memory");
                whiteout[ftwbuf->base] = '\0';
                if (do_setxattr(whiteout) < 0)
                        err(EXIT_FAILURE, "failed to create opaque ovlfs whiteout: %s", whiteout);
                free(whiteout);
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

        if (argc < 2) {
                printf("Usage: %s DIR\n", argv[0]);
                return (0);
        }

        init_capabilities();

        /*
         * Ideally we would like to do this as an unprivileged user, however setting trusted xattrs is currently
         * gated by CAP_SYS_ADMIN in the init userns, and mknod on userns-owned filesystems (Linux 4.19) hasn't
         * been picked up by mainstream distributions.
         */
#if 0
        if (unshare_userns(false) < 0)
                err(EXIT_FAILURE, "failed to create user namespace");
#endif
        if (realpath(argv[1], path) == NULL)
                err(EXIT_FAILURE, "failed to resolve path: %s", argv[1]);
        if (nftw(path, handle_whiteout, FOPEN_MAX, FTW_MOUNT|FTW_PHYS|FTW_DEPTH) < 0) /* FTW_CHDIR is not supported on Musl. */
                err(EXIT_FAILURE, "failed to walk directory: %s", path);
        return (0);
}
