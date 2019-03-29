/*
 * Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/capability.h>
#include <sched.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define MAYBE_UNUSED  __attribute__((unused))
#define ARRAY_SIZE(x) (sizeof(x) / sizeof(*x))
#define SAVE_ERRNO(x) __extension__ ({ int save_errno = errno; x; errno = save_errno; })
#define SHIFT_ARGS(x) argv[x] = argv[0]; argv += x; argc -= x

struct capabilities_v3 {
        struct __user_cap_header_struct hdr;
        struct __user_cap_data_struct data[_LINUX_CAPABILITY_U32S_3];
};

extern int capset(cap_user_header_t, cap_user_data_t);
extern int capget(cap_user_header_t, const cap_user_data_t);

#define CAP_INIT_V3(caps)        *caps = (struct capabilities_v3){{_LINUX_CAPABILITY_VERSION_3, 0}, {{0}}}
#define CAP_SET(caps, set, n)    (caps)->data[n / 32].set |= (1u << n % 32)
#define CAP_CLR(caps, set, n)    (caps)->data[n / 32].set &= ~(1u << n % 32)
#define CAP_ISSET(caps, set, n)  (caps)->data[n / 32].set & (1u << n % 32)
#define CAP_FOREACH(caps, n)     for (size_t n = 0; n < 32 * ARRAY_SIZE((caps)->data); ++n)
#define CAP_COPY(caps, dst, src) for (size_t i = 0; i < ARRAY_SIZE((caps)->data); ++i) \
                                        (caps)->data[i].dst = (caps)->data[i].src

static inline int
unshare_userns(bool map_root)
{
        char *uidmap = NULL, *gidmap = NULL;
        int rv = -1;

        if (asprintf(&gidmap, "%d %d 1", map_root ? 0 : getegid(), getegid()) < 0) {
                gidmap = NULL;
                goto err;
        }
        if (asprintf(&uidmap, "%d %d 1", map_root ? 0 : geteuid(), geteuid()) < 0) {
                uidmap = NULL;
                goto err;
        }

        if (unshare(CLONE_NEWUSER) < 0)
                goto err;

        struct { const char *path, *data; } procf[] = {
                {"/proc/self/setgroups", "deny"},
                {"/proc/self/gid_map", gidmap},
                {"/proc/self/uid_map", uidmap},
        };
        for (int fd, i = 0; i < (int)ARRAY_SIZE(procf); ++i) {
                if ((fd = open(procf[i].path, O_WRONLY)) < 0)
                        goto err;
                if (write(fd, procf[i].data, strlen(procf[i].data)) < 0) {
                        SAVE_ERRNO(close(fd));
                        goto err;
                }
                if (close(fd) < 0)
                        goto err;
        }
        rv = 0;

 err:
        free(gidmap);
        free(uidmap);
        return (rv);
}
