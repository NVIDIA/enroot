/*
 * Copyright (c) 1996  Peter Wemm <peter@FreeBSD.org>.
 * All rights reserved.
 * Copyright (c) 2002 Networks Associates Technology, Inc.
 * All rights reserved.
 *
 * Portions of this software were developed for the FreeBSD Project by
 * ThinkSec AS and NAI Labs, the Security Research Division of Network
 * Associates, Inc.  under DARPA/SPAWAR contract N66001-01-C-8035
 * ("CBOSS"), as part of the DARPA CHATS research program.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, is permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. The name of the author may not be used to endorse or promote
 *    products derived from this software without specific prior written
 *    permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 *
 * $FreeBSD: src/lib/libutil/libutil.h,v 1.47 2008/04/23 00:49:12 scf Exp $
 */

#ifndef LIBBSD_LIBUTIL_H
#define LIBBSD_LIBUTIL_H

#ifdef LIBBSD_OVERLAY
#include <sys/cdefs.h>
#else
#include <bsd/sys/cdefs.h>
#endif
#include <sys/types.h>
#include <stdint.h>
#include <stdio.h>

struct pidfh;

__BEGIN_DECLS
int humanize_number(char *buf, size_t len, int64_t bytes,
    const char *suffix, int scale, int flags);
int expand_number(const char *_buf, uint64_t *_num);

int flopen(const char *_path, int _flags, ...);
int flopenat(int dirfd, const char *path, int flags, ...);

struct pidfh *pidfile_open(const char *path, mode_t mode, pid_t *pidptr);
int pidfile_fileno(const struct pidfh *pfh);
int pidfile_write(struct pidfh *pfh);
int pidfile_close(struct pidfh *pfh);
int pidfile_remove(struct pidfh *pfh);

char   *fparseln(FILE *, size_t *, size_t *, const char[3], int);
__END_DECLS

/* Values for humanize_number(3)'s flags parameter. */
#define HN_DECIMAL		0x01
#define HN_NOSPACE		0x02
#define HN_B			0x04
#define HN_DIVISOR_1000		0x08
#define HN_IEC_PREFIXES		0x10

/* Values for humanize_number(3)'s scale parameter. */
#define HN_GETSCALE		0x10
#define HN_AUTOSCALE		0x20

/*
 * fparseln() specific operation flags.
 */
#define FPARSELN_UNESCESC	0x01
#define FPARSELN_UNESCCONT	0x02
#define FPARSELN_UNESCCOMM	0x04
#define FPARSELN_UNESCREST	0x08
#define FPARSELN_UNESCALL	0x0f

#endif /* !LIBBSD_LIBUTIL_H */
