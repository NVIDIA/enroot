/*
 * Copyright © 2004-2006, 2009-2011 Guillem Jover <guillem@hadrons.org>
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

#ifndef __has_include
#define __has_include(x) 1
#endif
#ifndef __has_include_next
#define __has_include_next(x) 1
#endif
#ifndef __has_attribute
#define __has_attribute(x) 0
#endif
/* Clang expands this to 1 if an identifier is *not* reserved. */
#ifndef __is_identifier
#define __is_identifier(x) 1
#endif

#ifdef LIBBSD_OVERLAY
/*
 * Some libc implementations do not have a <sys/cdefs.h>, in particular
 * musl, try to handle this gracefully.
 */
#if __has_include_next(<sys/cdefs.h>)
#include_next <sys/cdefs.h>
#endif
#else
#if __has_include(<sys/cdefs.h>)
#include <sys/cdefs.h>
#endif
#endif

#ifndef LIBBSD_SYS_CDEFS_H
#define LIBBSD_SYS_CDEFS_H

#ifndef __BEGIN_DECLS
#ifdef __cplusplus
#define __BEGIN_DECLS	extern "C" {
#define __END_DECLS	}
#else
#define __BEGIN_DECLS
#define __END_DECLS
#endif
#endif

/*
 * On non-glibc based systems, we cannot unconditionally use the
 * __GLIBC_PREREQ macro as it gets expanded before evaluation.
 */
#ifndef __GLIBC_PREREQ
#define __GLIBC_PREREQ(maj, min) 0
#endif

/*
 * Some kFreeBSD headers expect those macros to be set for sanity checks.
 */
#ifndef _SYS_CDEFS_H_
#define _SYS_CDEFS_H_
#endif
#ifndef _SYS_CDEFS_H
#define _SYS_CDEFS_H
#endif

#define LIBBSD_CONCAT(x, y)	x ## y
#define LIBBSD_STRING(x)	#x

#ifdef __GNUC__
#define LIBBSD_GCC_VERSION (__GNUC__ << 8 | __GNUC_MINOR__)
#else
#define LIBBSD_GCC_VERSION 0
#endif

#if LIBBSD_GCC_VERSION >= 0x0405 || __has_attribute(__deprecated__)
#define LIBBSD_DEPRECATED(x) __attribute__((__deprecated__(x)))
#elif LIBBSD_GCC_VERSION >= 0x0301
#define LIBBSD_DEPRECATED(x) __attribute__((__deprecated__))
#else
#define LIBBSD_DEPRECATED(x)
#endif

#if LIBBSD_GCC_VERSION >= 0x0200 || defined(__clang__)
#define LIBBSD_REDIRECT(name, proto, alias) name proto __asm__(LIBBSD_ASMNAME(#alias))
#endif
#define LIBBSD_ASMNAME(cname) LIBBSD_ASMNAME_PREFIX(__USER_LABEL_PREFIX__, cname)
#define LIBBSD_ASMNAME_PREFIX(prefix, cname) LIBBSD_STRING(prefix) cname

#ifndef __dead2
# if LIBBSD_GCC_VERSION >= 0x0207 || __has_attribute(__noreturn__)
#  define __dead2 __attribute__((__noreturn__))
# else
#  define __dead2
# endif
#endif

#ifndef __pure2
# if LIBBSD_GCC_VERSION >= 0x0207 || __has_attribute(__const__)
#  define __pure2 __attribute__((__const__))
# else
#  define __pure2
# endif
#endif

#ifndef __packed
# if LIBBSD_GCC_VERSION >= 0x0207 || __has_attribute(__packed__)
#  define __packed __attribute__((__packed__))
# else
#  define __packed
# endif
#endif

#ifndef __aligned
# if LIBBSD_GCC_VERSION >= 0x0207 || __has_attribute(__aligned__)
#  define __aligned(x) __attribute__((__aligned__(x)))
# else
#  define __aligned(x)
# endif
#endif

/* Linux headers define a struct with a member names __unused.
 * Debian bugs: #522773 (linux), #522774 (libc).
 * Disable for now. */
#if 0
#ifndef __unused
# if LIBBSD_GCC_VERSION >= 0x0300
#  define __unused __attribute__((__unused__))
# else
#  define __unused
# endif
#endif
#endif

#ifndef __printflike
# if LIBBSD_GCC_VERSION >= 0x0300 || __has_attribute(__format__)
#  define __printflike(x, y) __attribute((__format__(__printf__, (x), (y))))
# else
#  define __printflike(x, y)
# endif
#endif

#ifndef __nonnull
# if LIBBSD_GCC_VERSION >= 0x0302 || __has_attribute(__nonnull__)
#  define __nonnull(x) __attribute__((__nonnull__(x)))
# else
#  define __nonnull(x)
# endif
#endif

#ifndef __bounded__
# define __bounded__(x, y, z)
#endif

/*
 * Return the number of elements in a statically-allocated array,
 * __x.
 */
#define	__arraycount(__x)	(sizeof(__x) / sizeof(__x[0]))

/*
 * We define this here since <stddef.h>, <sys/queue.h>, and <sys/types.h>
 * require it.
 */
#ifndef __offsetof
# if LIBBSD_GCC_VERSION >= 0x0401 || !__is_identifier(__builtin_offsetof)
#  define __offsetof(type, field)	__builtin_offsetof(type, field)
# else
#  ifndef __cplusplus
#   define __offsetof(type, field) \
           ((size_t)(uintptr_t)((const volatile void *)&((type *)0)->field))
#  else
#   define __offsetof(type, field) \
	(__offsetof__ (reinterpret_cast <size_t> \
	               (&reinterpret_cast <const volatile char &> \
	                (static_cast<type *> (0)->field))))
#  endif
# endif
#endif

#define __rangeof(type, start, end) \
        (__offsetof(type, end) - __offsetof(type, start))

/*
 * Given the pointer x to the member m of the struct s, return
 * a pointer to the containing structure.  When using GCC, we first
 * assign pointer x to a local variable, to check that its type is
 * compatible with member m.
 */
#ifndef __containerof
# if LIBBSD_GCC_VERSION >= 0x0301 || !__is_identifier(__typeof__)
#  define __containerof(x, s, m) ({ \
	const volatile __typeof__(((s *)0)->m) *__x = (x); \
	__DEQUALIFY(s *, (const volatile char *)__x - __offsetof(s, m)); \
})
# else
#  define __containerof(x, s, m) \
          __DEQUALIFY(s *, (const volatile char *)(x) - __offsetof(s, m))
# endif
#endif

#ifndef __RCSID
# define __RCSID(x)
#endif

#ifndef __FBSDID
# define __FBSDID(x)
#endif

#ifndef __RCSID
# define __RCSID(x)
#endif

#ifndef __RCSID_SOURCE
# define __RCSID_SOURCE(x)
#endif

#ifndef __SCCSID
# define __SCCSID(x)
#endif

#ifndef __COPYRIGHT
# define __COPYRIGHT(x)
#endif

#ifndef __DECONST
#define __DECONST(type, var)	((type)(uintptr_t)(const void *)(var))
#endif

#ifndef __DEVOLATILE
#define __DEVOLATILE(type, var)	((type)(uintptr_t)(volatile void *)(var))
#endif

#ifndef __DEQUALIFY
#define __DEQUALIFY(type, var)	((type)(uintptr_t)(const volatile void *)(var))
#endif

#endif
