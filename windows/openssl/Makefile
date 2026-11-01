# NMake sub-project: builds a static OpenSSL for MSVC.
#
# Kept separate from windows\Makefile on purpose - OpenSSL's own build is
# large, slow, and rarely changes, unlike gsocket's own sources. The parent
# Makefile depends on $(OPENSSL_INSTALL)\lib\libssl.lib and recurses into
# this file (via "cd openssl && nmake") only when that file is missing.
#
# Override any of these on the command line if needed, e.g.:
#   nmake OPENSSL_SRC=D:\src\openssl OPENSSL_INSTALL=D:\out\openssl
# Defaults match the layout windows\build-openssl.bat already used.

!IFNDEF OPENSSL_SRC
OPENSSL_SRC = $(MAKEDIR)\..\build\openssl-src
!ENDIF
!IFNDEF OPENSSL_INSTALL
OPENSSL_INSTALL = $(MAKEDIR)\..\build\openssl-install
!ENDIF
!IFNDEF STRAWBERRY
STRAWBERRY = $(MAKEDIR)\..\build\strawberry-perl-extracted
!ENDIF

all: "$(OPENSSL_INSTALL)\lib\libssl.lib"

"$(OPENSSL_INSTALL)\lib\libssl.lib":
	@if not exist "$(OPENSSL_SRC)\Configure" (echo ERROR: OpenSSL source not found at "$(OPENSSL_SRC)" - fetch/extract it there first ^(see windows\build-openssl.bat for the known-good version^). & exit /b 1)
	@if not exist "$(STRAWBERRY)\perl\bin\perl.exe" (echo ERROR: Perl not found at "$(STRAWBERRY)\perl\bin\perl.exe" - OpenSSL's Configure script needs it ^(see windows\build-openssl.bat for how this was fetched^). & exit /b 1)
	cd "$(OPENSSL_SRC)" && set "PATH=$(STRAWBERRY)\perl\bin;$(STRAWBERRY)\c\bin;%PATH%" && perl Configure VC-WIN64A no-asm no-shared --prefix="$(OPENSSL_INSTALL)" --openssldir="$(OPENSSL_INSTALL)" && nmake && nmake install_sw

# Removes the installed/built output only - re-running `nmake` afterwards
# re-runs Configure+nmake against the still-present source tree.
clean:
	-if exist "$(OPENSSL_INSTALL)" rmdir /s /q "$(OPENSSL_INSTALL)"

# Also drops the ~5.7GB source checkout itself - a from-scratch rebuild
# after this needs OPENSSL_SRC repopulated first.
distclean: clean
	-if exist "$(OPENSSL_SRC)" rmdir /s /q "$(OPENSSL_SRC)"
