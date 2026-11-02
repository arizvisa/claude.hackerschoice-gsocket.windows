#!/usr/bin/env bash
# gs-transfer responder - see ../PROTOCOL.md for the wire format.
#
# Two ways to run this:
#
#   1. Standalone (recommended): gs-transfer-server.sh [-s <secret>|-k <file>] [-T]
#      This process launches gs-netcat itself (-l, plus whatever
#      secret/proxy flags were given) with -e pointing back at this
#      same script - no gs-netcat command line to construct by hand.
#   2. Manually, exactly as before gs-netcat ever existed as a
#      dependency this script could launch on its own:
#        gs-netcat -s <secret> -l -e /path/to/gs-transfer-server.sh
#      Still fully supported - see the GSTRANSFER_WORKER check below.
#
# Either way, once gs-netcat's -e actually execs this script, its
# stdin/stdout are the tunnel. Deliberately plain stdin/stdout (fd 0/1)
# throughout from that point on - gs-netcat's -e gives this script
# nothing else to talk to. Diagnostics go to stderr, which -e leaves
# separate from the tunnel data stream (confirmed via this project's
# own -e exec testing).
set -u

# Computed once, not per-check - uname -o spawns a subprocess, and
# is_safe_partial further down can run many times during a transfer.
# uname -o is a GNU/MSYS/Cygwin extension (absent on macOS/BSD, where
# the lookup fails safely to "no") - it's what distinguishes a real
# MSYS/Cygwin environment (Windows underneath, however this script
# itself got launched) from a native Linux/macOS one. Used below for
# two unrelated reasons: the launcher needs it to build a -e value
# Windows' CreateProcess can actually run, and is_cygwin_symlink
# further down needs it to know when checking for MSYS/Cygwin's own
# symlink emulation is even meaningful.
case "$(uname -o 2>/dev/null)" in
	Msys | Cygwin) IS_MSYS_LIKE=1 ;;
	*) IS_MSYS_LIKE=0 ;;
esac

# Worker if EITHER signal says so - never require both. GSTRANSFER_WORKER
# is this script's own explicit self-launch marker (set below, just
# before it execs gs-netcat, and inherited through gs-netcat's own
# fork/exec of its -e child) - but that marker is absent for the manual,
# pre-standalone-launching invocation style this script must keep
# supporting unchanged (gs-netcat -l -e /path/to/gs-transfer-server.sh,
# nobody sets any env var for that). The two styles are otherwise
# indistinguishable from argv/env alone, since gs-netcat's -e passes no
# arguments of its own - so the fallback signal is stdin's own nature:
# gs-netcat wires a -e child's stdin to a pipe (confirmed against this
# project's own win_childproc.c - CreatePipe, not a TTY or /dev/null),
# which a fresh launch from an interactive shell or a backgrounded/
# redirected one (this script's own test harness's nohup ... &
# included - bash redirects a backgrounded interactive job's stdin to
# /dev/null when nothing else was redirected) never is. Verified
# directly: -p correctly reads true for a real pipe and false for both
# a TTY-less /dev/null redirect and (this sandbox's own, non-interactive
# stdin) a pipe fed by `|` - the one case this can't simulate directly,
# a genuine attached terminal, is never a FIFO either by basic,
# well-established tty-vs-pipe semantics, not something platform-
# specific here.
if [[ "${GSTRANSFER_WORKER:-}" != "1" ]] && [[ ! -p /dev/stdin ]]; then
	# --- Outer/launcher mode: parse args, become gs-netcat, which will
	# later exec a fresh copy of this same script (in worker mode, via
	# -e) for each connection it accepts. ---
	GS_NETCAT_BIN="gs-netcat"
	BIN="$(cd "$(dirname "${0}")" >/dev/null 2>&1 && pwd)/${GS_NETCAT_BIN}"
	[[ -f "${BIN}" ]] && GS_NETCAT_BIN="${BIN}"
	command -v "${GS_NETCAT_BIN}" >/dev/null 2>&1 || { echo >&2 "${GS_NETCAT_BIN} not found. Check PATH=?"; exit 1; }

	usage() {
		echo >&2 "Usage: $0 [-s <secret>|-k <file>] [-T]"
		exit 1
	}

	SECRET=""
	SECFILE=""
	USE_TOR=0
	while getopts ":s:k:T" opt; do
		case "$opt" in
			s) SECRET="$OPTARG" ;;
			k) SECFILE="$OPTARG" ;;
			T) USE_TOR=1 ;;
			*) usage ;;
		esac
	done

	# -s/-k/-T are gs-netcat's own flags, passed straight through
	# unchanged - see gs-transfer-client.sh's header comment for the
	# same rationale (no new secret-handling or proxy mechanism here).
	GSNC_ARGS=(-l)
	[[ -n "$SECRET" ]] && GSNC_ARGS+=(-s "$SECRET")
	[[ -n "$SECFILE" ]] && GSNC_ARGS+=(-k "$SECFILE")
	[[ "$USE_TOR" == "1" ]] && GSNC_ARGS+=(-T)

	SELF="$(cd "$(dirname "${0}")" >/dev/null 2>&1 && pwd)/$(basename "${0}")"
	BASH_BIN="$(command -v bash)"

	# -e's value becomes whatever the underlying gs-netcat execs - never
	# bare "$SELF": a shebang is a #!-line convention the *kernel*
	# interprets on exec(), which a Windows CreateProcess (what
	# gs-netcat.exe actually calls - confirmed against this project's
	# own win_childproc.c, no shell in between) has no concept of at
	# all. Confirmed by direct testing: a bare path there made the
	# listener die on the very first connection (CreateProcess failing
	# outright, not a graceful protocol error - gs-netcat's own -e
	# implementation calls ERREXIT on that, taking the whole listener
	# down, not just that one session). Explicitly naming the
	# interpreter works unconditionally on real POSIX too (bash <path>
	# needs no shebang or +x bit either), so there's no reason to only
	# do this on MSYS - only the *path style* actually depends on
	# platform: on MSYS/Cygwin, $SELF and $BASH_BIN are POSIX-style
	# (/c/Users/...), which Windows' CreateProcess can't resolve at all
	# (a leading / means "root of the current drive" to Win32, not an
	# MSYS path) - cygpath -w converts both to the Windows-style path
	# CreateProcess actually needs.
	if [[ "$IS_MSYS_LIKE" == "1" ]]; then
		SELF="$(cygpath -w "$SELF")"
		BASH_BIN="$(cygpath -w "$BASH_BIN")"
	fi
	E_VALUE="\"$BASH_BIN\" \"$SELF\""

	export GSTRANSFER_WORKER=1
	exec "$GS_NETCAT_BIN" "${GSNC_ARGS[@]}" -e "$E_VALUE"
fi

# --- Worker mode: gs-netcat's own -e just exec'd this same script
# fresh (GSTRANSFER_WORKER=1 inherited through the exec above and then
# through gs-netcat's own fork/exec of its -e child), with stdin/stdout
# now wired to the tunnel. Unchanged from before standalone launching
# existed - this part has no idea whether it got here via the launcher
# above or a manually-typed gs-netcat -e invocation, and doesn't need
# to. ---

log() { printf '%s\n' "$*" >&2; }

# Keeps every path confined to the responder's starting directory - see
# ../PROTOCOL.md's "Path rules". Verified against adversarial inputs
# (../, absolute, backslash, //, trailing /, bare "..", empty) before
# this went anywhere near the actual GET/PUT/LIST handlers.
is_safe_path() {
	local p="$1"
	[ -n "$p" ] || return 1
	case "$p" in
		/* | */ ) return 1 ;;   # absolute, or trailing slash
		*'\'*) return 1 ;;      # no backslashes - / is the only separator on the wire
	esac
	local IFS='/'
	local -a parts
	read -ra parts <<< "$p"
	local seg
	for seg in "${parts[@]}"; do
		case "$seg" in
			"" | ".." ) return 1 ;;
		esac
	done
	return 0
}

# Deterministic staging path for a GET/PUT target - known in advance,
# never scanned for. Safety against a planted symlink at this exact,
# guessable path comes from create_exclusive's atomicity and
# is_safe_partial's vetting below, not from making the name
# unpredictable (see ../PROTOCOL.md's "Partial-file safety").
partial_path() {
	local target="$1" dir base
	dir=$(dirname -- "$target")
	base=$(basename -- "$target")
	if [ "$dir" = "." ]; then
		printf '.%s.partial\n' "$base"
	else
		printf '%s/.%s.partial\n' "$dir" "$base"
	fi
}

# On MSYS/Cygwin only: their own symlink emulation (distinct from a
# native Windows reparse point) represents a symlink as an ordinary
# file starting with the literal bytes "!<symlink>", followed by a
# UTF-16LE BOM and the target path - invisible to both Windows itself
# and to -f/-L, which see nothing but a plain regular file. Confirmed
# directly with a hand-built file in this exact format: it passes
# [[ -f && ! -L ]] cleanly, exactly the gap this closes. Git-for-
# Windows' own `ln -s` doesn't produce this format (it falls back to a
# plain copy instead - see is_safe_partial's own comment below), but
# other MSYS2/Cygwin configurations can, so this only costs a 10-byte
# read on the platforms where it's actually possible.
is_cygwin_symlink() {
	local p="$1"
	[[ "$IS_MSYS_LIKE" == "1" ]] || return 1
	[[ "$(head -c 10 -- "$p" 2>/dev/null)" == '!<symlink>' ]]
}

# A partial is only trustworthy if it's a plain regular file - never a
# symlink, even one pointing at a legitimate file (it could be swapped
# out from under us, or planted by another party on a shared
# directory). Verified directly against a real Windows symlink (made
# with mklink, since Git-Bash's own `ln -s` silently falls back to
# copying instead of erroring when it lacks the privilege - a trap that
# looked like a passing test the first time, without actually testing
# anything): this correctly tells a plain file apart from a symlink
# pointing at that same content. is_cygwin_symlink above covers the
# other kind of "symlink" -L can't see at all.
is_safe_partial() {
	local p="$1"
	[[ -f "$p" && ! -L "$p" ]] || return 1
	! is_cygwin_symlink "$p"
}

# True only if nothing exists at $1, or what's there is a plain regular
# file we can safely remove ourselves. Never touches a symlink or
# anything else - that might not be ours to remove.
reset_partial() {
	local p="$1"
	if [ -e "$p" ] || [ -L "$p" ]; then
		is_safe_partial "$p" || return 1
		rm -f -- "$p"
	fi
	return 0
}

# Atomically creates $1 only if nothing exists there yet - never
# follows or overwrites a pre-existing path of any kind, symlink
# included. This is bash's documented noclobber behavior: the same
# O_EXCL-style exclusive create mktemp relies on, just at a path we
# chose ourselves instead of one it randomized - a pre-planted symlink
# at this exact path is refused outright, not written through.
create_exclusive() {
	local p="$1"
	( set -C; : > "$p" ) 2>/dev/null
}

# Hash of just the first $2 bytes of $1 - bounded by how much has
# actually been transferred so far, never the whole file, so resume
# validation never costs more than the resume itself already did.
prefix_hash() {
	local path="$1" n="$2"
	head -c "$n" -- "$path" | sha256sum | awk '{print $1}'
}

do_list() {
	local dir="${1:-.}" f base type size mtime
	if [ "$dir" != "." ]; then
		if ! is_safe_path "$dir"; then
			printf 'ERR invalid path\n'
			return
		fi
		if [ ! -d "$dir" ]; then
			printf 'ERR not found\n'
			return
		fi
	fi
	for f in "$dir"/*; do
		[ -e "$f" ] || continue   # unmatched glob (empty directory)
		base=$(basename -- "$f")
		if [ -d "$f" ]; then
			type="D"; size=0
		elif [ -f "$f" ]; then
			type="F"
			size=$(stat --format='%s' -- "$f" 2>/dev/null) || continue
		else
			continue   # skip symlinks/devices/etc.
		fi
		mtime=$(stat --format='%Y' -- "$f" 2>/dev/null) || continue
		printf '%s %s %s %s\n' "$type" "$size" "$mtime" "$base"
	done
	printf 'END\n'
}

do_get() {
	local path="$1" offset="${2:-}" claimed_hash="${3:-}" size actual_hash remaining
	if ! is_safe_path "$path"; then
		printf 'ERR invalid path\n'
		return
	fi
	if [ ! -f "$path" ]; then
		printf 'ERR not found\n'
		return
	fi
	size=$(stat --format='%s' -- "$path") || { printf 'ERR stat failed\n'; return; }
	if [ -z "$offset" ]; then
		printf 'OK %s\n' "$size"
		head -c "$size" -- "$path"
		return
	fi
	# Resume request: offset/claimed_hash describe the bytes the client
	# already has. Only the overlap gets hashed here, never the whole
	# file - see ../PROTOCOL.md's "Partial-file safety".
	if ! [[ "$offset" =~ ^[0-9]+$ ]] || [ "$offset" -gt "$size" ]; then
		printf 'ERR invalid offset\n'
		return
	fi
	actual_hash=$(prefix_hash "$path" "$offset")
	if [ "$actual_hash" != "$claimed_hash" ]; then
		printf 'ERR resume mismatch\n'
		return
	fi
	remaining=$((size - offset))
	printf 'OK %s\n' "$remaining"
	[ "$remaining" -gt 0 ] && tail -c "+$((offset + 1))" -- "$path"
}

do_mkdir() {
	local path="$1"
	if ! is_safe_path "$path"; then
		printf 'ERR invalid path\n'
		return
	fi
	mkdir -p -- "$path" && printf 'OK\n' || printf 'ERR mkdir failed\n'
}

# PUT is a 4-step handshake, not a single fire-and-forget request -
# see ../PROTOCOL.md's "Wire format". Unlike GET, the client can't
# unilaterally decide whether to resume: the partial lives on *this*
# side, so this side has to offer its state first, before any bytes
# flow, which is also why path/size validation can fail here with no
# draining needed at all (nothing's been sent yet):
#   1. client:  PUT <path> <size>
#   2. us:      FRESH | RESUME <offset> <hash> | ERR <reason>
#   3. client:  RESTART | RESUME <offset>
#   4. client streams <size> bytes (RESTART) or <size-offset> bytes
#      (RESUME); us: OK | ERR <reason>
do_put() {
	local path="$1" size="$2" partial offer_offset offer_hash
	local decision dec_verb dec_offset remaining dir

	if ! is_safe_path "$path" || ! [[ "$size" =~ ^[0-9]+$ ]]; then
		printf 'ERR invalid path\n'
		return
	fi

	partial=$(partial_path "$path")
	offer_offset=0
	if is_safe_partial "$partial"; then
		offer_offset=$(stat --format='%s' -- "$partial" 2>/dev/null) || offer_offset=0
	fi
	if [ "$offer_offset" -gt 0 ] && [ "$offer_offset" -le "$size" ]; then
		offer_hash=$(prefix_hash "$partial" "$offer_offset")
		printf 'RESUME %s %s\n' "$offer_offset" "$offer_hash"
	else
		offer_offset=0
		printf 'FRESH\n'
	fi

	if ! read -r decision; then
		log "gs-transfer-server: client vanished mid-PUT handshake for '$path'"
		return
	fi

	dec_verb=${decision%% *}
	dec_offset=${decision#"$dec_verb"}
	dec_offset=${dec_offset# }
	if [ "$dec_verb" = "RESTART" ]; then
		dec_offset=0
	elif [ "$dec_verb" = "RESUME" ] && [[ "$dec_offset" =~ ^[0-9]+$ ]] && [ "$dec_offset" -le "$size" ]; then
		: # dec_offset already parsed
	else
		log "gs-transfer-server: unexpected PUT handshake reply '$decision'"
		printf 'ERR unexpected reply\n'
		return
	fi
	remaining=$((size - dec_offset))

	if [ "$dec_verb" = "RESUME" ] && [ "$dec_offset" -gt 0 ] && [ "$dec_offset" = "$offer_offset" ] \
		&& is_safe_partial "$partial"; then
		head -c "$remaining" >> "$partial"
	elif [ "$dec_verb" = "RESUME" ]; then
		# Client echoed an offset we never offered (stale/confused) -
		# drain to stay in sync, but don't write anything anywhere: the
		# incoming bytes are only the *tail* past some offset, never
		# safe to treat as if they were the whole file.
		head -c "$remaining" >/dev/null
		log "gs-transfer-server: PUT resume offset mismatch for '$path' (offered $offer_offset, client said $dec_offset)"
		printf 'ERR offset mismatch\n'
		return
	else
		if ! reset_partial "$partial" || ! create_exclusive "$partial"; then
			head -c "$remaining" >/dev/null
			printf 'ERR staging blocked\n'
			return
		fi
		head -c "$remaining" > "$partial"
	fi

	dir=$(dirname -- "$path")
	[ "$dir" = "." ] || mkdir -p -- "$dir"
	mv -f -- "$partial" "$path"
	printf 'OK\n'
}

while IFS= read -r line; do
	cmd=${line%% *}
	rest=${line#"$cmd"}
	rest=${rest# }
	case "$cmd" in
		LIST) do_list "$rest" ;;
		GET)
			# <path> [<offset> <hash>] - path may itself contain spaces
			# (already supported elsewhere, e.g. do_list's entries), so
			# this can only ever split off a trailing "<digits>
			# <64-hex-chars>" pair, never blindly split the whole line
			# on whitespace (a naive split broke exactly this case
			# during development - caught before it shipped).
			if [[ "$rest" =~ ^(.*)\ ([0-9]+)\ ([0-9a-f]{64})$ ]]; then
				do_get "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
			else
				do_get "$rest" "" ""
			fi
			;;
		MKDIR) do_mkdir "$rest" ;;
		PUT)
			# <path> <size> - same reasoning as GET above; a plain
			# "first space" split (the original implementation, before
			# resume support) broke on spacey filenames too.
			if [[ "$rest" =~ ^(.*)\ ([0-9]+)$ ]]; then
				do_put "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
			else
				printf 'ERR invalid path\n'
			fi
			;;
		QUIT) log "gs-transfer-server: QUIT"; exit 0 ;;
		*)
			# Every request must get a response, even a bad one - otherwise
			# the client's read blocks forever waiting for something that
			# will never arrive (confirmed by direct testing: sending an
			# unrecognized command previously left the client hanging
			# indefinitely on its next read, even though the connection
			# itself stayed healthy for subsequent requests).
			log "gs-transfer-server: unknown command '$cmd'"
			printf 'ERR unknown command\n'
			;;
	esac
done
log "gs-transfer-server: EOF on stdin, exiting"
