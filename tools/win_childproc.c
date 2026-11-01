/*
 * See win_childproc.h for the rationale behind the loopback-socket bridge
 * design (gs-select's event loop only ever sees plain select()-able sockets).
 */
#include "common.h"
#include "utils.h"
#include "win_childproc.h"

#include <processthreadsapi.h>
/* CreatePseudoConsole/ResizePseudoConsole/ClosePseudoConsole exist in
 * kernel32.dll on Windows 10 1809+/Server 2019+, but statically importing
 * them (declaring them via windows.h and calling them by name, which makes
 * the linker bind the import at link time) means the loader must resolve
 * that import before main() even runs - on any Windows build/edition where
 * it doesn't, the *entire* exe fails to start with an "Entry Point Not
 * Found" message box, taking down every other mode (port-forward/exec/
 * SOCKS) along with -i. Resolve the three entry points dynamically instead
 * (GetProcAddress against the already-loaded kernel32.dll) so ConPTY is a
 * runtime-checked optional feature: if it's missing, -i falls back to a
 * plain (non-PTY) exec instead of crashing the whole program.
 * (A still-earlier pass shipped Microsoft's conpty.dll/OpenConsole.exe
 * redistributable instead of the OS's own export - removed because it
 * reproduced the same rendering bug anyway and cost a second DLL + exe to
 * deploy. This dynamic-load approach needs neither that nor a static
 * kernel32 import.) */
typedef HRESULT (WINAPI *PFN_CreatePseudoConsole)(COORD, HANDLE, HANDLE, DWORD, HPCON *);
typedef HRESULT (WINAPI *PFN_ResizePseudoConsole)(HPCON, COORD);
typedef VOID    (WINAPI *PFN_ClosePseudoConsole)(HPCON);

static PFN_CreatePseudoConsole pfnCreatePseudoConsole;
static PFN_ResizePseudoConsole pfnResizePseudoConsole;
static PFN_ClosePseudoConsole  pfnClosePseudoConsole;
static int g_conpty_checked;	/* 0 = not probed yet; 1 = probed (pfns may still be NULL) */

/* Returns true iff all three ConPTY entry points resolved. Safe to call
 * repeatedly; only probes kernel32.dll once. */
static int
conpty_is_available(void)
{
	if (!g_conpty_checked)
	{
		HMODULE hK32 = GetModuleHandleA("kernel32.dll");	/* always already loaded */
		if (hK32 != NULL)
		{
			pfnCreatePseudoConsole = (PFN_CreatePseudoConsole)GetProcAddress(hK32, "CreatePseudoConsole");
			pfnResizePseudoConsole = (PFN_ResizePseudoConsole)GetProcAddress(hK32, "ResizePseudoConsole");
			pfnClosePseudoConsole  = (PFN_ClosePseudoConsole)GetProcAddress(hK32, "ClosePseudoConsole");
		}
		g_conpty_checked = 1;
		if ((pfnCreatePseudoConsole == NULL) || (pfnResizePseudoConsole == NULL) || (pfnClosePseudoConsole == NULL))
			DEBUGF_R("ConPTY not available on this Windows version/build - falling back to non-interactive exec for -i\n");
	}

	return (pfnCreatePseudoConsole != NULL) && (pfnResizePseudoConsole != NULL) && (pfnClosePseudoConsole != NULL);
}

#ifndef STARTF_USESTDHANDLES
# define STARTF_USESTDHANDLES 0x00000100
#endif

/* FD_SETSIZE here must match win32-compat.h's (4096) - see that file's
 * comment on why bumping FD_SETSIZE is an empirical, not proven, fix. */
static struct _bridge *g_bridge_by_fd[FD_SETSIZE];

struct _bridge
{
	SOCKET near_sock;		/* our end; threads pump bytes to/from this */
	HANDLE hRead;			/* read child output (ConPTY out, or stdout pipe) */
	HANDLE hWrite;			/* write child input (ConPTY in, or stdin pipe) */
	HANDLE hProcess;
	HPCON hPC;				/* NULL if not a PTY session */
	CRITICAL_SECTION lock;	/* guards the close-once fields above */
	LONG refcnt;			/* 2 threads; last one out frees everything */
	int far_fd;				/* index into g_bridge_by_fd[], for win_pty_resize() */
};

static void
safe_close_handle(struct _bridge *b, HANDLE *h)
{
	EnterCriticalSection(&b->lock);
	if (*h != NULL)
	{
		CloseHandle(*h);
		*h = NULL;
	}
	LeaveCriticalSection(&b->lock);
}

static void
safe_close_pty(struct _bridge *b)
{
	EnterCriticalSection(&b->lock);
	if (b->hPC != NULL)
	{
		pfnClosePseudoConsole(b->hPC);	/* unblocks reader thread's pending ReadFile */
		b->hPC = NULL;
	}
	LeaveCriticalSection(&b->lock);
}

static void
safe_terminate(struct _bridge *b)
{
	EnterCriticalSection(&b->lock);
	if (b->hProcess != NULL)
		TerminateProcess(b->hProcess, 0);
	LeaveCriticalSection(&b->lock);
}

static void
bridge_release(struct _bridge *b)
{
	if (InterlockedDecrement(&b->refcnt) != 0)
		return;

	if (b->far_fd >= 0 && b->far_fd < FD_SETSIZE)
		g_bridge_by_fd[b->far_fd] = NULL;

	safe_close_pty(b);
	safe_close_handle(b, &b->hRead);
	safe_close_handle(b, &b->hWrite);
	EnterCriticalSection(&b->lock);
	if (b->hProcess != NULL)
	{
		CloseHandle(b->hProcess);
		b->hProcess = NULL;
	}
	LeaveCriticalSection(&b->lock);
	closesocket(b->near_sock);
	DeleteCriticalSection(&b->lock);
	free(b);
}

static DWORD WINAPI
reader_thread(LPVOID arg)
{
	struct _bridge *b = (struct _bridge *)arg;
	char buf[4096];
	DWORD n;

	while (ReadFile(b->hRead, buf, sizeof buf, &n, NULL) && n > 0)
	{
		DWORD off = 0;
		while (off < n)
		{
			int sent = send(b->near_sock, buf + off, (int)(n - off), 0);
			if (sent <= 0)
				goto done;
			off += (DWORD)sent;
		}
	}
done:
	/* Child is done producing output (exited, or we were force-closed by
	 * the writer thread below). Tell the far side (gs-netcat.c) EOF. */
	shutdown(b->near_sock, SD_SEND);
	safe_close_handle(b, &b->hRead);
	bridge_release(b);
	return 0;
}

static DWORD WINAPI
writer_thread(LPVOID arg)
{
	struct _bridge *b = (struct _bridge *)arg;
	char buf[4096];
	int n;

	while ((n = recv(b->near_sock, buf, sizeof buf, 0)) > 0)
	{
		DWORD off = 0;
		while (off < (DWORD)n)
		{
			DWORD written = 0;
			if (!WriteFile(b->hWrite, buf + off, (DWORD)n - off, &written, NULL))
				goto done;
			off += written;
		}
	}
done:
	/* The far side closed its fd (XCLOSE(p->fd_in)) or errored. Upstream's
	 * semantics for closing a child's stdin is to end the session - do the
	 * same here: close the input handle (EOF to a well-behaved child), then
	 * force the issue so a shell waiting on input doesn't linger forever. */
	safe_close_handle(b, &b->hWrite);
	safe_terminate(b);
	safe_close_pty(b);	/* forces reader_thread's ReadFile to unblock */
	bridge_release(b);
	return 0;
}

static int
bridge_start(HANDLE hRead, HANDLE hWrite, HANDLE hProcess, HPCON hPC)
{
	SOCKET lsock, nearsock, farsock;
	struct sockaddr_in addr;
	int addrlen = sizeof addr;

	/* Windows has no socketpair(); emulate one via a loopback connection. */
	lsock = socket(AF_INET, SOCK_STREAM, 0);
	if (lsock == INVALID_SOCKET)
		return -1;
	memset(&addr, 0, sizeof addr);
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	addr.sin_port = 0;
	if (bind(lsock, (struct sockaddr *)&addr, sizeof addr) != 0)
	{
		closesocket(lsock);
		return -1;
	}
	if (listen(lsock, 1) != 0)
	{
		closesocket(lsock);
		return -1;
	}
	getsockname(lsock, (struct sockaddr *)&addr, &addrlen);

	farsock = socket(AF_INET, SOCK_STREAM, 0);
	if (farsock == INVALID_SOCKET)
	{
		closesocket(lsock);
		return -1;
	}
	if (connect(farsock, (struct sockaddr *)&addr, sizeof addr) != 0)
	{
		closesocket(lsock);
		closesocket(farsock);
		return -1;
	}
	nearsock = accept(lsock, NULL, NULL);
	closesocket(lsock);
	if (nearsock == INVALID_SOCKET)
	{
		closesocket(farsock);
		return -1;
	}

	struct _bridge *b = calloc(1, sizeof *b);
	XASSERT(b != NULL, "calloc()\n");
	b->near_sock = nearsock;
	b->hRead = hRead;
	b->hWrite = hWrite;
	b->hProcess = hProcess;
	b->hPC = hPC;
	b->refcnt = 2;
	b->far_fd = (int)farsock;
	InitializeCriticalSection(&b->lock);

	if (b->far_fd >= 0 && b->far_fd < FD_SETSIZE)
		g_bridge_by_fd[b->far_fd] = b;

	HANDLE ht1 = CreateThread(NULL, 0, reader_thread, b, 0, NULL);
	HANDLE ht2 = CreateThread(NULL, 0, writer_thread, b, 0, NULL);
	XASSERT((ht1 != NULL) && (ht2 != NULL), "CreateThread()\n");
	CloseHandle(ht1);
	CloseHandle(ht2);

	return (int)farsock;
}

void
win_pty_resize(int fd, int cols, int rows)
{
	if ((fd < 0) || (fd >= FD_SETSIZE))
		return;
	struct _bridge *b = g_bridge_by_fd[fd];
	if (b == NULL)
		return;

	EnterCriticalSection(&b->lock);
	if (b->hPC != NULL)
	{
		COORD size;
		size.X = (SHORT)cols;
		size.Y = (SHORT)rows;
		pfnResizePseudoConsole(b->hPC, size);
	}
	LeaveCriticalSection(&b->lock);
}

/* True iff Windows PowerShell actually exists on disk at its well-known
 * install path (present by default since Windows 7/Server 2008 R2, but not
 * guaranteed on a stripped-down Server Core/Nano install). Checked via its
 * fixed path rather than a PATH search so this can't accidentally pick up
 * some unrelated renamed powershell.exe. */
static int
powershell_path(char *out, size_t outsz)
{
	const char *sysroot = getenv("SystemRoot");
	if (sysroot == NULL)
		sysroot = "C:\\Windows";

	snprintf(out, outsz, "%s\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", sysroot);
	DWORD attrs = GetFileAttributesA(out);

	return (attrs != INVALID_FILE_ATTRIBUTES) && !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

/* -e <cmd> (if given) is run directly as the CreateProcess command line -
 * e.g. "-e powershell.exe" spawns PowerShell itself, not cmd.exe wrapping
 * it via "/C powershell.exe" (that extra layer buys nothing here and just
 * adds a redundant parent process). With no -e, default to PowerShell if
 * it's actually present, else fall back to the system shell (%ComSpec%,
 * normally cmd.exe). CreateProcess's lpCommandLine must be writable, hence
 * the copy into a mutable buffer in every branch. */
static char *
mk_cmdline(const char *cmd)
{
	static char buf[4096];

	if (cmd != NULL)
	{
		snprintf(buf, sizeof buf, "%s", cmd);
		return buf;
	}

	char pwsh[MAX_PATH];
	if (powershell_path(pwsh, sizeof pwsh))
	{
		snprintf(buf, sizeof buf, "\"%s\"", pwsh);
		return buf;
	}

	const char *comspec = getenv("ComSpec");
	if (comspec == NULL)
		comspec = "cmd.exe";
	snprintf(buf, sizeof buf, "\"%s\"", comspec);

	return buf;
}

/* Plain (non-PTY) pipe spawn - used for -e exec, and as the ConPTY fallback. */
static int
win_fd_cmd_plain(const char *cmd, pid_t *pidptr, int *err)
{
	SECURITY_ATTRIBUTES sa;
	HANDLE hStdinR = NULL, hStdinW = NULL, hStdoutR = NULL, hStdoutW = NULL;
	PROCESS_INFORMATION pi;
	STARTUPINFOA si;

	memset(&sa, 0, sizeof sa);
	sa.nLength = sizeof sa;
	sa.bInheritHandle = TRUE;

	if (!CreatePipe(&hStdinR, &hStdinW, &sa, 0))
		ERREXIT("CreatePipe(stdin): %lu\n", GetLastError());
	if (!CreatePipe(&hStdoutR, &hStdoutW, &sa, 0))
		ERREXIT("CreatePipe(stdout): %lu\n", GetLastError());
	SetHandleInformation(hStdinW, HANDLE_FLAG_INHERIT, 0);
	SetHandleInformation(hStdoutR, HANDLE_FLAG_INHERIT, 0);

	memset(&si, 0, sizeof si);
	si.cb = sizeof si;
	si.dwFlags = STARTF_USESTDHANDLES;
	si.hStdInput = hStdinR;
	si.hStdOutput = hStdoutW;
	si.hStdError = hStdoutW;

	memset(&pi, 0, sizeof pi);
	char *cmdline = mk_cmdline(cmd);
	if (!CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi))
		ERREXIT("CreateProcess(%s): %lu\n", cmdline, GetLastError());

	CloseHandle(hStdinR);
	CloseHandle(hStdoutW);
	CloseHandle(pi.hThread);

	if (pidptr != NULL)
		*pidptr = (pid_t)pi.dwProcessId;

	return bridge_start(hStdoutR, hStdinW, pi.hProcess, NULL);
}

static int
win_fd_cmd_pty(const char *cmd, pid_t *pidptr, int *err)
{
	HANDLE hPipePTYIn = INVALID_HANDLE_VALUE, hPipePTYOut = INVALID_HANDLE_VALUE;
	HANDLE hPipeIn = INVALID_HANDLE_VALUE, hPipeOut = INVALID_HANDLE_VALUE; /* ours */
	HPCON hPC = NULL;
	HRESULT hr;

	if (!conpty_is_available())
		goto fallback;

	/* Standard ConPTY pipe pattern (Microsoft's CreatePseudoConsoleAndPipes
	 * sample): hPipePTYIn/hPipePTYOut are the PTY's own ends and get closed
	 * by us right after CreatePseudoConsole() - it dup's them internally. */
	if (!CreatePipe(&hPipePTYIn, &hPipeOut, NULL, 0))
		goto fallback;
	if (!CreatePipe(&hPipeIn, &hPipePTYOut, NULL, 0))
		goto fallback;

	COORD size;
	size.X = 80;
	size.Y = 24; /* fixed initial size; see header comment re: no live SIGWINCH */
	hr = pfnCreatePseudoConsole(size, hPipePTYIn, hPipePTYOut, 0, &hPC);
	if (FAILED(hr))
		goto fallback;

	CloseHandle(hPipePTYOut);
	CloseHandle(hPipePTYIn);

	size_t attrListSize = 0;
	InitializeProcThreadAttributeList(NULL, 1, 0, &attrListSize);
	LPPROC_THREAD_ATTRIBUTE_LIST attrList = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attrListSize);
	XASSERT(attrList != NULL, "malloc()\n");
	if (!InitializeProcThreadAttributeList(attrList, 1, 0, &attrListSize))
		ERREXIT("InitializeProcThreadAttributeList(): %lu\n", GetLastError());
	if (!UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
			hPC, sizeof hPC, NULL, NULL))
		ERREXIT("UpdateProcThreadAttribute(): %lu\n", GetLastError());

	STARTUPINFOEXA siEx;
	memset(&siEx, 0, sizeof siEx);
	siEx.StartupInfo.cb = sizeof siEx;
	siEx.lpAttributeList = attrList;

	PROCESS_INFORMATION pi;
	memset(&pi, 0, sizeof pi);
	char *cmdline = mk_cmdline(cmd);
	BOOL ok = CreateProcessA(NULL, cmdline, NULL, NULL, FALSE,
			EXTENDED_STARTUPINFO_PRESENT, NULL, NULL, &siEx.StartupInfo, &pi);
	DeleteProcThreadAttributeList(attrList);
	free(attrList);
	if (!ok)
		ERREXIT("CreateProcess(%s): %lu\n", cmdline, GetLastError());

	CloseHandle(pi.hThread);
	if (pidptr != NULL)
		*pidptr = (pid_t)pi.dwProcessId;

	return bridge_start(hPipeIn, hPipeOut, pi.hProcess, hPC);

fallback:
	if (hPC != NULL)
		pfnClosePseudoConsole(hPC);
	if (hPipePTYIn != INVALID_HANDLE_VALUE)
		CloseHandle(hPipePTYIn);
	if (hPipePTYOut != INVALID_HANDLE_VALUE)
		CloseHandle(hPipePTYOut);
	if (hPipeIn != INVALID_HANDLE_VALUE)
		CloseHandle(hPipeIn);
	if (hPipeOut != INVALID_HANDLE_VALUE)
		CloseHandle(hPipeOut);
	*err = GS_FD_CMD_ERR_NOPTY;
	return win_fd_cmd_plain(cmd, pidptr, err);
}

int
win_fd_cmd(const char *cmd, pid_t *pidptr, int *err)
{
	*err = 0;
	if (gopt.is_interactive)
		return win_fd_cmd_pty(cmd, pidptr, err);

	return win_fd_cmd_plain(cmd, pidptr, err);
}

int
win_stdio_bridge_fd(void)
{
	HANDLE hIn = GetStdHandle(STD_INPUT_HANDLE);
	HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);

	/* Duplicate: the real console handles must outlive this call (they are
	 * process-lifetime), but bridge_start()/safe_close_handle() will close
	 * whatever it's given once the session ends. Use private duplicates so
	 * we never close the process's actual std handles. */
	HANDLE hInDup, hOutDup;
	DuplicateHandle(GetCurrentProcess(), hIn, GetCurrentProcess(), &hInDup, 0, FALSE, DUPLICATE_SAME_ACCESS);
	DuplicateHandle(GetCurrentProcess(), hOut, GetCurrentProcess(), &hOutDup, 0, FALSE, DUPLICATE_SAME_ACCESS);

	return bridge_start(hInDup, hOutDup, NULL, NULL);
}
