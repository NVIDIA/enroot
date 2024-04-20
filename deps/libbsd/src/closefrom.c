/*
 * SPDX-License-Identifier: ISC
 *
 * Copyright (c) 2004-2005, 2007, 2010, 2012-2015, 2017-2018
 *	Todd C. Miller <Todd.Miller@sudo.ws>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#ifdef __linux__
# include <sys/syscall.h>
# if defined(__NR_close_range) && !defined(SYS_close_range)
#  define SYS_close_range __NR_close_range
# endif
#endif
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>
#ifdef HAVE_PSTAT_GETPROC
# include <sys/param.h>
# include <sys/pstat.h>
#else
# ifdef HAVE_DIRENT_H
#  include <dirent.h>
#  define NAMLEN(dirent) strlen((dirent)->d_name)
# else
#  define dirent direct
#  define NAMLEN(dirent) (dirent)->d_namlen
#  ifdef HAVE_SYS_NDIR_H
#   include <sys/ndir.h>
#  endif
#  ifdef HAVE_SYS_DIR_H
#   include <sys/dir.h>
#  endif
#  ifdef HAVE_NDIR_H
#   include <ndir.h>
#  endif
# endif
#endif

#ifndef OPEN_MAX
# define OPEN_MAX 256
#endif

static inline void
closefrom_close(int fd)
{
#ifdef __APPLE__
	/* Avoid potential libdispatch crash when we close its fds. */
	(void)fcntl(fd, F_SETFD, FD_CLOEXEC);
#else
	(void)close(fd);
#endif
}

#if defined(__linux__) && defined(SYS_close_range)
static inline int
sys_close_range(unsigned int fd, unsigned int max_fd, unsigned int flags)
{
	return syscall(SYS_close_range, fd, max_fd, flags);
}
#endif

/*
 * Close all file descriptors greater than or equal to lowfd.
 * This is the expensive (fallback) method.
 */
static void
closefrom_fallback(int lowfd)
{
	long fd, maxfd;

	/*
	 * Fall back on sysconf(_SC_OPEN_MAX) or getdtablesize(). This is
	 * equivalent to checking the RLIMIT_NOFILE soft limit. It is
	 * possible for there to be open file descriptors past this limit
	 * but there is not much we can do about that since the hard limit
	 * may be RLIM_INFINITY (LLONG_MAX or ULLONG_MAX on modern systems).
	 */
#ifdef HAVE_SYSCONF
	maxfd = sysconf(_SC_OPEN_MAX);
#else
	maxfd = getdtablesize();
#endif /* HAVE_SYSCONF */
	if (maxfd < OPEN_MAX)
		maxfd = OPEN_MAX;

	/* Make sure we did not get RLIM_INFINITY as the upper limit. */
	if (maxfd > INT_MAX)
		maxfd = INT_MAX;

	for (fd = lowfd; fd < maxfd; fd++)
		closefrom_close(fd);
}

#if defined(HAVE_PSTAT_GETPROC)
static int
closefrom_pstat(int lowfd)
{
	struct pst_status pst;
	int fd;

	/*
	 * EOVERFLOW is not a fatal error for the fields we use.
	 * See the "EOVERFLOW Error" section of pstat_getvminfo(3).
	 */
	if (pstat_getproc(&pst, sizeof(pst), 0, getpid()) != -1 ||
	    errno == EOVERFLOW) {
		for (fd = lowfd; fd <= pst.pst_highestfd; fd++)
			(void)close(fd);
		return 0;
	}
	return -1;
}
#elif defined(HAVE_DIRFD)
static int
closefrom_procfs(int lowfd)
{
	const char *path;
	DIR *dirp;
	struct dirent *dent;
	int *fd_array = NULL;
	int fd_array_used = 0;
	int fd_array_size = 0;
	int ret = 0;
	int i;

	/* Use /proc/self/fd (or /dev/fd on macOS) if it exists. */
# ifdef __APPLE__
	path = "/dev/fd";
# else
	path = "/proc/self/fd";
# endif
	dirp = opendir(path);
	if (dirp == NULL)
		return -1;

	while ((dent = readdir(dirp)) != NULL) {
		const char *errstr;
		int fd;

		fd = strtonum(dent->d_name, lowfd, INT_MAX, &errstr);
		if (errstr != NULL || fd == dirfd(dirp))
			continue;

		if (fd_array_used >= fd_array_size) {
			int *ptr;

			if (fd_array_size > 0)
				fd_array_size *= 2;
			else
				fd_array_size = 32;

			ptr = reallocarray(fd_array, fd_array_size, sizeof(int));
			if (ptr == NULL) {
				ret = -1;
				break;
			}
			fd_array = ptr;
		}

		fd_array[fd_array_used++] = fd;
	}

	for (i = 0; i < fd_array_used; i++)
		closefrom_close(fd_array[i]);

	free(fd_array);
	(void)closedir(dirp);

	return ret;
}
#endif

/*
 * Close all file descriptors greater than or equal to lowfd.
 * We try the fast way first, falling back on the slow method.
 */
void
closefrom(int lowfd)
{
	if (lowfd < 0)
		lowfd = 0;

	/* Try the fast methods first, if possible. */
#if defined(HAVE_FCNTL_CLOSEM)
	if (fcntl(lowfd, F_CLOSEM, 0) != -1)
		return;
#endif /* HAVE_FCNTL_CLOSEM */
#if defined(__linux__) && defined(SYS_close_range)
	if (sys_close_range(lowfd, UINT_MAX, 0) == 0)
		return;
#endif

#if defined(HAVE_PSTAT_GETPROC)
	if (closefrom_pstat(lowfd) != -1)
		return;
#elif defined(HAVE_DIRFD)
	if (closefrom_procfs(lowfd) != -1)
		return;
#endif /* HAVE_DIRFD */

	/* Do things the slow way. */
	closefrom_fallback(lowfd);
}
