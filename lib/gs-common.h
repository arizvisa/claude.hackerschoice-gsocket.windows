
#ifndef __GS_COMMON_H__
#define __GS_COMMON_H__ 1

#ifdef HAVE_CONFIG_H
# include <config.h>
#endif

#ifdef _WIN32
# include "win32-compat.h"
#else
#include <sys/types.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#if defined(__FREEBSD__)
# include <sys/sysctl.h>
# include <sys/caprights.h>
# include <sys/param.h>
# include <sys/queue.h>
#endif // __FREEBSD__
#include <netinet/in.h>
#ifdef HAVE_NETINET_IN_SYSTM_H
# include <netinet/in_systm.h>
#endif
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <netinet/ip_icmp.h>
#include <arpa/inet.h>
#include <netdb.h>              // gethostbyname
#include <unistd.h>
#include <signal.h>
#include <libgen.h>		/* basename() */
#include <fcntl.h>
#endif /* !_WIN32 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <stdlib.h>
#include <stdint.h>
#include <ctype.h>
#include <inttypes.h>
#if defined(__APPLE__) && defined(HAVE_LIBPROC_H)
# include <libproc.h>          // getpidwd(pid_t)
#endif
#if defined(__FREEBSD__)
// FIXME: Please tell me where this is defined? fbsd 12-1 complains:
// /usr/include/libprocstat.h:122:15: error: field 'fs_cap_rights' has incomplete type
# ifndef cap_rights_t
typedef struct cap_rights       cap_rights_t;
# endif
# include <libprocstat.h>
#endif
#include <openssl/srp.h>
#include <openssl/ssl.h>
#include <openssl/rand.h>
#include <openssl/err.h>

static inline int
gs_set_nonblock(int fd, int onoff)
{
#ifdef _WIN32
	u_long mode = onoff ? 1 : 0;
	return ioctlsocket((SOCKET)fd, FIONBIO, &mode) == 0 ? 0 : -1;
#else
	int flags = fcntl(fd, F_GETFL, 0);
	if (flags < 0)
		return -1;
	if (onoff)
		flags |= O_NONBLOCK;
	else
		flags &= ~O_NONBLOCK;
	return fcntl(fd, F_SETFL, flags);
#endif
}

#ifndef MAX
# define MAX(X, Y) (((X) < (Y)) ? (Y) : (X))
#endif

#ifndef MIN
# define MIN(X, Y) (((X) < (Y)) ? (X) : (Y))
#endif

// debian-hurd does not define PATH_MAX (and has no limit on filename length)
#ifndef PATH_MAX
# define GS_PATH_MAX      4096
#else
# define GS_PATH_MAX      PATH_MAX
#endif

#define D_RED(a)	"\033[0;31m"a"\033[0m"
#define D_GRE(a)	"\033[0;32m"a"\033[0m"
#define D_YEL(a)	"\033[0;33m"a"\033[0m"
#define D_BLU(a)	"\033[0;34m"a"\033[0m"
#define D_MAG(a)	"\033[0;35m"a"\033[0m"
#define D_BRED(a)	"\033[1;31m"a"\033[0m"
#define D_BGRE(a)	"\033[1;32m"a"\033[0m"
#define D_BYEL(a)	"\033[1;33m"a"\033[0m"
#define D_BBLU(a)	"\033[1;34m"a"\033[0m"
#define D_BMAG(a)	"\033[1;35m"a"\033[0m"
#ifdef DEBUG
# define DEBUGF(...)   do{ xfprintf(gs_dout, D_BLU("LIB")"-%d %s:%d: ", gs_did, __func__, __LINE__); xfprintf(gs_dout, __VA_ARGS__); }while(0)
# define DEBUGF_R(...) do{ xfprintf(gs_dout, D_BLU("LIB")"-%d %s:%d: ", gs_did, __func__, __LINE__); xfprintf(gs_dout, "\033[1;31m"); xfprintf(gs_dout, __VA_ARGS__); xfprintf(gs_dout, "\033[0m"); }while(0)
# define DEBUGF_G(...) do{ xfprintf(gs_dout, D_BLU("LIB")"-%d %s:%d: ", gs_did, __func__, __LINE__); xfprintf(gs_dout, "\033[1;32m"); xfprintf(gs_dout, __VA_ARGS__); xfprintf(gs_dout, "\033[0m"); }while(0)
# define DEBUGF_B(...) do{ xfprintf(gs_dout, D_BLU("LIB")"-%d %s:%d: ", gs_did, __func__, __LINE__); xfprintf(gs_dout, "\033[1;34m"); xfprintf(gs_dout, __VA_ARGS__); xfprintf(gs_dout, "\033[0m"); }while(0)
# define DEBUGF_Y(...) do{ xfprintf(gs_dout, D_BLU("LIB")"-%d %s:%d: ", gs_did, __func__, __LINE__); xfprintf(gs_dout, "\033[1;33m"); xfprintf(gs_dout, __VA_ARGS__); xfprintf(gs_dout, "\033[0m"); }while(0)
# define DEBUGF_M(...) do{ xfprintf(gs_dout, D_BLU("LIB")"-%d %s:%d: ", gs_did, __func__, __LINE__); xfprintf(gs_dout, "\033[1;35m"); xfprintf(gs_dout, __VA_ARGS__); xfprintf(gs_dout, "\033[0m"); }while(0)
# define DEBUGF_C(...) do{ xfprintf(gs_dout, D_BLU("LIB")"-%d %s:%d: ", gs_did, __func__, __LINE__); xfprintf(gs_dout, "\033[1;36m"); xfprintf(gs_dout, __VA_ARGS__); xfprintf(gs_dout, "\033[0m"); }while(0)
# define DEBUGF_W(...) do{ xfprintf(gs_dout, D_BLU("LIB")"-%d %s:%d: ", gs_did, __func__, __LINE__); xfprintf(gs_dout, "\033[1;37m"); xfprintf(gs_dout, __VA_ARGS__); xfprintf(gs_dout, "\033[0m"); }while(0)
# define DEBUG_SETID(xgs)    gs_did = (xgs)->fd
#else
# define DEBUGF(...)
# define DEBUGF_R(...)
# define DEBUGF_G(...)
# define DEBUGF_B(...)
# define DEBUGF_Y(...)
# define DEBUGF_M(...)
# define DEBUGF_C(...)
# define DEBUGF_W(...)
# define DEBUG_SETID(xgs)
#endif

#define SXPRINTF(ptr, len, ...) do {\
        size_t n = snprintf(ptr, len, __VA_ARGS__); \
        ptr += MIN(n, len); \
} while(0)

#define XFREE(ptr)  do{if(ptr) free(ptr); ptr = NULL;}while(0)

#define xfprintf(fp, ...) do {if (fp != NULL) { fprintf(fp, __VA_ARGS__); fflush(fp); } } while (0)

/* A detached CreateThread() worker (see win_childproc.c's reader_thread/writer_thread)
 * can be parked mid-syscall, possibly holding a CRT/loader lock, at the exact moment
 * any of the fatal macros below run - exit()'s ExitProcess() has to synchronize with
 * every other thread before it can finish, and a thread stuck like that is a well-known
 * way for that to hang forever instead of actually terminating. TerminateProcess kills
 * the whole process at the OS level unconditionally - no atexit chain, no CRT lock,
 * nothing left for another thread to block. POSIX's plain exit(code) has no such hazard
 * (no equivalent "wait for every thread" step), so it's untouched.
 */
#ifdef _WIN32
# define GS_HARD_EXIT(code)  TerminateProcess(GetCurrentProcess(), (code))
#else
# define GS_HARD_EXIT(code)  exit(code)
#endif

#ifdef DEBUG
# define ERREXIT(...)   do { \
	xfprintf(gs_errfp, "ERROR "); \
        xfprintf(gs_errfp, "%s():%d ", __func__, __LINE__); \
        xfprintf(gs_errfp, __VA_ARGS__); \
        GS_HARD_EXIT(255); \
} while (0)
#else
# define ERREXIT(...)   do { \
	xfprintf(gs_errfp, "ERROR: "); \
        xfprintf(gs_errfp, __VA_ARGS__); \
        GS_HARD_EXIT(255); \
} while (0)
#endif

#ifndef XASSERT
# define XASSERT(expr, ...) do { \
	if (!(expr)) { \
		xfprintf(gs_errfp, "%s:%d:%s() ASSERT(%s) ", __FILE__, __LINE__, __func__, #expr); \
		xfprintf(gs_errfp, __VA_ARGS__); \
		xfprintf(gs_errfp, " Exiting...\n"); \
		GS_HARD_EXIT(255); \
	} \
} while (0)
#endif

#define XCLOSE(fd)      do { \
        if (fd < 0) { break; } \
        DEBUGF_W("Closing fd = %d\n", fd); \
        close(fd); \
        fd = -1; \
} while (0)

#define XFD_SET(fd, set) do { \
        /*if (fd <= 0) { DEBUGF_R("WARNING: FD_SET(%d, )\n", fd); } */ \
        if (fd < 0) { break; } \
        FD_SET(fd, set); \
} while (0)

#define XFD_CLR(fd, set) do { \
        if (fd <= 0) { DEBUGF_R("WARNING: FD_CLR(%d, )\n", fd); } \
        if (fd < 0) { break; } \
        FD_CLR(fd, set); \
} while (0)

#ifdef DEBUG
# define HEXDUMP(a, len)        do { \
        int n = 0; \
        xfprintf(gs_dout, D_BLU("LIB")" %s:%d HEX ", __FILE__, __LINE__); \
        while (n < len) { xfprintf(gs_dout, "%2.2x", ((unsigned char *)a)[n]); n++; } \
        xfprintf(gs_dout, "\n"); \
} while (0)

# define HEXDUMPF(a, len, ...) do{xfprintf(gs_dout, __VA_ARGS__); HEXDUMP(a, len);}while(0)
#else
# define HEXDUMP(a, len)
# define HEXDUMPF(a, len, ...)
#endif

#endif /* !__GS_COMMON_H__ */
