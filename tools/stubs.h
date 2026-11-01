#ifndef __GSNC_WIN_STUBS_H__
#define __GSNC_WIN_STUBS_H__ 1

/*
 * This Windows port deliberately does NOT port three upstream subsystems,
 * each a separate large POSIX-coupled feature orthogonal to the 5 target
 * modes (port-forward, exec, interactive shell, SOCKS, file-transfer via
 * simple redirection):
 *
 *  - console.c (1614 lines): the live admin UI overlay (^E escape menu,
 *    multi-peer status bar/"EEElite-console"). Stubbed to transparent
 *    passthrough below - data still flows normally, there's just no local
 *    escape-key menu. To end an interactive session, close the window/Ctrl-C
 *    the local process, or let the remote shell exit.
 *  - ids.c (299 lines): utmp-based "who else is logged in" alerting between
 *    multiple interactive peers. Meaningless for this port's use case (a
 *    tunnel between orchestration nodes you control) - stubbed to no-ops.
 *  - filetransfer.c/filetransfer_mgr.c/globbing.c (~2800 lines): the in-band
 *    multi-file transfer-with-resume protocol driven by typing "!send"/
 *    "!recv" into the (stubbed-out) console. NOT ported. Basic whole-stream
 *    file transfer still works via plain redirection (same as gs-tunnel.exe),
 *    since that path never touches this code at all.
 *
 * All struct/function shapes below are kept because struct _peer embeds
 * GS_PKT/GS_FT fields and pkt_mgr.c calls a handful of these unconditionally;
 * stubbing them (rather than #ifdef'ing out every call site) keeps the
 * ported gs-netcat.c/pkt_mgr.c/event_mgr.c nearly line-for-line identical
 * to upstream, which made porting those files mostly mechanical.
 */

#include "console_display.h"	/* GS_CONDIS - real upstream header, no POSIX content */

/* ---- console.h stand-in ---- */
#define GS_CONSOLE_ESC	    0x05
#define GS_CONSOLE_ESC_CHR  'E'
#define GS_CONSOLE_ESC_LCHR 'e'
#define GS_CONSOLE_ESC_STR  "^E"
#define GS_CONSOLE_ROWS     (8)

ssize_t CONSOLE_write(int fd, void *data, size_t len);
int CONSOLE_check_esc(uint8_t c, uint8_t *submit);
int CONSOLE_action(struct _peer *p, uint8_t key);
int CONSOLE_command(struct _peer *p, const char *cmd);
void CONSOLE_reset(void);
void CONSOLE_resize(struct _peer *p);
int CONSOLE_readline(struct _peer *p, void *data, size_t len);
void CONSOLE_draw(int fd);
void CONSOLE_update_pinginfo(struct _peer *p, float ms, int load, char *active_user, int sec_idle, uint8_t n_users);
void CONSOLE_update_bps(struct _peer *p);

/* ---- ids.h stand-in ---- */
void GS_IDS_utmp(GS_LIST *new, GS_LIST *new_active, char **least_idle, int *sec_idle, int *n_users);
void ids_gs_login(struct _peer *self_peer);
void ids_gs_logout(struct _peer *self_peer);

/* ---- filetransfer.h stand-in (only what struct _peer / pkt_mgr.c need) ---- */
typedef struct
{
	int dummy; /* real upstream GS_FT carries file-queue state; unused here */
} GS_FT;

#define GS_FT_pause_data(ft)    do {} while (0)
#define GS_FT_unpause_data(ft)  do {} while (0)
#define GS_FT_WANT_WRITE(ft)    (0)

/* ---- filetransfer_mgr.h stand-in ---- */
void GS_FTM_init(struct _peer *p, int is_server);
void GS_FTM_free(struct _peer *p);
ssize_t GS_FTM_mk_packet(GS_FT *ft, uint8_t *dst, size_t dlen);

#endif /* !__GSNC_WIN_STUBS_H__ */
