/*
 * Copyright © 2005 Aurelien Jarno
 * Copyright © 2006 Robert Millan
 * Copyright © 2008-2011 Guillem Jover <guillem@hadrons.org>
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL
 * THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#ifdef LIBBSD_OVERLAY
#include_next <stdlib.h>
#else
#include <stdlib.h>
#endif

/* For compatibility with NetBSD, which defines humanize_number here. */
#ifdef LIBBSD_OVERLAY
#include <libutil.h>
#else
#include <bsd/libutil.h>
#endif

#ifndef LIBBSD_STDLIB_H
#define LIBBSD_STDLIB_H

#ifdef LIBBSD_OVERLAY
#include <sys/cdefs.h>
#else
#include <bsd/sys/cdefs.h>
#endif
#include <sys/stat.h>
#include <stdint.h>

__BEGIN_DECLS
#if !defined(__GLIBC__) || \
    !__GLIBC_PREREQ(2, 36) || \
    !defined(_DEFAULT_SOURCE)
uint32_t arc4random(void);
void arc4random_buf(void *_buf, size_t n);
uint32_t arc4random_uniform(uint32_t upper_bound);
#endif
void arc4random_stir(void);
void arc4random_addrandom(unsigned char *dat, int datlen);

int dehumanize_number(const char *str, int64_t *size);

const char *getprogname(void);
void setprogname(const char *);

int heapsort(void *, size_t, size_t, int (*)(const void *, const void *));
int mergesort(void *base, size_t nmemb, size_t size,
              int (*cmp)(const void *, const void *));
int radixsort(const unsigned char **base, int nmemb,
              const unsigned char *table, unsigned endbyte);
int sradixsort(const unsigned char **base, int nmemb,
               const unsigned char *table, unsigned endbyte);

void *reallocf(void *ptr, size_t size);
#if !defined(__GLIBC__) || \
    !__GLIBC_PREREQ(2, 26) || \
    (__GLIBC_PREREQ(2, 26) && !__GLIBC_PREREQ(2, 29) && !defined(_GNU_SOURCE)) || \
    (__GLIBC_PREREQ(2, 29) && !defined(_DEFAULT_SOURCE))
void *reallocarray(void *ptr, size_t nmemb, size_t size);
#endif
void *recallocarray(void *ptr, size_t oldnmemb, size_t nmemb, size_t size);
void freezero(void *ptr, size_t size);

long long strtonum(const char *nptr, long long minval, long long maxval,
                   const char **errstr);

char *getbsize(int *headerlenp, long *blocksizep);
__END_DECLS

#endif
