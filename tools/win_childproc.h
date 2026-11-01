#ifndef __WIN_CHILDPROC_H__
#define __WIN_CHILDPROC_H__ 1

/*
 * Windows replacement for the POSIX fork()/openpty()/forkpty()/socketpair()
 * cluster in upstream utils.c. There is no select()-able "pipe" handle on
 * Windows (Winsock's select() only works on SOCKETs), so every non-socket
 * I/O endpoint we need to multiplex into the existing socket-based GS_SELECT
 * loop - a spawned child's ConPTY/pipes, or our own real console - is bridged
 * into a loopback TCP socket pair by a pair of pump threads. The rest of the
 * ported code (gs-netcat.c, pkt_mgr.c, ...) only ever sees a plain socket fd
 * and never knows the difference.
 *
 * Teardown is driven entirely by the caller closing the returned fd (via the
 * existing XCLOSE()/close() path) - that alone unwinds the child process and
 * all handles. No separate explicit cleanup call is required.
 */

#include <sys/types.h> /* pid_t */

/* Spawn a child (PTY-backed if is_interactive, else plain pipes) and return
 * a bridged socket fd for its combined stdin/stdout/stderr. Mirrors upstream
 * fd_cmd()'s signature/semantics exactly, including the is_interactive check.
 * *err is set to GS_FD_CMD_ERR_NOPTY if ConPTY setup failed and we fell back
 * to a plain (non-PTY) pipe, matching upstream's forkpty-fails fallback. */
int win_fd_cmd(const char *cmd, pid_t *pidptr, int *err);

/* Bridge our own real console's STDIN/STDOUT into a single bridged socket fd.
 * Used wherever upstream hardcodes STDIN_FILENO/STDOUT_FILENO as the local
 * fd (plain stdin-forward client, or the stdin/stdout fallback server mode). */
int win_stdio_bridge_fd(void);

/* Apply a terminal resize (from the client's PKT_MSG_WSIZE) to the ConPTY
 * backing the given bridged fd, if there is one. No-op otherwise. */
void win_pty_resize(int fd, int cols, int rows);

#endif /* !__WIN_CHILDPROC_H__ */
