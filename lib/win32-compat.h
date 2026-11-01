/*
 * Win32 compatibility shim for the ported gsocket lib/.
 * Included only via gs-common.h's `#ifdef _WIN32` branch.
 *
 * This codebase treats socket descriptors as plain `int` throughout (never
 * SOCKET) and uses -1 as its "invalid fd" sentinel (see XCLOSE/XFD_SET in
 * gs-common.h). We keep that convention on Windows too: socket()/accept()
 * results are narrowed to int at the point of creation, and read()/write()/
 * close() are redirected to their Winsock equivalents for those ints.
 */
#ifndef __GS_WIN32_COMPAT_H__
#define __GS_WIN32_COMPAT_H__ 1

#define WIN32_LEAN_AND_MEAN
#ifndef _CRT_SECURE_NO_WARNINGS
# define _CRT_SECURE_NO_WARNINGS
#endif

/*
 * KNOWN LIMITATION: GS_SELECT_CTX (gs-select.h) indexes several of its
 * bookkeeping arrays directly by raw fd value (e.g. mgr_r[fd], sized
 * [FD_SETSIZE]). That's safe on POSIX, where fds are small sequential
 * integers. On Windows a SOCKET is a real kernel handle value with no such
 * guarantee - Winsock's own fd_set is array/count-based (not a value-indexed
 * bitmask), so bumping FD_SETSIZE only fixes FD_SET/FD_CLR/select() itself;
 * it does NOT guarantee every socket handle value stays under this bound.
 * For this tool's small, short-lived handle count this is true in practice,
 * but it is an empirical assumption, not a proof - a real fix needs a
 * handle->dense-index translation table in gsocket-select.c. Flagged in the
 * port report; not fixed here.
 */
#define FD_SETSIZE 4096

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <basetsd.h>
#include <stdint.h>
#include <malloc.h> /* _alloca */

typedef SSIZE_T ssize_t;
typedef int pid_t; /* unused on Windows builds (GS_getpidwd/GS_daemonize are stubbed out) */

#define strdup _strdup

#ifndef SHUT_RD
# define SHUT_RD   SD_RECEIVE
#endif
#ifndef SHUT_WR
# define SHUT_WR   SD_SEND
#endif
#ifndef SHUT_RDWR
# define SHUT_RDWR SD_BOTH
#endif

/* sleep() takes seconds on POSIX; Sleep() takes milliseconds. */
#define sleep(sec) Sleep((DWORD)(sec) * 1000)

static inline int
gs_win_gettimeofday(struct timeval *tv, void *tz)
{
	(void)tz;
	FILETIME ft;
	ULARGE_INTEGER uli;
	/* 100ns intervals since 1601-01-01 -> usec since 1970-01-01 */
	GetSystemTimeAsFileTime(&ft);
	uli.LowPart = ft.dwLowDateTime;
	uli.HighPart = ft.dwHighDateTime;
	uint64_t usec_since_1601 = uli.QuadPart / 10;
	const uint64_t EPOCH_DIFF_USEC = 11644473600000000ULL;
	uint64_t usec_since_1970 = usec_since_1601 - EPOCH_DIFF_USEC;
	tv->tv_sec = (long)(usec_since_1970 / 1000000ULL);
	tv->tv_usec = (long)(usec_since_1970 % 1000000ULL);
	return 0;
}
#define gettimeofday(tv, tz) gs_win_gettimeofday((tv), (tz))

/*
 * The lib checks errno against POSIX codes (EAGAIN, EINTR, EINPROGRESS,
 * ECONNRESET, EISCONN, ...) after failed socket calls. Winsock reports
 * errors via WSAGetLastError() using WSAE*-numbered codes that do NOT
 * match errno.h's values, so every wrapper below must translate.
 * WSAEWOULDBLOCK -> EAGAIN covers both the read/write "would block" checks
 * AND the non-blocking connect()-in-progress check (which also accepts
 * EAGAIN, since POSIX's EINPROGRESS has no separate Winsock code).
 */
static inline void
gs_win_xlate_errno(void)
{
	switch (WSAGetLastError())
	{
		case WSAEWOULDBLOCK:  errno = EAGAIN; break;
		case WSAEINTR:        errno = EINTR; break;
		case WSAEINPROGRESS:  errno = EINPROGRESS; break;
		case WSAECONNRESET:   errno = ECONNRESET; break;
		case WSAECONNABORTED: errno = ECONNABORTED; break;
		case WSAEISCONN:      errno = EISCONN; break;
		case WSAENOTCONN:     errno = ENOTCONN; break;
		case WSAETIMEDOUT:    errno = ETIMEDOUT; break;
		case WSAECONNREFUSED: errno = ECONNREFUSED; break;
		default:              errno = EIO; break;
	}
}

static inline int
gs_win_socket(int af, int type, int proto)
{
	SOCKET s = socket(af, type, proto);
	if (s == INVALID_SOCKET)
	{
		gs_win_xlate_errno();
		return -1;
	}
	return (int)s;
}
#define socket(af, type, proto) gs_win_socket((af), (type), (proto))

static inline int
gs_win_close(int fd)
{
	if (fd < 0)
		return 0;
	return closesocket((SOCKET)fd) == 0 ? 0 : -1;
}
#define close(fd) gs_win_close(fd)

static inline ssize_t
gs_win_read(int fd, void *buf, size_t len)
{
	int ret = recv((SOCKET)fd, (char *)buf, (int)len, 0);
	if (ret == SOCKET_ERROR)
	{
		gs_win_xlate_errno();
		return -1;
	}
	return (ssize_t)ret;
}
#define read(fd, buf, len) gs_win_read((fd), (buf), (len))

static inline ssize_t
gs_win_write(int fd, const void *buf, size_t len)
{
	int ret = send((SOCKET)fd, (const char *)buf, (int)len, 0);
	if (ret == SOCKET_ERROR)
	{
		gs_win_xlate_errno();
		return -1;
	}
	return (ssize_t)ret;
}
#define write(fd, buf, len) gs_win_write((fd), (buf), (len))

static inline int
gs_win_connect(int fd, const struct sockaddr *addr, int addrlen)
{
	if (connect((SOCKET)fd, addr, addrlen) == SOCKET_ERROR)
	{
		gs_win_xlate_errno();
		return -1;
	}
	return 0;
}
#define connect(fd, addr, addrlen) gs_win_connect((fd), (addr), (addrlen))

static inline int
gs_win_select(int nfds, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv)
{
	(void)nfds; /* Winsock's select() ignores nfds and only looks at the fd_sets */
	int ret = select(0, r, w, e, tv);
	if (ret == SOCKET_ERROR)
	{
		gs_win_xlate_errno();
		return -1;
	}
	return ret;
}
#define select(nfds, r, w, e, tv) gs_win_select((nfds), (r), (w), (e), (tv))

/*
 * One-time Winsock init/teardown. gs-tunnel.c calls these from main();
 * the ported lib itself has no program-lifecycle hook to do it implicitly.
 */
static inline int
gs_win_wsa_init(void)
{
	WSADATA wsa;
	return WSAStartup(MAKEWORD(2, 2), &wsa);
}
#define gs_win_wsa_cleanup() WSACleanup()

#endif /* !__GS_WIN32_COMPAT_H__ */
