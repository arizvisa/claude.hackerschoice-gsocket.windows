/*
 * gs-tunnel: minimal Windows-native GSRN TCP tunnel.
 *
 * Server/listener side (registers on the GSRN, forwards each incoming
 * GS connection to a local target):
 *   gs-tunnel -s <secret> -l -d <target-ip> -p <target-port>
 *
 * Client/dialer side (listens locally, forwards each local connection
 * out through the GSRN to the listener side above):
 *   gs-tunnel -s <secret> -p <local-port>
 *
 * Modeled on upstream gsocket's tools/3_gs-full-pipe.c relay pattern, with
 * a real local TCP socket substituted for stdin/stdout, and gs-netcat's
 * -l/-d/-p/-s port-forward flag semantics for familiarity. Scope is
 * deliberately narrow: no PTY/SOCKS/file-transfer (that's gs-netcat's
 * job, not ported here), and one forwarded TCP session is relayed at a
 * time (sessions are handled sequentially in a loop, not concurrently).
 */
#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS
/*
 * Must match win32-compat.h's FD_SETSIZE exactly. The ported lib's
 * GS_SELECT_CTX/gs_accept_blocking() memcpy whole fd_sets using sizeof(),
 * computed against whatever FD_SETSIZE was in effect when THAT translation
 * unit included winsock2.h. A mismatch here is a silent ABI mismatch: the
 * lib's memcpy would read/write past this file's (smaller) fd_set buffers.
 */
#define FD_SETSIZE 4096
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <basetsd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>

typedef SSIZE_T ssize_t;

#include <openssl/ssl.h>
#include <openssl/srp.h>

#include <gsocket/gsocket.h>
#include <gsocket/gs-select.h>

#define BUF_SZ 4096

struct session
{
	GS *gs;
	SOCKET local_fd;
	int done;

	unsigned char gs2local_buf[BUF_SZ];
	size_t gs2local_len;

	unsigned char local2gs_buf[BUF_SZ];
	size_t local2gs_len;
};

static void
die(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	exit(1);
}

static void
set_nonblock(SOCKET s)
{
	u_long mode = 1;
	ioctlsocket(s, FIONBIO, &mode);
}

/* ---- direction: local socket -> GS ---- */

static int
write_to_gs(GS_SELECT_CTX *ctx, struct session *sess)
{
	ssize_t ret = GS_write(sess->gs, sess->local2gs_buf, sess->local2gs_len);

	if (ret == (ssize_t)sess->local2gs_len)
	{
		sess->local2gs_len = 0;
		FD_SET((int)sess->local_fd, ctx->rfd);
		FD_CLR(GS_get_fd(sess->gs), ctx->wfd);
		return GS_SUCCESS;
	}
	if (ret > 0)
	{
		memmove(sess->local2gs_buf, sess->local2gs_buf + ret, sess->local2gs_len - ret);
		sess->local2gs_len -= ret;
		FD_CLR((int)sess->local_fd, ctx->rfd);
		FD_SET(GS_get_fd(sess->gs), ctx->wfd);
		return GS_ECALLAGAIN;
	}
	if (ret == 0)
		return GS_ECALLAGAIN; /* would block */

	/* ret < 0: fatal GS write error */
	sess->done = 1;
	return GS_SUCCESS;
}

static int
cb_read_local(GS_SELECT_CTX *ctx, int fd, void *arg, int val)
{
	struct session *sess = (struct session *)arg;
	(void)fd; (void)val;

	if (sess->local2gs_len != 0)
		return GS_SUCCESS; /* buffer busy; shouldn't normally be called */

	int n = recv(sess->local_fd, (char *)sess->local2gs_buf, sizeof sess->local2gs_buf, 0);
	if (n == 0)
	{
		/* Local side closed. Tell peer by shutting down our GS write side. */
		GS_shutdown(sess->gs);
		FD_CLR((int)sess->local_fd, ctx->rfd);
		return GS_SUCCESS;
	}
	if (n < 0)
	{
		if (WSAGetLastError() == WSAEWOULDBLOCK)
			return GS_SUCCESS;
		sess->done = 1;
		return GS_SUCCESS;
	}
	sess->local2gs_len = (size_t)n;
	return write_to_gs(ctx, sess);
}

static int
cb_write_local_ready_for_gs(GS_SELECT_CTX *ctx, int fd, void *arg, int val)
{
	(void)fd; (void)val;
	return write_to_gs(ctx, (struct session *)arg);
}

/* ---- direction: GS -> local socket ---- */

static int
write_to_local(GS_SELECT_CTX *ctx, struct session *sess)
{
	int n = send(sess->local_fd, (const char *)sess->gs2local_buf, (int)sess->gs2local_len, 0);

	if (n == (int)sess->gs2local_len)
	{
		sess->gs2local_len = 0;
		FD_SET(GS_get_fd(sess->gs), ctx->rfd);
		FD_CLR((int)sess->local_fd, ctx->wfd);
		return GS_SUCCESS;
	}
	if (n > 0)
	{
		memmove(sess->gs2local_buf, sess->gs2local_buf + n, sess->gs2local_len - n);
		sess->gs2local_len -= n;
		FD_CLR(GS_get_fd(sess->gs), ctx->rfd);
		FD_SET((int)sess->local_fd, ctx->wfd);
		return GS_ECALLAGAIN;
	}
	if ((n < 0) && (WSAGetLastError() == WSAEWOULDBLOCK))
	{
		FD_CLR(GS_get_fd(sess->gs), ctx->rfd);
		FD_SET((int)sess->local_fd, ctx->wfd);
		return GS_ECALLAGAIN;
	}

	/* local socket error: tear down this session */
	sess->done = 1;
	return GS_SUCCESS;
}

static int
cb_read_gs(GS_SELECT_CTX *ctx, int fd, void *arg, int val)
{
	struct session *sess = (struct session *)arg;
	(void)fd; (void)val;

	if (sess->gs2local_len != 0)
		return GS_SUCCESS;

	ssize_t len = GS_read(sess->gs, sess->gs2local_buf, sizeof sess->gs2local_buf);
	if (len == 0)
		return GS_ECALLAGAIN; /* would block */
	if (len == GS_ERR_EOF)
	{
		shutdown(sess->local_fd, SD_SEND);
		return GS_SUCCESS;
	}
	if (len < 0)
	{
		sess->done = 1;
		return GS_SUCCESS;
	}
	sess->gs2local_len = (size_t)len;
	return write_to_local(ctx, sess);
}

static int
cb_write_gs_ready_for_local(GS_SELECT_CTX *ctx, int fd, void *arg, int val)
{
	(void)fd; (void)val;
	return write_to_local(ctx, (struct session *)arg);
}

/* ---- per-session relay loop ---- */

static void
relay_session(GS_CTX *gs_ctx, GS *gs, SOCKET local_fd)
{
	/*
	 * static, not stack-local: with FD_SETSIZE bumped to 4096 (see
	 * win32-compat.h), GS_SELECT_CTX's internal per-fd arrays and these
	 * fd_sets total ~400KB - comfortably exceeds headroom on a default
	 * 1MB thread stack otherwise. Safe as static because sessions are
	 * handled strictly one at a time (never concurrently or recursively).
	 */
	static GS_SELECT_CTX sctx;
	static fd_set rfd, wfd, r, w;
	struct timeval tv_now;
	static struct session sess;

	memset(&sctx, 0, sizeof sctx);
	memset(&sess, 0, sizeof sess);
	sess.gs = gs;
	sess.local_fd = local_fd;

	FD_ZERO(&rfd); FD_ZERO(&wfd); FD_ZERO(&r); FD_ZERO(&w);
	GS_SELECT_CTX_init(&sctx, &rfd, &wfd, &r, &w, &tv_now, (int)GS_SEC_TO_USEC(1));
	GS_CTX_use_gselect(gs_ctx, &sctx);

	set_nonblock(local_fd);

	GS_SELECT_add_cb(&sctx, cb_read_local, cb_write_local_ready_for_gs, (int)local_fd, &sess, 0);
	GS_SELECT_add_cb(&sctx, cb_read_gs, cb_write_gs_ready_for_local, GS_get_fd(gs), &sess, 0);
	FD_SET((int)local_fd, sctx.rfd);
	FD_SET(GS_get_fd(gs), sctx.rfd);

	fprintf(stderr, "Session started.\n");
	while (!sess.done)
	{
		int n = GS_select(&sctx);
		GS_heartbeat(gs);
		if (n < 0)
			break;
	}
	fprintf(stderr, "Session ended.\n");

	GS_SELECT_del_cb(&sctx, (int)local_fd);
	GS_SELECT_del_cb(&sctx, GS_get_fd(gs));
}

/* ---- local TCP helpers (plain Winsock, no lib involvement) ---- */

static SOCKET
tcp_listen(const char *ip, int port)
{
	SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
	if (s == INVALID_SOCKET)
		die("socket(): %d\n", WSAGetLastError());

	int yes = 1;
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char *)&yes, sizeof yes);

	struct sockaddr_in sin;
	memset(&sin, 0, sizeof sin);
	sin.sin_family = AF_INET;
	sin.sin_port = htons((unsigned short)port);
	sin.sin_addr.s_addr = inet_addr(ip);

	if (bind(s, (struct sockaddr *)&sin, sizeof sin) != 0)
		die("bind(%s:%d): %d\n", ip, port, WSAGetLastError());
	if (listen(s, 8) != 0)
		die("listen(): %d\n", WSAGetLastError());

	return s;
}

static SOCKET
tcp_connect(const char *ip, int port)
{
	SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
	if (s == INVALID_SOCKET)
		return INVALID_SOCKET;

	struct sockaddr_in sin;
	memset(&sin, 0, sizeof sin);
	sin.sin_family = AF_INET;
	sin.sin_port = htons((unsigned short)port);
	sin.sin_addr.s_addr = inet_addr(ip);

	if (connect(s, (struct sockaddr *)&sin, sizeof sin) != 0)
	{
		closesocket(s);
		return INVALID_SOCKET;
	}
	return s;
}

/* ---- modes ---- */

static void
run_server(GS_CTX *gs_ctx, GS_ADDR *addr, const char *target_ip, int target_port)
{
	GS *listener = GS_new(gs_ctx, addr);
	if (listener == NULL)
		die("GS_new(): %s\n", GS_CTX_strerror(gs_ctx));

	if (GS_listen(listener, GS_MAX_SOX_BACKLOG) != 0)
		die("GS_listen(): %s\n", GS_strerror(listener));

	fprintf(stderr, "Listening on GSRN. Forwarding to %s:%d\n", target_ip, target_port);

	for (;;)
	{
		GS *gs = GS_accept(listener, NULL);
		if (gs == NULL)
		{
			fprintf(stderr, "GS_accept(): %s\n", GS_strerror(listener));
			continue;
		}

		SOCKET local_fd = tcp_connect(target_ip, target_port);
		if (local_fd == INVALID_SOCKET)
		{
			fprintf(stderr, "connect(%s:%d) failed: %d\n", target_ip, target_port, WSAGetLastError());
			GS_close(gs);
			continue;
		}

		relay_session(gs_ctx, gs, local_fd);

		closesocket(local_fd);
		GS_close(gs);
	}
}

static void
run_client(GS_CTX *gs_ctx, GS_ADDR *addr, int local_port)
{
	SOCKET listen_fd = tcp_listen("127.0.0.1", local_port);
	fprintf(stderr, "Listening on 127.0.0.1:%d. Forwarding via GSRN.\n", local_port);

	for (;;)
	{
		struct sockaddr_in peer;
		int peerlen = sizeof peer;
		SOCKET local_fd = accept(listen_fd, (struct sockaddr *)&peer, &peerlen);
		if (local_fd == INVALID_SOCKET)
			continue;

		GS *gs = GS_new(gs_ctx, addr);
		if (gs == NULL)
		{
			fprintf(stderr, "GS_new(): %s\n", GS_CTX_strerror(gs_ctx));
			closesocket(local_fd);
			continue;
		}

		if (GS_connect(gs) != 0)
		{
			fprintf(stderr, "GS_connect(): %s\n", GS_strerror(gs));
			closesocket(local_fd);
			GS_close(gs);
			continue;
		}

		relay_session(gs_ctx, gs, local_fd);

		closesocket(local_fd);
		GS_close(gs);
	}
}

static void
usage(const char *prog)
{
	fprintf(stderr,
		"Usage:\n"
		"  Listener/server:  %s -s <secret> -l -d <target-ip> -p <target-port>\n"
		"  Dialer/client:    %s -s <secret> -p <local-port>\n",
		prog, prog);
	exit(1);
}

int
main(int argc, char *argv[])
{
	const char *secret = NULL;
	const char *target_ip = "127.0.0.1";
	int port = 0;
	int is_server = 0;

	for (int i = 1; i < argc; i++)
	{
		if (!strcmp(argv[i], "-s") && i + 1 < argc)
			secret = argv[++i];
		else if (!strcmp(argv[i], "-l"))
			is_server = 1;
		else if (!strcmp(argv[i], "-d") && i + 1 < argc)
			target_ip = argv[++i];
		else if (!strcmp(argv[i], "-p") && i + 1 < argc)
			port = atoi(argv[++i]);
		else
			usage(argv[0]);
	}
	if ((secret == NULL) || (port == 0))
		usage(argv[0]);

	WSADATA wsa;
	if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0)
		die("WSAStartup() failed\n");

	GS_library_init(stderr, stderr, NULL);

	GS_CTX gs_ctx;
	static fd_set rfd, wfd, r, w; /* see relay_session() comment: FD_SETSIZE=4096 makes these too large for a stack frame */
	struct timeval tv_now;
	FD_ZERO(&rfd); FD_ZERO(&wfd); FD_ZERO(&r); FD_ZERO(&w);
	GS_CTX_init(&gs_ctx, &rfd, &wfd, &r, &w, &tv_now);
	GS_CTX_setsockopt(&gs_ctx, GS_OPT_BLOCK, NULL, 0); /* GS objects default to non-blocking; we call GS_accept()/GS_connect() in bare loops */

	GS_ADDR addr;
	if (GS_ADDR_sec2addr(&addr, secret) == NULL)
		die("GS_ADDR_sec2addr(): %s\n", GS_CTX_strerror(&gs_ctx));

	if (is_server)
		run_server(&gs_ctx, &addr, target_ip, port);
	else
		run_client(&gs_ctx, &addr, port);

	WSACleanup();
	return 0;
}
