# NMake top-level build: gsocket.lib + gs-tunnel.exe + gs-netcat.exe
# Mirrors windows\gsocket.proj - keep both in sync when files/flags change.
#
# Assumes an already-activated VC dev environment (cl/lib/link on PATH) -
# e.g. run from an "x64 Native Tools Command Prompt for VS 2022", or after
# `call vcvars64.bat`. Override any of these on the command line, e.g.:
#   nmake OSSLDIR=D:\openssl
!IFNDEF ROOT
ROOT = $(MAKEDIR)\..
!ENDIF
!IFNDEF OSSLDIR
OSSLDIR = $(MAKEDIR)\build\openssl-install
!ENDIF
!IFNDEF OSSLSRC
OSSLSRC = $(MAKEDIR)\build\openssl-src
!ENDIF
!IFNDEF STRAWBERRY
STRAWBERRY = $(MAKEDIR)\build\strawberry-perl-extracted
!ENDIF
!IFNDEF OUTDIR
OUTDIR = $(MAKEDIR)\build
!ENDIF

LIBDIR = $(ROOT)\lib
TOOLSDIR = $(ROOT)\tools
INCDIR = $(ROOT)\include
OBJDIR = $(OUTDIR)\obj
OBJDIR_NETCAT = $(OUTDIR)\obj-netcat

CC = cl
CFLAGS = /nologo /W3 /O2 /MT /MP
SYSLIBS = ws2_32.lib crypt32.lib advapi32.lib user32.lib gdi32.lib
OSSLLIBS = "$(OSSLDIR)\lib\libssl.lib" "$(OSSLDIR)\lib\libcrypto.lib"

LIB_INC = /I"$(LIBDIR)" /I"$(INCDIR)" /I"$(OSSLDIR)\include"
NETCAT_INC = /I"$(TOOLSDIR)" /I"$(LIBDIR)" /I"$(INCDIR)" /I"$(OSSLDIR)\include"

# Keep in sync with lib/*.c in the repo (buf, event, gsocket-engine,
# gsocket-select, gsocket-sha256, gsocket-ssl, gsocket-util, list, packet).
LIB_OBJS = \
	"$(OBJDIR)\buf.obj" \
	"$(OBJDIR)\event.obj" \
	"$(OBJDIR)\gsocket-engine.obj" \
	"$(OBJDIR)\gsocket-select.obj" \
	"$(OBJDIR)\gsocket-sha256.obj" \
	"$(OBJDIR)\gsocket-ssl.obj" \
	"$(OBJDIR)\gsocket-util.obj" \
	"$(OBJDIR)\list.obj" \
	"$(OBJDIR)\packet.obj"

# Keep in sync with gs-netcat's sources in tools/ (everything gs-netcat.exe
# links except gs-tunnel.c, which is its own single-file target below).
NETCAT_OBJS = \
	"$(OBJDIR_NETCAT)\4_gs-netcat.obj" \
	"$(OBJDIR_NETCAT)\utils.obj" \
	"$(OBJDIR_NETCAT)\socks.obj" \
	"$(OBJDIR_NETCAT)\event_mgr.obj" \
	"$(OBJDIR_NETCAT)\pkt_mgr.obj" \
	"$(OBJDIR_NETCAT)\stubs.obj" \
	"$(OBJDIR_NETCAT)\win_getopt.obj" \
	"$(OBJDIR_NETCAT)\win_childproc.obj" \
	"$(OBJDIR_NETCAT)\gsocket_dso-lib.obj"

# Coarse-grained header tracking (see windows/Makefile design notes in the
# plan this came from): touching any of these rebuilds every object in the
# corresponding group, rather than true per-file #include scanning. Correct,
# just not maximally precise - acceptable at this codebase's size.
LIB_HEADERS = \
	"$(LIBDIR)\gs-common.h" \
	"$(LIBDIR)\win32-compat.h" \
	"$(LIBDIR)\gs-externs.h" \
	"$(LIBDIR)\gsocket-engine.h" \
	"$(LIBDIR)\gsocket-sha256.h" \
	"$(INCDIR)\gsocket\gsocket.h" \
	"$(INCDIR)\gsocket\packet.h" \
	"$(INCDIR)\gsocket\gsocket-ssl.h" \
	"$(INCDIR)\gsocket\gs-select.h" \
	"$(INCDIR)\gsocket\event.h" \
	"$(INCDIR)\gsocket\list.h" \
	"$(INCDIR)\gsocket\buf.h" \
	"$(INCDIR)\gsocket\gs-readline.h"

NETCAT_HEADERS = \
	"$(TOOLSDIR)\common.h" \
	"$(TOOLSDIR)\gs-netcat.h" \
	"$(TOOLSDIR)\utils.h" \
	"$(TOOLSDIR)\socks.h" \
	"$(TOOLSDIR)\pkt_mgr.h" \
	"$(TOOLSDIR)\event_mgr.h" \
	"$(TOOLSDIR)\stubs.h" \
	"$(TOOLSDIR)\win_getopt.h" \
	"$(TOOLSDIR)\win_childproc.h" \
	"$(TOOLSDIR)\gsocket_dso-lib.h" \
	"$(TOOLSDIR)\console_display.h"

all: "$(OUTDIR)\gs-tunnel.exe" "$(OUTDIR)\gs-netcat.exe"

lib: "$(OUTDIR)\gsocket.lib"

openssl: "$(OSSLDIR)\lib\libssl.lib"

# Delegates to the separate OpenSSL sub-project (windows\openssl\) - see
# that Makefile for why it's kept distinct. Transitively triggered by
# gsocket.lib/the exes below depending on this same file.
"$(OSSLDIR)\lib\libssl.lib":
	cd "$(MAKEDIR)\openssl" && nmake /nologo OPENSSL_SRC="$(OSSLSRC)" OPENSSL_INSTALL="$(OSSLDIR)" STRAWBERRY="$(STRAWBERRY)"

"$(OUTDIR)\gsocket.lib": $(LIB_OBJS)
	@if not exist "$(OUTDIR)" mkdir "$(OUTDIR)"
	lib /nologo /OUT:"$(OUTDIR)\gsocket.lib" $(LIB_OBJS)

{$(LIBDIR)\}.c{$(OBJDIR)\}.obj::
	@if not exist "$(OBJDIR)" mkdir "$(OBJDIR)"
	$(CC) $(CFLAGS) /DHAVE_LIBCRYPTO=1 $(LIB_INC) /c /Fo"$(OBJDIR)\\" $<

{$(TOOLSDIR)\}.c{$(OBJDIR_NETCAT)\}.obj::
	@if not exist "$(OBJDIR_NETCAT)" mkdir "$(OBJDIR_NETCAT)"
	$(CC) $(CFLAGS) /DHAVE_LIBCRYPTO=1 $(NETCAT_INC) /c /Fo"$(OBJDIR_NETCAT)\\" $<

$(LIB_OBJS): $(LIB_HEADERS)
$(NETCAT_OBJS): $(LIB_HEADERS) $(NETCAT_HEADERS)

# gs-tunnel.c is a single file with no POSIX-exec/PTY machinery, so it does
# NOT get -DHAVE_LIBCRYPTO=1 - matching the existing, already-verified
# build-tunnel.bat exactly. Not something to "fix" as a side effect here.
"$(OUTDIR)\gs-tunnel.exe": "$(TOOLSDIR)\gs-tunnel.c" "$(OUTDIR)\gsocket.lib" "$(OSSLDIR)\lib\libssl.lib"
	@if not exist "$(OUTDIR)" mkdir "$(OUTDIR)"
	$(CC) $(CFLAGS) $(LIB_INC) "$(TOOLSDIR)\gs-tunnel.c" /Fo"$(OUTDIR)\\" /Fe:"$(OUTDIR)\gs-tunnel.exe" /link "$(OUTDIR)\gsocket.lib" $(OSSLLIBS) $(SYSLIBS)

"$(OUTDIR)\gs-netcat.exe": $(NETCAT_OBJS) "$(OUTDIR)\gsocket.lib" "$(OSSLDIR)\lib\libssl.lib"
	$(CC) $(CFLAGS) /Fe:"$(OUTDIR)\gs-netcat.exe" $(NETCAT_OBJS) /link "$(OUTDIR)\gsocket.lib" $(OSSLLIBS) $(SYSLIBS)

clean:
	-if exist "$(OBJDIR)" rmdir /s /q "$(OBJDIR)"
	-if exist "$(OBJDIR_NETCAT)" rmdir /s /q "$(OBJDIR_NETCAT)"
	-if exist "$(OUTDIR)\gsocket.lib" del /q "$(OUTDIR)\gsocket.lib"
	-if exist "$(OUTDIR)\gs-tunnel.exe" del /q "$(OUTDIR)\gs-tunnel.exe"
	-if exist "$(OUTDIR)\gs-netcat.exe" del /q "$(OUTDIR)\gs-netcat.exe"

rebuild: clean all
