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
#include <ctype.h>
#include <err.h>
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

#define NORETURN      __attribute__((noreturn))
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

static bool debug_flag;

static void __attribute__((constructor))
init(void)
{
        debug_flag = (getenv("ENROOT_DEBUG") != NULL);
}

static inline void  __attribute__((format(printf, 1, 2), nonnull(1)))
warndbg(const char *fmt, ...)
{
        va_list ap;

        if (debug_flag) {
            va_start(ap, fmt);
            vwarn(fmt, ap);
            va_end(ap);
        }
}

static inline bool
strnull(const char *str)
{
        return (str == NULL || *str == '\0');
}

static inline char *
strtrim(const char *str, const char *prefix)
{
        size_t len;

        len = strlen(prefix);
        if (!strncmp(str, prefix, len))
                return ((char *)str + len);
        return ((char *)str);
}

static inline int
unshare_userns(bool remap_root)
{
        char *uidmap = NULL, *gidmap = NULL;
        int rv = -1;

        if (asprintf(&gidmap, "%d %d 1", remap_root ? 0 : getegid(), getegid()) < 0) {
                gidmap = NULL;
                goto err;
        }
        if (asprintf(&uidmap, "%d %d 1", remap_root ? 0 : geteuid(), geteuid()) < 0) {
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

static inline bool
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

static inline int
load_environment(const char *envfile)
{
        FILE *fs;
        char *buf = NULL, *ptr;
        size_t n = 0;

        if ((fs = fopen(envfile, "r")) == NULL)
                return (-1);
        if (clearenv() < 0)
                return (-1);
        while (getline(&buf, &n, fs) >= 0) {
                buf[strcspn(buf, "\n")] = '\0';
                if (!envvar_valid(buf))
                        continue;

                ptr = strchr(buf, '=');
                *ptr++ = '\0';
                if (setenv(buf, ptr, 1) < 0)
                        goto err;
        }
        if (!feof(fs))
                goto err;
        if (fclose(fs) < 0)
                goto err;
        free(buf);
        return (0);

 err:
        free(buf);
        SAVE_ERRNO(fclose(fs));
        return (-1);
}
