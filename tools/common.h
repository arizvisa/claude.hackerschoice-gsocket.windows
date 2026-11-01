
#ifndef __GST_COMMON_H__
#define __GST_COMMON_H__ 1

/* Windows/MSVC port of upstream tools/common.h. See stubs.h for the 3
 * subsystems deliberately not ported (console UI, IDS, file-transfer). */

/* These must come BEFORE win32-compat.h: ucrt's <io.h> declares its own
 * (deprecated-but-present) `read`/`write`/`close` names for POSIX source
 * compat, and win32-compat.h's macros of the same names would otherwise
 * rewrite - and break - that declaration text. */
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <stdlib.h>
#include <stdint.h>
#include <ctype.h>
#include <inttypes.h>
#include <signal.h>
#include <locale.h>
#include <time.h>
#include <io.h>			/* _isatty, _fileno, _getcwd */
#include <direct.h>		/* _getcwd */
#include <process.h>	/* _getpid */

#include "win32-compat.h"	/* winsock2.h, FD_SETSIZE=4096, socket macros - in lib/, reached via the -I search path */

#include <openssl/ssl.h>
#include <openssl/srp.h>
#include <openssl/sha.h>
#include <gsocket/gsocket.h>
#include <gsocket/gs-select.h>

#include "win_getopt.h"
#include "stubs.h"	/* GS_FT must be a complete type before struct _peer below uses it by value */
#include "gsocket_dso-lib.h"	/* authcookie_gen(), gs_getenv(), portrange - fully portable, unmodified */

#ifndef PACKAGE_VERSION
# define PACKAGE_VERSION "1.4.41-winport"
#endif

#ifndef PATH_MAX
# define GS_PATH_MAX      4096
#else
# define GS_PATH_MAX      PATH_MAX
#endif

#ifndef htonll
# define htonll(x)	htobe64(x)
#endif
#ifndef ntohll
# define ntohll(x)  be64toh(x)
#endif
#ifndef htobe64
# define htobe64(x) _byteswap_uint64(x)
# define be64toh(x) _byteswap_uint64(x)
#endif

/* Windows has no isatty()/getcwd()/getpid() by those POSIX names */
#define isatty(fd)   _isatty(fd)
#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2
static __inline char *gs_getcwdx_win(void) { return _getcwd(NULL, 0); }
#define getpid() _getpid()

/* win32-compat.h (src/gsocket/, shared with the already-verified gs-tunnel.exe
 * build) intentionally covers only what that tool needs and is left alone
 * here. gs-netcat additionally needs non-blocking toggling (fcntl(O_NONBLOCK)
 * in upstream) - added locally instead of touching the shared compat header. */
static __inline void
gs_win_set_nonblock(int fd, int on)
{
	u_long mode = on ? 1 : 0;
	ioctlsocket((SOCKET)fd, FIONBIO, &mode);
}

/* ucrt's fcntl.h has no F_SETFL/F_GETFL/O_NONBLOCK (those are POSIX
 * fcntl() flags, not related to ucrt's _O_* file-open flags). */
#ifndef F_SETFL
# define F_SETFL 4
# define F_GETFL 3
#endif
#ifndef O_NONBLOCK
# define O_NONBLOCK 04000
#endif

/* UCRT's errno.h defines EWOULDBLOCK (140) as a DIFFERENT value from EAGAIN
 * (11) - but win32-compat.h's gs_win_xlate_errno() always translates
 * WSAEWOULDBLOCK to EAGAIN, never to EWOULDBLOCK. Code written for POSIX
 * (where EWOULDBLOCK == EAGAIN on every mainstream libc) that checks
 * `errno == EWOULDBLOCK` - e.g. read_esc() in 4_gs-netcat.c - would
 * otherwise silently never match on Windows. Force them equal. */
#undef EWOULDBLOCK
#define EWOULDBLOCK EAGAIN

/* fcntl(fd, F_SETFL, O_NONBLOCK | fcntl(fd, F_GETFL, 0)) and the
 * clear-nonblock variant, as used in 4_gs-netcat.c's read_esc() - redirect
 * to gs_win_set_nonblock() above. F_GETFL deliberately has NO side effect
 * (just returns 0, i.e. "no flags") - it appears nested inside the F_SETFL
 * call's own argument (`O_NONBLOCK | fcntl(fd, F_GETFL, 0)`), which the
 * preprocessor expands too since macro args are expanded before
 * substitution; giving it a real side effect here would make that nested,
 * supposedly-read-only call itself toggle blocking mode on every use. */
#define fcntl(fd, cmd, ...) gs_win_fcntl_stub((fd), (cmd), __VA_ARGS__)
static __inline int
gs_win_fcntl_stub(int fd, int cmd, long arg)
{
	if (cmd == F_SETFL)
		gs_win_set_nonblock(fd, (arg & O_NONBLOCK) ? 1 : 0);
	return 0; /* F_GETFL (or anything else): no flags, no side effect */
}

/* "winsize" isn't a Windows concept; keep upstream's struct winsize shape
 * (used by get_winsize()/pkt_app_cb_wsize) as a plain local struct. Must be
 * defined before struct _gopt below, which embeds it by value. */
struct winsize
{
	unsigned short ws_row;
	unsigned short ws_col;
	unsigned short ws_xpixel;
	unsigned short ws_ypixel;
};

struct _gopt
{
	GS_CTX gs_ctx;
	GS *gsocket;	/* Listening gsocket */

	FILE *log_fp;
	FILE *err_fp;
	int verbosity;
	int flags;
	int verboselevel;
	const char *sec_str;
	const char *sec_file;
	GS_ADDR gs_addr;
	char *token_str;
	int is_sock_wait;
	int is_client_or_server;
	int is_no_encryption;
	int is_blocking;
	int is_interactive;
	int is_receive_only;
	int is_use_tor;
	int is_socks_server;
	int is_multi_peer;
	int is_daemon;
	int is_watchdog;
	int is_logfile;
	int is_quiet;
	int is_win_resized;
	int is_console;
	int is_pong_pending;
	int is_status_nopty_pending;
	int is_pty_failed;
	int is_want_pwd;
	int is_pwdreply_pending;
	int is_want_chdir;
	int is_want_ids_on;
	int is_want_authcookie;
	int is_send_authcookie;
	int is_internal;
	int is_udp;
	int is_built_debug;
	int is_greetings;
	int is_try_server;
	int gs_server_check_sec;
	int is_stdin_a_tty;
	int is_stdin_ignore_eof;
	char *prg_name;
	uint64_t ts_ping_sent;
	fd_set rfd, r;
	fd_set wfd, w;
	struct timeval tv_now;
	const char *cmd;
	uint32_t dst_ip;
	uint16_t port;
	int listen_fd;
	struct winsize winsize;
	struct winsize winsize_prev;
	int row_total;
	int peer_count;
	int peer_id_counter;
	GS_EVENT event_ping;
	GS_EVENT event_bps;
	GS_EVENT *event_ids;
	GS_LIST ids_peers;
	char *ids_active_user;
	int ids_idle;
	int n_users;
	int app_keepalive_sec;
};

#ifdef DEBUG
#define GS_APP_KEEPALIVE        10
#else
#define GS_APP_KEEPALIVE        GSRN_DEFAULT_PING_INTERVAL
#endif
#define GS_APP_KEEPALIVE_SERVER   (GS_APP_KEEPALIVE + 5)

#define EX_CONNREFUSED  61
#define EX_BAD_AUTH    201
#define EX_ALARM       202
#define EX_NETERROR    203
#define EX_EXECFAILED  248
#define EX_NOTREACHED  249
#define EX_BADWRITE    250
#define EX_UNKNWNCMD   251

#define EX_BADSELECT   253
#define EX_SIGTERM     254
#define EX_FATAL       255

struct _socks
{
	uint32_t dst_ip;
	uint16_t dst_port;
	char dst_hostname[256];
	int state;
};

#define GSNC_STATE_AWAITING_MSG_AUTH        (0x01)
#define GSNC_STATE_AWAITING_MSG_CONNECT     (0x02)
#define GSNC_STATE_RESOLVING_DN	            (0x03)
#define GSNC_STATE_CONNECTING               (0x04)
#define GSNC_STATE_CONNECTED                (0x05)

struct _peer
{
	GS *gs;
	int fd_in;
	int fd_out;
	uint8_t rbuf[2048];
	size_t r_max;
	ssize_t rlen;
	uint8_t wbuf[2048];
	size_t w_max;
	ssize_t wlen;
	uint8_t pbuf[2048];
	int is_network_forward;
	int is_stdin_forward;
	int is_app_forward;
	int is_fd_connected;
	int is_pty_first_read;
	int is_stty_set_raw;
	int is_received_gs_eof;
	int is_want_ping;
	int id;
	struct _socks socks;
	GS_PKT pkt;
	GS_FT ft;
	GS_LIST logs;
	int is_pending_logs;
	GS_LIST_ITEM *ids_li;
	pid_t pid;
	uint64_t ts_peer_io;
	GS_BUF udp_buf;
	GS_EVENT event_peer_timeout;
};

#define GSC_FL_IS_SERVER		(0x01)

extern struct _gopt gopt;

#define xfprintf(fp, ...) do {if (fp != NULL) { fprintf(fp, __VA_ARGS__); fflush(fp); } } while (0)

#define int_ntoa(x)	inet_ntoa(*((struct in_addr *)&x))

#ifndef MAX
# define MAX(X, Y) (((X) < (Y)) ? (Y) : (X))
#endif
#ifndef MIN
# define MIN(X, Y) (((X) < (Y)) ? (X) : (Y))
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

#define DEBUGF(...)
#define DEBUGF_R(...)
#define DEBUGF_G(...)
#define DEBUGF_B(...)
#define DEBUGF_Y(...)
#define DEBUGF_M(...)
#define DEBUGF_C(...)
#define DEBUGF_W(...)
#define DEBUGF_A(...)

#define SXPRINTF(ptr, len, ...) do {\
	size_t n = snprintf(ptr, len, __VA_ARGS__); \
	ptr += MIN(n, len); \
} while(0)

#define SNPRINTF_ABORT(...)	(snprintf(__VA_ARGS__) < 0 ? abort() : (void)0)

#define VOUT(level, ...) do { \
	if (level > gopt.verboselevel) \
		break; \
	xfprintf(gopt.out, __VA_ARGS__); \
	fflush(gopt.out); \
} while (0)

#define XFREE(ptr)  do{if(ptr) free(ptr); ptr = NULL;}while(0)

#define ERREXITC(code, ...)   do { \
		xfprintf(gopt.err_fp, "ERROR(%d): ", code); \
        xfprintf(gopt.err_fp, __VA_ARGS__); \
        exit(code); \
} while (0)

#define ERREXIT(...)   do { \
		xfprintf(gopt.err_fp, "ERROR: "); \
        xfprintf(gopt.err_fp, __VA_ARGS__); \
        exit(255); \
} while (0)

#ifndef XASSERT
# define XASSERT(expr, ...) do { \
	if (!(expr)) { \
		xfprintf(gopt.err_fp, "%s:%d:%s() ASSERT(%s) ", __FILE__, __LINE__, __func__, #expr); \
		xfprintf(gopt.err_fp, __VA_ARGS__); \
		xfprintf(gopt.err_fp, " Exiting...\n"); \
		exit(255); \
	} \
} while (0)
#endif

#define XCLOSE(fd)      do { \
        if (fd < 0) { break; } \
        close(fd); \
        fd = -1; \
} while (0)

#define XFCLOSE(fp)		do { \
		if (fp == NULL) { break; } \
		fclose(fp); \
		fp = NULL; \
} while (0)

#define XFD_SET(fd, set) do { \
        if (fd < 0) { break; } \
        FD_SET(fd, set); \
} while (0)

#define HEXDUMP(a, len)
#define HEXDUMPF(a, len, ...)

#endif /* !__GST_COMMON_H__ */
