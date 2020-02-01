/*
 * Copyright © 2005-2020 Rich Felker, et al.
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to
 * the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#include <stdio.h>
#include <string.h>
#include <mntent.h>
#include <errno.h>
#include <utmp.h>

#ifdef __GLIBC__
# define compat_getmntent_r getmntent_r
# define compat_lastlog     lastlog
#else

static inline struct mntent *
compat_getmntent_r(FILE *f, struct mntent *mnt, char *linebuf, int buflen)
{
        int n[8] = {0};

        *mnt = (struct mntent){0};

        do {
                fgets(linebuf, buflen, f);
                if (feof(f) || ferror(f))
                        return (NULL);

                if (!strchr(linebuf, '\n')) {
                        fscanf(f, "%*[^\n]%*[\n]");
                        errno = ERANGE;
                        return (NULL);
                }
                sscanf(linebuf, " %n%*s%n %n%*s%n %n%*s%n %n%*s%n %d %d",
                    n, n+1, n+2, n+3, n+4, n+5, n+6, n+7,
                    &mnt->mnt_freq, &mnt->mnt_passno);
        } while (n[1] == 0 || linebuf[n[0]] == '#');

        linebuf[n[1]] = '\0';
        mnt->mnt_fsname = linebuf + n[0];

        if (n[3] > 0) {
            linebuf[n[3]] = '\0';
            mnt->mnt_dir = linebuf + n[2];
        }
        if (n[5] > 0) {
            linebuf[n[5]] = '\0';
            mnt->mnt_type = linebuf + n[4];
        }
        if (n[7] > 0) {
            linebuf[n[7]] = '\0';
            mnt->mnt_opts = linebuf + n[6];
        }
        return (mnt);
}

struct compat_lastlog {
#ifdef __x86_64__
        int32_t ll_time;
#else
        time_t ll_time;
#endif
        char ll_line[UT_LINESIZE];
        char ll_host[UT_HOSTSIZE];
};

#endif
