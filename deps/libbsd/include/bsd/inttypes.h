/*
 * Copyright © 2018 Guillem Jover <guillem@hadrons.org>
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
#include_next <inttypes.h>
#else
#include <inttypes.h>
#endif

#ifndef LIBBSD_INTTYPES_H
#define LIBBSD_INTTYPES_H

#ifdef LIBBSD_OVERLAY
#include <sys/cdefs.h>
#else
#include <bsd/sys/cdefs.h>
#endif

__BEGIN_DECLS
intmax_t strtoi(const char *__restrict nptr, char **__restrict endptr,
                int base, intmax_t lo, intmax_t hi, int *rstatus);
uintmax_t strtou(const char *__restrict nptr, char **__restrict endptr,
                 int base, uintmax_t lo, uintmax_t hi, int *rstatus);
__END_DECLS

#endif
