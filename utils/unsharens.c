/*
 * Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.
 */

#define _GNU_SOURCE
#include <err.h>
#include <errno.h>
#include <sched.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

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

static struct capabilities_v3 caps;

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

        if (execvp(argv[1], &argv[1]) < 0)
                err(EXIT_FAILURE, "failed to execute: %s", argv[1]);
        return (0);
}
