/* Stub implementations - see stubs.h for what's deliberately not ported. */
#include "common.h"
#include "stubs.h"

GS_CONDIS gs_condis; /* upstream: defined in console.c; referenced by pkt_mgr.c */

/*
 * lib/gsocket-util.c guards the real GS_getpidwd() out entirely on _WIN32
 * ("not implemented, unused by gs-tunnel" - true until this gs-netcat port
 * needed it for the "pwd" command). Rather than touch that shared, already-
 * verified file, provide it here. Best-effort only: there's no /proc on
 * Windows to read a remote process's *live* working directory, so this
 * reports gs-netcat's own cwd (matches the spawned shell's initial
 * directory, but won't track `cd` commands typed inside that shell).
 */
char *
GS_getpidwd(pid_t pid)
{
	(void)pid;
	char *wd = _getcwd(NULL, 0);
	return wd != NULL ? wd : strdup("?");
}

/* ---- console.c stand-ins: transparent passthrough, no local UI ---- */
ssize_t
CONSOLE_write(int fd, void *data, size_t len)
{
	return write(fd, data, len);
}

int
CONSOLE_check_esc(uint8_t c, uint8_t *submit)
{
	(void)c;
	(void)submit;
	return -1; /* never matches an escape sequence; byte passes through untouched */
}

int
CONSOLE_action(struct _peer *p, uint8_t key)
{
	(void)p;
	(void)key;
	return 0;
}

int
CONSOLE_command(struct _peer *p, const char *cmd)
{
	(void)p;
	(void)cmd;
	return 0;
}

void
CONSOLE_reset(void)
{
}

void
CONSOLE_resize(struct _peer *p)
{
	(void)p;
}

int
CONSOLE_readline(struct _peer *p, void *data, size_t len)
{
	(void)p;
	(void)data;
	(void)len;
	return 0; /* never intercepted; caller treats data as normal payload */
}

void
CONSOLE_draw(int fd)
{
	(void)fd;
}

void
CONSOLE_update_pinginfo(struct _peer *p, float ms, int load, char *active_user, int sec_idle, uint8_t n_users)
{
	(void)p; (void)ms; (void)load; (void)active_user; (void)sec_idle; (void)n_users;
}

void
CONSOLE_update_bps(struct _peer *p)
{
	(void)p;
}

/* ---- ids.c stand-ins: no multi-user login tracking ---- */
void
GS_IDS_utmp(GS_LIST *new_login, GS_LIST *new_active, char **least_idle, int *sec_idle, int *n_users)
{
	GS_LIST_init(new_login, 0);
	GS_LIST_init(new_active, 0);
	*least_idle = NULL;
	*sec_idle = 0;
	*n_users = 0;
}

void
ids_gs_login(struct _peer *self_peer)
{
	(void)self_peer;
}

void
ids_gs_logout(struct _peer *self_peer)
{
	(void)self_peer;
}

/* ---- filetransfer_mgr.c stand-ins: in-band file transfer not ported ---- */
void
GS_FTM_init(struct _peer *p, int is_server)
{
	(void)p;
	(void)is_server;
}

void
GS_FTM_free(struct _peer *p)
{
	(void)p;
}

ssize_t
GS_FTM_mk_packet(GS_FT *ft, uint8_t *dst, size_t dlen)
{
	(void)ft;
	(void)dst;
	(void)dlen;
	return 0; /* "no data available", matches pkt_app_send_ft()'s success-no-op path */
}

/* ---- console_display.c stand-ins: GS_CONDIS backing store, unused since
 * the console that would read it (CONSOLE_draw) is itself a no-op above ---- */
int
GS_condis_init(GS_CONDIS *cd, int fd, int rows)
{
	memset(cd, 0, sizeof *cd);
	cd->fd = fd;
	cd->rows = rows;
	return 0;
}

void
GS_condis_add(GS_CONDIS *cd, int color, const char *str)
{
	(void)cd; (void)color; (void)str;
}

void
GS_condis_printf(GS_CONDIS *cd, int color, const char *fmt, ...)
{
	(void)cd; (void)color; (void)fmt;
}

void
GS_condis_log(GS_CONDIS *cd, int color, const char *str)
{
	(void)cd; (void)color; (void)str;
}

void
GS_condis_pos(GS_CONDIS *cd, int y, int maxlen)
{
	(void)cd; (void)y; (void)maxlen;
}

void
GS_condis_draw(GS_CONDIS *cd, int force)
{
	(void)cd; (void)force;
}

void
GS_condis_up(GS_CONDIS *cd)
{
	(void)cd;
}

void
GS_condis_down(GS_CONDIS *cd)
{
	(void)cd;
}

void
GS_condis_clear(GS_CONDIS *cd)
{
	(void)cd;
}
