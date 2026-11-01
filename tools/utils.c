/*
 * Windows/MSVC port of upstream tools/utils.c.
 *
 * Ported as-is: add_env_argv, init_defaults (minus POSIX privilege-drop,
 * irrelevant on Windows), gs_create, cb_sigterm, cb_gs_log, init_vars,
 * usage, zap_arg, do_getopt, stty_check_esc, fd_net_*, cmd_ping, cmd_pwd.
 *
 * Replaced with Windows-native equivalents: get_winsize (console API),
 * stty_set_raw/stty_reset (console mode, VT sequences), fd_cmd (delegates
 * to win_childproc.c's ConPTY/pipe bridge), getcwdx (_getcwd).
 *
 * Dropped (see common.h/mk_shellname callers): the openpty/forkpty/forkfd/
 * pty_cmd/setup_cmd_child/mk_shellname cluster - entirely replaced by
 * win_childproc.c, which doesn't need any of their logic since Windows
 * process spawning (CreateProcess) looks nothing like fork+exec.
 * gs_watchdog (-D/-W daemon/watchdog mode): not supported on this port -
 * see the ERREXIT below for why and what to use instead.
 */

#include "common.h"
#include "utils.h"
#include "win_childproc.h"

static void
add_env_argv(int *argcptr, char **argvptr[])
{
	char *str_orig = GS_getenv("GSOCKET_ARGS");
	if (str_orig == NULL)
		str_orig = GS_getenv("GS_ARGS");
	char *str = NULL;
	char *next;
	char **newargv = NULL;
	int newargc;

	if (str_orig == NULL)
		return;

	str = strdup(str_orig);
	next = str;

	newargv = malloc(1 * sizeof *argvptr);
	memcpy(&newargv[0], argvptr[0], 1 * sizeof *argvptr);
	newargc = 1;

	while (next != NULL)
	{
		while (*str == ' ')
			str++;

		next = strchr(str, ' ');
		if (next != NULL)
		{
			*next = 0;
			next++;
		}
		if (strlen(str) > 0)
		{
			newargc++;
			newargv = realloc(newargv, newargc * sizeof newargv);
			newargv[newargc - 1] = str;
		}

		str = next;
		if (str == NULL)
			break;
	}

	newargv = realloc(newargv, (newargc + *argcptr) * sizeof newargv);
	memcpy(newargv + newargc, *argvptr + 1, (*argcptr - 1) * sizeof *argvptr);

	newargc += (*argcptr - 1);
	newargv[newargc] = NULL;

	*argcptr = newargc;
	*argvptr = newargv;
}

void
init_defaults(int *argcptr, char **argvptr[])
{
#ifdef DEBUG
	gopt.is_built_debug = 1;
#endif
	gopt.log_fp = stderr;
	gopt.err_fp = stderr;
	gopt.prg_name = NULL;
	if (argvptr != NULL)
	{
		gopt.prg_name = *argvptr[0];

		if ((gopt.prg_name != NULL) && (gopt.prg_name[0] == '/'))
		{
			char *ptr;
			ptr = strrchr(gopt.prg_name, '/');
			if (ptr != NULL)
				gopt.prg_name = ptr + 1;
		}
		if (gopt.prg_name != NULL)
			gopt.prg_name = strdup(gopt.prg_name);
	}

	/* Upstream also does FD_SETSIZE rlimit raising and euid/egid drop here;
	 * both are POSIX-process-model concepts with no Windows equivalent and
	 * not relevant to a console tool run directly by its own user. */

	add_env_argv(argcptr, argvptr);

	gopt.app_keepalive_sec = GS_APP_KEEPALIVE;
}

GS *
gs_create(void)
{
	GS *gs = GS_new(&gopt.gs_ctx, &gopt.gs_addr);
	XASSERT(gs != NULL, "%s\n", GS_CTX_strerror(&gopt.gs_ctx));

	if (gopt.token_str != NULL)
		GS_set_token(gs, gopt.token_str, strlen(gopt.token_str));

	return gs;
}

static void
cb_sigterm(int sig)
{
	(void)sig;
	exit(EX_SIGTERM);
}

/*
 * Windows: query the real console's buffer size. Falls back to 80x24 if
 * stdout isn't a console (redirected/piped), same as upstream's ioctl
 * failure fallback.
 */
void
get_winsize(void)
{
	memcpy(&gopt.winsize_prev, &gopt.winsize, sizeof gopt.winsize_prev);

	CONSOLE_SCREEN_BUFFER_INFO info;
	HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
	if ((h != INVALID_HANDLE_VALUE) && GetConsoleScreenBufferInfo(h, &info))
	{
		gopt.winsize.ws_col = (unsigned short)(info.srWindow.Right - info.srWindow.Left + 1);
		gopt.winsize.ws_row = (unsigned short)(info.srWindow.Bottom - info.srWindow.Top + 1);
	} else {
		gopt.winsize.ws_col = 80;
		gopt.winsize.ws_row = 24;
	}
}

static void
cb_gs_log(struct _gs_log_info *l)
{
	if (l == NULL)
		return;

#ifndef DEBUG
	if (l->type == GS_LOG_TYPE_DEBUG)
		return;
#endif

	FILE *fp = gopt.log_fp;
	if (l->type == GS_LOG_TYPE_ERROR)
		fp = gopt.err_fp;

	if (fp == NULL)
		return;

	if (l->level > gopt.verbosity)
		return;

	fprintf(fp, "%s", l->msg);
	fflush(fp);
}

void
init_vars(void)
{
	GS_library_init(gopt.err_fp, gopt.err_fp, cb_gs_log);
	GS_LIST_init(&gopt.ids_peers, 0);
	GS_CTX_init(&gopt.gs_ctx, &gopt.rfd, &gopt.wfd, &gopt.r, &gopt.w, &gopt.tv_now);

	if (gopt.is_use_tor == 1)
		GS_CTX_setsockopt(&gopt.gs_ctx, GS_OPT_USE_SOCKS, NULL, 0);
	if (gopt.is_sock_wait != 0)
		GS_CTX_setsockopt(&gopt.gs_ctx, GS_OPT_SOCKWAIT, NULL, 0);
	if (gopt.is_client_or_server != 0)
		GS_CTX_setsockopt(&gopt.gs_ctx, GS_OPT_CLIENT_OR_SERVER, NULL, 0);
	if (gopt.is_no_encryption == 1)
		GS_CTX_setsockopt(&gopt.gs_ctx, GS_OPT_NO_ENCRYPTION, NULL, 0);
	if (gopt.is_blocking == 1)
		GS_CTX_setsockopt(&gopt.gs_ctx, GS_OPT_BLOCK, NULL, 0);
	if (gopt.is_multi_peer == 0)
		GS_CTX_setsockopt(&gopt.gs_ctx, GS_OPT_SINGLESHOT, NULL, 0);
	if (gopt.is_interactive != 0)
		GS_CTX_setsockopt(&gopt.gs_ctx, GS_OPT_LOW_LATENCY, NULL, 0);
	if (gopt.gs_server_check_sec > 0)
		GS_CTX_setsockopt(&gopt.gs_ctx, GS_OPT_SERVER_CHECK, NULL, 0);

	gopt.is_greetings = 1;
	if (GS_getenv("GSOCKET_NO_GREETINGS") != NULL)
		gopt.is_greetings = 0;

	char *gs_args = GS_getenv("GSOCKET_ARGS");
	if (gs_args == NULL)
		gs_args = GS_getenv("GS_ARGS");

	int is_sec_by_prompt = 0;
	if ((gopt.sec_file == NULL) && (gopt.sec_str == NULL))
		is_sec_by_prompt = 1;

	if (gs_args != NULL)
		GS_LOG_V("=Extra arguments: '%s'\n", gs_args);

	if ((gopt.is_quiet) && (!is_sec_by_prompt))
		gopt.is_greetings = 0;

	gopt.sec_str = GS_user_secret(&gopt.gs_ctx, gopt.sec_file, gopt.sec_str);
	if (gopt.sec_str == NULL)
		ERREXIT("%s\n", GS_CTX_strerror(&gopt.gs_ctx));

	if (gopt.is_greetings)
		GS_LOG("=Secret         : %s\n", gopt.sec_str);

	GS_ADDR_sec2addr(&gopt.gs_addr, gopt.sec_str);

	GS_LOG_V("=GS Address     : %s\n", GS_addr2hex(NULL, gopt.gs_addr.addr));

	gopt.is_stdin_a_tty = isatty(STDIN_FILENO);
	if ((gopt.is_interactive && !(gopt.flags & GSC_FL_IS_SERVER) && !gopt.is_stdin_a_tty))
		gopt.is_stdin_ignore_eof = 1;

	signal(SIGTERM, cb_sigterm);
}

void
usage(const char *params)
{
	fprintf(stderr, "Version %s%s, %s %s [%s]\n", PACKAGE_VERSION, gopt.is_built_debug?"#debug":"", __DATE__, __TIME__, OPENSSL_VERSION_TEXT);

	while (*params)
	{
		switch (params[0])
		{
			case 'L': fprintf(stderr, "  -L <file>    Logfile\n"); break;
			case 'q': fprintf(stderr, "  -q           Quiet. No log output\n"); break;
			case 'v': fprintf(stderr, "  -v           Verbose. -vv more verbose. -vvv insanely verbose\n"); break;
			case 'r': fprintf(stderr, "  -r           Receive-only. Terminate when no more data.\n"); break;
			case 'I': fprintf(stderr, "  -I           Ignore EOF on stdin.\n"); break;
			case 's': fprintf(stderr, "  -s <secret>  Secret (e.g. password).\n"); break;
			case 'k': fprintf(stderr, "  -k <file>    Read Secret from file.\n"); break;
			case 'l': fprintf(stderr, "  -l           Listening server [default: client]\n"); break;
			case 'g': fprintf(stderr, "  -g           Generate a Secret (random)\n"); break;
			case 'a': fprintf(stderr, "  -a <token>   Set listen password\n"); break;
			case 'w': fprintf(stderr, "  -w           Wait for server to become available [client only]\n"); break;
			case 'A': fprintf(stderr, "  -A           Be server if no server is listening\n"); break;
			case 'C': fprintf(stderr, "  -C           Disable encryption\n"); break;
			case 'T': fprintf(stderr, "  -T           Use TOR or any Socks proxy (See gs-netcat(1))\n"); break;
		}
		params++;
	}
}

static void
zap_arg(char *str)
{
	memset(str, '*', strlen(str));
}

char *
getcwdx(void)
{
	return gs_getcwdx_win();
}

void
do_getopt(int argc, char *argv[])
{
	int c;
	opterr = 0;
	while ((c = getopt(argc, argv, UTILS_GETOPT_STR)) != -1)
	{
		switch (c)
		{
			case 'v': gopt.verbosity += 1; break;
			case 'L':
				gopt.is_logfile = 1;
				gopt.log_fp = fopen(optarg, "a");
				if (gopt.log_fp == NULL)
					ERREXIT("fopen(%s): %s\n", optarg, strerror(errno));
				gopt.err_fp = gopt.log_fp;
				break;
			case 'T': gopt.is_use_tor = 1; break;
			case 'q': gopt.is_quiet = 1; break;
			case 'r': gopt.is_receive_only = 1; break;
			case 'I': gopt.is_stdin_ignore_eof = 1; break;
			case 'i': gopt.is_interactive = 1; break;
			case 'C': gopt.is_no_encryption = 1; break;
			case 'A': gopt.is_client_or_server = 1; break;
			case 'w': gopt.is_sock_wait = 1; break;
			case 'a':
				GS_LOG("*** WARNING *** -a not fully supported yet. Trying our best...\n");
				gopt.token_str = optarg;
				break;
			case 'l': gopt.flags |= GSC_FL_IS_SERVER; break;
			case 's': gopt.sec_str = strdup(optarg); zap_arg(optarg); break;
			case 'k': gopt.sec_file = strdup(optarg); zap_arg(optarg); break;
			case 'g':
				printf("%s\n", GS_gen_secret());
				fflush(stdout);
				exit(0);
			case '3':
				if (strcmp(optarg, "1337") == 0)
					GS_LOG("!!Greets to 0xD1G, xaitax and the rest of https://t.me/thcorg!!\n");
				break;
		}
	}
}

/*
 * Windows: toggle the console's input/output mode to get raw, VT-passthrough
 * behavior, instead of POSIX termios. Equivalent intent to upstream's
 * ICANON/ECHO/ISIG-stripping tcsetattr() call.
 */
static DWORD saved_in_mode, saved_out_mode;
static int is_stty_raw;
static int is_stty_nopty;

void
stty_set_raw(void)
{
	if (is_stty_raw != 0)
		return;

	HANDLE hIn = GetStdHandle(STD_INPUT_HANDLE);
	HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
	if (!isatty(STDIN_FILENO))
		return;

	GetConsoleMode(hIn, &saved_in_mode);
	GetConsoleMode(hOut, &saved_out_mode);

	DWORD in_mode = saved_in_mode;
	in_mode &= ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
	in_mode |= ENABLE_VIRTUAL_TERMINAL_INPUT;
	SetConsoleMode(hIn, in_mode);

	DWORD out_mode = saved_out_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING | ENABLE_PROCESSED_OUTPUT;
	SetConsoleMode(hOut, out_mode);

	is_stty_raw = 1;
}

void
stty_switch_nopty(void)
{
	if (is_stty_nopty != 0)
		return;
	if (is_stty_raw == 0)
		return;
	if (!isatty(STDIN_FILENO))
		return;

	printf("\r=No PTY on remote. Using dump terminal instead.\r\n");
	is_stty_nopty = 1;
}

void
stty_reset(void)
{
	if (is_stty_raw == 0)
		return;

	is_stty_raw = 0;
	is_stty_nopty = 0;
	SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), saved_in_mode);
	SetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), saved_out_mode);
}

static const char esc_seq[] = "\r~.\r";
static int esc_pos;
void
stty_check_esc(GS *gs, char c)
{
	(void)gs;
	if (c == esc_seq[esc_pos])
	{
		esc_pos++;
		if (esc_pos < sizeof esc_seq - 1)
			return;

		stty_reset();
		exit(0);
		return;
	}
	esc_pos = 0;
	if (c == esc_seq[0])
		esc_pos = 1;
}

/*
 * Windows: is_pty_failed only happens if ConPTY setup itself failed, which
 * means there is no real PTY to signal Ctrl-C into (unlike upstream's /proc
 * foreground-process hack, there's also no Windows equivalent worth
 * building for this rare fallback path). Best-effort: ask the process to
 * stop via its console control handler.
 */
void
ctrl_c_child(pid_t pid)
{
	GenerateConsoleCtrlEvent(CTRL_C_EVENT, (DWORD)pid);
}

int
fd_cmd(const char *cmd, pid_t *pidptr, int *err)
{
	return win_fd_cmd(cmd, pidptr, err);
}

int
fd_net_connect(GS_SELECT_CTX *ctx, int fd, uint32_t ip, uint16_t port)
{
	struct sockaddr_in addr;
	int ret;

	memset(&addr, 0, sizeof addr);
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = ip;
	addr.sin_port = port;
	ret = connect(fd, (struct sockaddr *)&addr, sizeof addr);
	if (ret != 0)
	{
		if ((errno == EINPROGRESS) || (errno == EAGAIN) || (errno == EINTR))
		{
			XFD_SET(fd, ctx->wfd);
			return -1;
		}
		if (errno != EISCONN)
			return -2;
	}

	return 0;
}

int
fd_net_accept(int listen_fd)
{
	int sox = accept(listen_fd, NULL, NULL);
	if (sox < 0)
		return -2;

	gs_win_set_nonblock(sox, 1);
	return sox;
}

int
fd_net_listen(int fd, uint16_t *port, int type)
{
	struct sockaddr_in addr;
	int ret;
	int is_random_port = 0;
	int reuse = 1;

	if ((port == NULL) || (*port == 0))
		is_random_port = 1;

	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse, sizeof reuse);

	memset(&addr, 0, sizeof addr);
	addr.sin_family = AF_INET;
	if (is_random_port == 0)
	{
		addr.sin_port = *port;
		addr.sin_addr.s_addr = htonl(INADDR_ANY);
	} else {
		addr.sin_addr.s_addr = inet_addr("127.0.0.1");
	}

	ret = bind(fd, (struct sockaddr *)&addr, sizeof addr);
	if (ret < 0)
		return ret;

	if (is_random_port)
	{
		struct sockaddr_in paddr;
		socklen_t plen = sizeof paddr;
		getsockname(fd, (struct sockaddr *)&paddr, &plen);
		*port = paddr.sin_port;
	}

	if (type == SOCK_STREAM)
	{
		ret = listen(fd, 1);
		if (ret != 0)
			return -1;
	}

	return 0;
}

int
fd_new_socket(int type)
{
	int fd = socket(PF_INET, type, 0);
	if (fd < 0)
		return -2;

	gs_win_set_nonblock(fd, 1);
	return fd;
}

void
fd_kernel_flush(int fd)
{
	(void)fd; /* TIOCOUTQ has no Windows equivalent; nothing to flush for a socket here */
}

void
cmd_ping(struct _peer *p)
{
	if (p->is_want_ping != 0)
		return;

	p->is_want_ping = 1;
	GS_SELECT_FD_SET_W(p->gs);
}

void
cmd_pwd(struct _peer *p)
{
	if (gopt.is_want_pwd != 0)
		return;

	gopt.is_want_pwd = 1;
	GS_SELECT_FD_SET_W(p->gs);
}

void
gs_watchdog(void)
{
	ERREXIT("Daemon/watchdog mode (-D/-W) is not supported in this Windows port "
		"(it relies on POSIX fork()-based auto-restart). Run gs-netcat.exe "
		"directly; wrap it in a Scheduled Task or Windows Service if you "
		"need it to restart automatically.\n");
}
