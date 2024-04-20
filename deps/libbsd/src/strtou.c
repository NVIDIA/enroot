/*	$NetBSD: _strtoi.h,v 1.2 2015/01/18 17:55:22 christos Exp $	*/

/*-
 * Copyright (c) 1990, 1993
 *	The Regents of the University of California.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. Neither the name of the University nor the names of its contributors
 *    may be used to endorse or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 *
 * Original version ID:
 * NetBSD: src/lib/libc/locale/_wcstoul.h,v 1.2 2003/08/07 16:43:03 agc Exp
 *
 * Created by Kamil Rytarowski, based on ID:
 * NetBSD: src/common/lib/libc/stdlib/_strtoul.h,v 1.7 2013/05/17 12:55:56 joe…
 */

#include <sys/cdefs.h>

#include <stddef.h>
#include <assert.h>
#include <errno.h>
#include <inttypes.h>

#define _DIAGASSERT(t)

uintmax_t
strtou(const char *__restrict nptr,
       char **__restrict endptr, int base,
       uintmax_t lo, uintmax_t hi, int *rstatus)
{
	int serrno;
	uintmax_t im;
	char *ep;
	int rep;

	_DIAGASSERT(hi >= lo);

	_DIAGASSERT(nptr != NULL);
	/* endptr may be NULL */

	if (endptr == NULL)
		endptr = &ep;

	if (rstatus == NULL)
		rstatus = &rep;

	serrno = errno;
	errno = 0;

	im = strtoumax(nptr, endptr, base);

	*rstatus = errno;
	errno = serrno;

	if (*rstatus == 0) {
		/* No digits were found */
		if (nptr == *endptr)
			*rstatus = ECANCELED;
		/* There are further characters after number */
		else if (**endptr != '\0')
			*rstatus = ENOTSUP;
	}

	if (im < lo) {
		if (*rstatus == 0)
			*rstatus = ERANGE;
		return lo;
	}
	if (im > hi) {
		if (*rstatus == 0)
			*rstatus = ERANGE;
		return hi;
	}

	return im;
}
