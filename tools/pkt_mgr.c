/*
 * Windows port of upstream tools/pkt_mgr.c. Line-for-line identical except:
 *  - pkt_app_cb_wsize: ioctl(TIOCGWINSZ/TIOCSWINSZ) on the PTY -> ConPTY
 *    resize via win_pty_resize() (see win_childproc.c).
 *  - pkt_app_send_pong: getloadavg() has no Windows equivalent; reports 0
 *    load (this feeds only the stubbed admin console's status display).
 */
#include "common.h"
#include "pkt_mgr.h"
#include "event_mgr.h"
#include "utils.h"
#include "gs-netcat.h"
#include "win_childproc.h"

extern GS_CONDIS gs_condis; /* defined in stubs.c */

void
pkt_app_cb_wsize(uint8_t msg, const uint8_t *data, size_t len, void *ptr)
{
	struct _peer *p = (struct _peer *)ptr;
	uint16_t col, row;

	memcpy(&col, data, 2);
	memcpy(&row, data + 2, 2);
	col = ntohs(col);
	row = ntohs(row);

	win_pty_resize(p->fd_in, col, row);
}

void
pkt_app_cb_ping(uint8_t msg, const uint8_t *data, size_t len, void *ptr)
{
	struct _peer *p = (struct _peer *)ptr;
	gopt.is_pong_pending = 1;
	GS_SELECT_FD_SET_W(p->gs);
}

void
pkt_app_cb_pong(uint8_t msg, const uint8_t *data, size_t len, void *ptr)
{
	struct _peer *p = (struct _peer *)ptr;
	struct _pkt_app_pong pong;
	if (gopt.ts_ping_sent == 0)
		return;

	memcpy(&pong, data, sizeof pong);

	float ms = (float)(GS_TV_TO_USEC(&gopt.tv_now) - gopt.ts_ping_sent) / 1000;

	uint8_t buf[sizeof (pong.user) + 1];
	memcpy(buf, pong.user, sizeof pong.user);
	GS_sanitize_fname_str((char *)buf, sizeof buf);

	CONSOLE_update_pinginfo(p, ms, ntohs(pong.load), (char *)buf, ntohs(pong.idle), pong.n_users);

	gopt.ts_ping_sent = 0;
}

void
pkt_app_cb_log(uint8_t msg, const uint8_t *data, size_t len, void *ptr)
{
	struct _pkt_app_log *log = (struct _pkt_app_log *)data;

	GS_sanitize_fname_str((char *)log->msg, sizeof log->msg);
	GS_condis_log(&gs_condis, log->type, (const char *)log->msg);
	CONSOLE_draw(gs_condis.fd);
}

void
pkt_app_cb_status(uint8_t msg, const uint8_t *data, size_t len, void *ptr)
{
	struct _pkt_app_status *status = (struct _pkt_app_status *)data;

	if (status->type == GS_PKT_APP_STATUS_TYPE_NOPTY)
		stty_switch_nopty();
}

void
pkt_app_cb_ids(uint8_t msg, const uint8_t *data, size_t len, void *ptr)
{
	struct _peer *p = (struct _peer *)ptr;

	if (p->ids_li != NULL)
		return;

	p->ids_li = GS_LIST_add(&gopt.ids_peers, NULL, p, 0);
	if (gopt.event_ids == NULL)
	{
		gopt.event_ids = GS_EVENT_add_by_ts(&p->gs->ctx->gselect_ctx->emgr, NULL, 0, GS_APP_IDSFREQ, cbe_ids, NULL, 0);
		cbe_ids(NULL);
	}
}

void
pkt_app_cb_pwdrequest(uint8_t msg, const uint8_t *dataUNUSED, size_t lenUNUSED, void *ptr)
{
	struct _peer *p = (struct _peer *)ptr;

	gopt.is_pwdreply_pending = 1;
	GS_SELECT_FD_SET_W(p->gs);
}

void
pkt_app_cb_pwdreply(uint8_t chn, const uint8_t *data, size_t len, void *ptr)
{
	if (len <= 0)
		return;
	if (data[len - 1] != '\0')
		return;

	GS_condis_add(&gs_condis, GS_PKT_APP_LOG_TYPE_DEFAULT, (char *)data);
	CONSOLE_draw(gs_condis.fd);
}

int
pkt_app_send_wsize(GS_SELECT_CTX *ctx, struct _peer *p, int row)
{
	p->wbuf[0] = GS_PKT_ESC;
	p->wbuf[1] = PKT_MSG_WSIZE;
	uint16_t c, r;
	c = htons(gopt.winsize.ws_col);
	r = htons(row);
	memcpy(p->wbuf + 2, &c, 2);
	memcpy(p->wbuf + 4, &r, 2);
	p->wlen = 2 + GS_PKT_MSG_size_by_type(PKT_MSG_WSIZE);
	return write_gs(ctx, p, NULL);
}

int
pkt_app_send_pong(GS_SELECT_CTX *ctx, struct _peer *p)
{
	uint16_t l = 0; /* no getloadavg() on Windows; feeds only the stubbed console */
	struct _pkt_app_pong pong;

	p->wbuf[0] = GS_PKT_ESC;
	p->wbuf[1] = PKT_MSG_PONG;

	memset(&pong, 0, sizeof pong);
	pong.load = htons(l);
	pong.idle = htons(gopt.ids_idle);
	pong.n_users = (uint8_t)MIN(255, gopt.n_users);
	if (gopt.ids_active_user != NULL)
		snprintf((char *)pong.user, sizeof pong.user, "%s", gopt.ids_active_user);

	memcpy(p->wbuf + 2, &pong, sizeof pong);

	p->wlen = 2 + GS_PKT_MSG_size_by_type(PKT_MSG_PONG);
	return write_gs(ctx, p, NULL);
}

int
pkt_app_send_ping(GS_SELECT_CTX *ctx, struct _peer *p)
{
	struct _pkt_app_ping ping;
	struct timeval tv;

	p->wbuf[0] = GS_PKT_ESC;
	p->wbuf[1] = PKT_MSG_PING;

	gettimeofday(&tv, NULL);
	gopt.ts_ping_sent = GS_TV_TO_USEC(&tv);

	memset(&ping, 0, sizeof ping);
	memcpy(p->wbuf + 2, &ping, sizeof ping);

	p->wlen = 2 + GS_PKT_MSG_size_by_type(PKT_MSG_PING);
	return write_gs(ctx, p, NULL);
}

int
pkt_app_send_ids(GS_SELECT_CTX *ctx, struct _peer *p)
{
	struct _pkt_app_ids ids;

	p->wbuf[0] = GS_PKT_ESC;
	p->wbuf[1] = PKT_MSG_IDS;

	memset(&ids, 0, sizeof ids);
	ids.flags = GS_PKT_APP_FL_IDS;

	memcpy(p->wbuf + 2, &ids, sizeof ids);
	p->wlen = 2 + GS_PKT_MSG_size_by_type(PKT_MSG_IDS);
	return write_gs(ctx, p, NULL);
}

int
pkt_app_send_pwdrequest(GS_SELECT_CTX *ctx, struct _peer *p)
{
	p->wbuf[0] = GS_PKT_ESC;
	p->wbuf[1] = PKT_MSG_PWD;
	p->wlen = 2 + GS_PKT_MSG_size_by_type(PKT_MSG_PWD);
	return write_gs(ctx, p, NULL);
}

int
pkt_app_send_pwdreply(GS_SELECT_CTX *ctx, struct _peer *p)
{
	struct gs_pkt_chn_hdr *hdr = (struct gs_pkt_chn_hdr *)p->wbuf;

	hdr->esc = GS_PKT_ESC;
	hdr->type = GS_PKT_CHN2TYPE(GS_CHN_PWD);

	char *wd = GS_getpidwd(p->pid);
	snprintf((char *)p->wbuf + sizeof *hdr, sizeof p->wbuf - sizeof *hdr, "%s", wd);
	size_t sz = strlen(wd) + 1;
	XFREE(wd);

	uint16_t len = htons((uint16_t)sz);
	memcpy(&hdr->len, &len, sizeof len);

	p->wlen = sizeof *hdr + sz;
	return write_gs(ctx, p, NULL);
}

int
pkt_app_send_ft(GS_SELECT_CTX *ctx, struct _peer *p)
{
	ssize_t sz;
	int len;

	while (1)
	{
		sz = GS_FTM_mk_packet(&p->ft, p->wbuf, sizeof p->wbuf);
		if (sz == 0)
			return GS_SUCCESS;
		if (sz == -1)
			return GS_SUCCESS;
		if (sz < 0)
			return GS_ERR_FATAL;

		p->wlen = sz;
		len = write_gs_atomic(ctx, p);
		if (len == -1)
			return GS_ECALLAGAIN;
		if (len != p->wlen)
			return GS_ERROR;
		p->wlen = 0;
		return GS_SUCCESS;
	}

	return GS_SUCCESS;
}

static int
send_log(GS_SELECT_CTX *ctx, struct _peer *p, struct _pkt_app_log *log)
{
	int killed = 0;
	int ret;
	p->wbuf[0] = GS_PKT_ESC;
	p->wbuf[1] = PKT_MSG_LOG;

	XASSERT(GS_PKT_MSG_size_by_type(p->wbuf[1]) == sizeof *log, "Size does not fit\n");

	memcpy(p->wbuf + 2, log, sizeof *log);
	p->wlen = 2 + GS_PKT_MSG_size_by_type(p->wbuf[1]);

	ret = write_gs(ctx, p, &killed);
	if (killed)
		return GS_ERR_FATAL;

	return ret;
}

int
pkt_app_send_all_log(GS_SELECT_CTX *ctx, struct _peer *p)
{
	GS_LIST_ITEM *li = NULL;
	int ret;

	p->is_pending_logs = 0;

	while (1)
	{
		li = GS_LIST_next(&p->logs, NULL);
		if (li == NULL)
			break;

		ret = send_log(ctx, p, li->data);
		if (ret == GS_ERR_FATAL)
			return GS_ERR_FATAL;

		XFREE(li->data);
		GS_LIST_del(li);

		if (ret != GS_SUCCESS)
		{
			p->is_pending_logs = 1;
			return ret;
		}
	}

	return GS_SUCCESS;
}

int
pkt_app_send_status_nopty(GS_SELECT_CTX *ctx, struct _peer *p)
{
	struct _pkt_app_status status;

	p->wbuf[0] = GS_PKT_ESC;
	p->wbuf[1] = PKT_MSG_STATUS;

	memset(&status, 0, sizeof status);
	status.type = GS_PKT_APP_STATUS_TYPE_NOPTY;
	memcpy(p->wbuf + 2, &status, sizeof status);

	p->wlen = 2 + GS_PKT_MSG_size_by_type(PKT_MSG_STATUS);
	return write_gs(ctx, p, NULL);
}
