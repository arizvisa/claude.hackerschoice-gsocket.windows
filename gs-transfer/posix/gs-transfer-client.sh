#!/usr/bin/env bash
# gs-transfer client - see ../PROTOCOL.md for the wire format.
#
# Usage:
#   gs-transfer-client.sh [-s <secret>|-k <file>] [-T] [-t <timeout>] [-r] ls [path]
#   gs-transfer-client.sh [-s <secret>|-k <file>] [-T] [-t <timeout>] [-r] get <remote-path> [local-path]
#   gs-transfer-client.sh [-s <secret>|-k <file>] [-T] [-t <timeout>] [-r] put <local-path> [remote-path]
#
# get/put take independent local and remote paths (sftp/scp-style) - the
# local path is whatever this machine's file is actually at (any valid
# local path, no restrictions), the remote path is what gets sent on the
# wire (subject to ../PROTOCOL.md's "Path rules"). Each defaults to the
# other's basename if omitted, e.g. `put /home/me/report.txt` uploads to
# plain "report.txt" remotely, and `get logs/data.bin` saves to plain
# "data.bin" locally. Passing the same absolute local path as the remote
# path (e.g. `put /home/me/report.txt /home/me/report.txt`) will fail -
# the remote responder only ever accepts relative paths.
#
# -r recurses into directories for ls/get/put, rsync -r style - the
# source path's trailing slash controls whether its own basename becomes
# an extra destination directory level:
#   put -r photos     dst  ->  dst/photos/...   (no trailing slash: source's
#                                                 name is kept as a level)
#   put -r photos/    dst  ->  dst/...          (trailing slash: only the
#                                                 contents move, flattened
#                                                 into dst itself)
# identically for `get -r <remote> [local]`, with remote/local swapped.
# -r on a plain file (not a directory) is a no-op; the single-file path
# is used as-is. This is entirely a client-side concern - the wire
# protocol has no recursion of its own; MKDIR plus repeated LIST/GET/PUT
# calls do all of it (see ../PROTOCOL.md).
#
# get/put resume automatically whenever an interrupted attempt left a
# usable partial behind - no flag needed. See ../PROTOCOL.md's
# "Partial-file safety" for the full mechanism; the short version: a
# deterministic .<basename>.partial sibling, created with bash's
# noclobber (atomic - never follows or overwrites a pre-existing path,
# symlink included), and never trusted for a resume without hashing the
# overlap - the bytes already transferred - against the same range on
# the other side first.
#
# -s/-k/-T are gs-netcat's own flags, passed straight through to the
# gs-netcat subprocess unchanged - no new secret-handling or proxy
# mechanism invented here. -k <file> reads the secret from a file
# instead of argv (gs-netcat's own man page recommends this specifically
# because a secret on the command line is visible in `ps`/shell history
# - -k wins if both -s and -k are given, same precedence gs-netcat's own
# GS_user_secret() already applies, not reimplemented here). -T routes
# the connection through a SOCKS5 proxy (normally TOR on 127.0.0.1:9050,
# overridable via GSOCKET_SOCKS_IP/GSOCKET_SOCKS_PORT - gs-netcat's own
# env vars, not this script's). If none of -s/-k are given, falls
# through to gs-netcat's own GSOCKET_ARGS/interactive prompt handling -
# same convention as every other gsocket tool.
#
# -t sets how long (seconds) to wait for a control-line response before
# giving up - default 30. Without this, a request the responder never
# answers (a crash, a protocol mismatch, a dead connection) left this
# script blocked forever; confirmed and fixed - see the server's own
# "every request must get a response" comment for the matching
# root-cause fix on that side. Actual data transfer (a GET/PUT payload)
# gets its own, larger bound - DATA_TIMEOUT below - since it has to
# cover the whole file, not just the first byte.
set -u

# Computed once, not per-check - uname -o spawns a subprocess, and
# is_safe_partial below can run many times during a transfer. uname -o
# is a GNU/MSYS/Cygwin extension (absent on macOS/BSD, where the
# lookup fails safely to "no") - it's what distinguishes a real MSYS/
# Cygwin environment from a native Linux/macOS one, which is exactly
# where is_cygwin_symlink below needs to actually do anything.
case "$(uname -o 2>/dev/null)" in
	Msys | Cygwin) IS_MSYS_LIKE=1 ;;
	*) IS_MSYS_LIKE=0 ;;
esac

DATA_TIMEOUT=300

GS_NETCAT_BIN="gs-netcat"
# Prefer a gs-netcat sitting next to this script, same lookup blitz uses.
BIN="$(cd "$(dirname "${0}")" >/dev/null 2>&1 && pwd)/${GS_NETCAT_BIN}"
[[ -f "${BIN}" ]] && GS_NETCAT_BIN="${BIN}"
command -v "${GS_NETCAT_BIN}" >/dev/null 2>&1 || { echo >&2 "${GS_NETCAT_BIN} not found. Check PATH=?"; exit 1; }

usage() {
	echo >&2 "Usage: $0 [-s <secret>|-k <file>] [-T] [-t <timeout>] [-r] ls [path] | get <remote-path> [local-path] | put <local-path> [remote-path]"
	exit 1
}

SECRET=""
SECFILE=""
USE_TOR=0
TIMEOUT=30
RECURSIVE=0
while getopts ":s:k:Tt:r" opt; do
	case "$opt" in
		s) SECRET="$OPTARG" ;;
		k) SECFILE="$OPTARG" ;;
		T) USE_TOR=1 ;;
		t) TIMEOUT="$OPTARG" ;;
		r) RECURSIVE=1 ;;
		*) usage ;;
	esac
done
shift $((OPTIND - 1))

cmd="${1:-}"
[[ -n "$cmd" ]] || usage

GSNC_ARGS=()
[[ -n "$SECRET" ]] && GSNC_ARGS+=(-s "$SECRET")
[[ -n "$SECFILE" ]] && GSNC_ARGS+=(-k "$SECFILE")
[[ "$USE_TOR" == "1" ]] && GSNC_ARGS+=(-T)

coproc GSNC { "$GS_NETCAT_BIN" "${GSNC_ARGS[@]}"; }
# Duplicate to stable fd numbers immediately - the standard, robust bash
# coproc idiom (the raw ${GSNC[0]}/${GSNC[1]} indices aren't safe to reuse
# across multiple redirections).
exec 3<&"${GSNC[0]}" 4>&"${GSNC[1]}"

quit() {
	printf 'QUIT\n' >&4 2>/dev/null
	exec 3<&- 4>&- 2>/dev/null
	# Give gs-netcat a few seconds to exit on its own after QUIT; if it
	# doesn't, kill this exact PID - never by image name (a shared-machine
	# "taskkill by name" mistake took down unrelated processes earlier in
	# this project; this only ever targets the specific PID this script
	# itself captured when it spawned the coproc).
	( sleep 3; kill -0 "$GSNC_PID" 2>/dev/null && kill "$GSNC_PID" 2>/dev/null ) &
	local watchdog=$!
	wait "$GSNC_PID" 2>/dev/null
	kill "$watchdog" 2>/dev/null
	wait "$watchdog" 2>/dev/null
}
trap quit EXIT

# Bytes -> "118K"/"3.4M" style. Falls back to the raw byte count if
# numfmt isn't available, rather than failing outright.
human_size() {
	numfmt --to=iec --suffix=B --format='%.1f' -- "$1" 2>/dev/null || printf '%sB' "$1"
}

# Unix epoch -> "2026-11-02 14:30" style, local time. Same raw-fallback
# philosophy as human_size.
human_date() {
	date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$1"
}

# Reads one control line with the configured timeout. Prints a clear
# message and returns failure on timeout/EOF instead of leaving the
# caller blocked.
read_response() {
	if ! read -t "$TIMEOUT" -r "$1" <&3; then
		echo >&2 "timed out (${TIMEOUT}s) or lost connection waiting for a response"
		return 1
	fi
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
	if [[ "$dir" == "." ]]; then
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

# Joins a wire-format remote path, collapsing a "." (or empty) base so
# the result doesn't carry an ugly "./" prefix - "." and "" both mean
# "the responder's own starting directory" on the wire (see do_list's
# own "${1:-.}" default and is_safe_path's acceptance of ".").
join_path() {
	local base="$1" name="$2"
	if [[ -z "$base" || "$base" == "." ]]; then
		printf '%s\n' "$name"
	else
		printf '%s/%s\n' "$base" "$name"
	fi
}

# rsync -r trailing-slash semantics: if $src ends with /, its own
# contents land directly in $dest_root; otherwise $src's basename is
# appended as an extra destination directory level. Applies identically
# whether an explicit destination was given or defaulted to "." - see
# the -r block in the header comment for worked examples.
effective_dest() {
	local src="$1" dest_root="${2%/}"
	[[ -n "$dest_root" ]] || dest_root="."
	case "$src" in
		*/)
			printf '%s\n' "$dest_root"
			;;
		*)
			if [[ "$dest_root" == "." ]]; then
				basename -- "$src"
			else
				printf '%s/%s\n' "$dest_root" "$(basename -- "$src")"
			fi
			;;
	esac
}

print_listing_line() {
	local type="$1" size="$2" mtime="$3" name="$4"
	if [[ "$type" == "D" ]]; then
		printf '%-10s  %-16s  %s/\n' "-" "$(human_date "$mtime")" "$name"
	else
		printf '%-10s  %-16s  %s\n' "$(human_size "$size")" "$(human_date "$mtime")" "$name"
	fi
}

print_recursive_listing_line() {
	local type="$1" size="$2" mtime="$3" relpath="$4" root="$5"
	print_listing_line "$type" "$size" "$mtime" "$(join_path "$root" "$relpath")"
}

# Recursively walks $remote_root (a directory on the responder) via
# repeated LIST calls - the wire protocol has no recursion of its own.
# Invokes $callback once per entry found, as:
#   callback <type> <size> <mtime> <relpath> <remote_root>
# where <relpath> is always relative to $remote_root and always /-
# separated, regardless of the responder's own platform.
remote_walk() {
	local remote_root="$1" callback="$2"
	local -a dirs=("")
	local -a ptype psize pmtime prel
	local rel full line rest type size mtime name relpath i
	while [[ ${#dirs[@]} -gt 0 ]]; do
		rel="${dirs[0]}"
		dirs=("${dirs[@]:1}")
		if [[ -z "$rel" ]]; then
			full="$remote_root"
		else
			full=$(join_path "$remote_root" "$rel")
		fi
		printf 'LIST %s\n' "$full" >&4
		# Fully drain this LIST's response (through END) before invoking
		# any callback - the wire protocol is strictly request/response,
		# and the responder doesn't read a new request until it has
		# finished writing the previous one's entire response. Calling
		# the callback per-line, before END, let a callback that issues
		# its own request (GET) collide with this LIST's still-in-flight
		# remaining entries - confirmed by a loopback test: the GET's
		# "read the response" call read a trailing LIST entry line
		# instead, because the responder hadn't even reached the GET
		# request yet.
		ptype=() psize=() pmtime=() prel=()
		while true; do
			if ! read -t "$TIMEOUT" -r line <&3; then
				echo >&2 "timed out (${TIMEOUT}s) or lost connection waiting for a response"
				exit 1
			fi
			[[ "$line" == "END" ]] && break
			case "$line" in
				ERR\ *) echo >&2 "server: ${line#ERR } ($full)"; exit 1 ;;
			esac
			type=${line%% *}; rest=${line#* }
			size=${rest%% *}; rest=${rest#* }
			mtime=${rest%% *}; name=${rest#* }
			if [[ -z "$rel" ]]; then
				relpath="$name"
			else
				relpath="$rel/$name"
			fi
			ptype+=("$type"); psize+=("$size"); pmtime+=("$mtime"); prel+=("$relpath")
		done
		for ((i = 0; i < ${#prel[@]}; i++)); do
			"$callback" "${ptype[$i]}" "${psize[$i]}" "${pmtime[$i]}" "${prel[$i]}" "$remote_root"
			[[ "${ptype[$i]}" == "D" ]] && dirs+=("${prel[$i]}")
		done
	done
}

remote_mkdir() {
	local path="$1" resp
	printf 'MKDIR %s\n' "$path" >&4
	read_response resp || return 1
	case "$resp" in
		OK) return 0 ;;
		ERR\ *) echo >&2 "server: ${resp#ERR } (mkdir $path)"; return 1 ;;
		*) echo >&2 "unexpected response: $resp"; return 1 ;;
	esac
}

# Shared single-file GET - used directly by the `get` command and, via
# recursive_get's get_one callback, by `get -r` too, so resume behaves
# identically either way. See ../PROTOCOL.md's "Partial-file safety".
do_get_file() {
	local remote="$1" local_path="$2"
	local localdir partial offset claimed_hash resp n

	localdir=$(dirname -- "$local_path")
	[[ "$localdir" == "." ]] || mkdir -p -- "$localdir"
	partial=$(partial_path "$local_path")

	offset=""
	if is_safe_partial "$partial"; then
		offset=$(stat --format='%s' -- "$partial" 2>/dev/null) || offset=""
		[[ "$offset" == "0" ]] && offset=""
	fi

	if [[ -n "$offset" ]]; then
		claimed_hash=$(prefix_hash "$partial" "$offset")
		printf 'GET %s %s %s\n' "$remote" "$offset" "$claimed_hash" >&4
	else
		printf 'GET %s\n' "$remote" >&4
	fi

	read_response resp || exit 1
	case "$resp" in
		OK\ *)
			n="${resp#OK }"
			if [[ -n "$offset" ]]; then
				if ! timeout "$DATA_TIMEOUT" head -c "$n" <&3 >> "$partial"; then
					echo >&2 "timed out (${DATA_TIMEOUT}s) or lost connection while receiving data - partial kept for a later resume"
					exit 1
				fi
			else
				if ! create_exclusive "$partial"; then
					echo >&2 "staging path blocked: $partial already exists and isn't a plain file"
					exit 1
				fi
				if ! timeout "$DATA_TIMEOUT" head -c "$n" <&3 > "$partial"; then
					echo >&2 "timed out (${DATA_TIMEOUT}s) or lost connection while receiving data - partial kept for a later resume"
					exit 1
				fi
			fi
			mv -f -- "$partial" "$local_path"
			if [[ -n "$offset" ]]; then
				echo "got $remote -> $local_path ($(human_size "$((offset + n))"), resumed from $(human_size "$offset"))"
			else
				echo "got $remote -> $local_path ($(human_size "$n"))"
			fi
			;;
		ERR\ *)
			if [[ -n "$offset" ]]; then
				echo >&2 "resume rejected (${resp#ERR }); discarding partial and retrying fresh"
				rm -f -- "$partial"
				do_get_file "$remote" "$local_path"
				return
			fi
			echo >&2 "server: ${resp#ERR }"
			exit 1
			;;
		*) echo >&2 "unexpected response: $resp"; exit 1 ;;
	esac
}

# Shared single-file PUT - used directly by the `put` command and, via
# recursive_put's loop body, by `put -r` too. PUT is a 4-step handshake
# (see ../PROTOCOL.md's "Wire format") because, unlike GET, the side
# with the partial (the responder) isn't the side that knows what to do
# about it (us) - so it has to offer first.
do_put_file() {
	local local_path="$1" remote="$2"
	local size resp offer_offset offer_hash local_hash resume_offset remaining

	size=$(stat --format='%s' -- "$local_path") || exit 1
	printf 'PUT %s %s\n' "$remote" "$size" >&4

	resume_offset=""
	read_response resp || exit 1
	case "$resp" in
		FRESH) : ;;
		RESUME\ *)
			offer_offset=${resp#RESUME }
			offer_hash=${offer_offset#* }
			offer_offset=${offer_offset%% *}
			if [[ "$offer_offset" =~ ^[0-9]+$ ]] && [ "$offer_offset" -le "$size" ]; then
				local_hash=$(prefix_hash "$local_path" "$offer_offset")
				[[ "$local_hash" == "$offer_hash" ]] && resume_offset="$offer_offset"
			fi
			;;
		ERR\ *) echo >&2 "server: ${resp#ERR }"; exit 1 ;;
		*) echo >&2 "unexpected response: $resp"; exit 1 ;;
	esac

	if [[ -n "$resume_offset" ]]; then
		printf 'RESUME %s\n' "$resume_offset" >&4
	else
		printf 'RESTART\n' >&4
		resume_offset=0
	fi
	remaining=$((size - resume_offset))

	if [ "$remaining" -gt 0 ]; then
		if ! timeout "$DATA_TIMEOUT" tail -c "+$((resume_offset + 1))" -- "$local_path" >&4; then
			echo >&2 "timed out (${DATA_TIMEOUT}s) or lost connection while sending data"
			exit 1
		fi
	fi

	read_response resp || exit 1
	case "$resp" in
		OK)
			if [ "$resume_offset" -gt 0 ]; then
				echo "put $local_path -> $remote ($(human_size "$size"), resumed from $(human_size "$resume_offset"))"
			else
				echo "put $local_path -> $remote ($(human_size "$size"))"
			fi
			;;
		ERR\ *) echo >&2 "server: ${resp#ERR }"; exit 1 ;;
		*) echo >&2 "unexpected response: $resp"; exit 1 ;;
	esac
}

# Uploads $local_root (a directory, no trailing slash) to $remote_dest
# (already run through effective_dest), preserving the local tree
# structure. Every directory - including empty ones - gets an explicit
# MKDIR; files go through do_put_file. find's default pre-order
# traversal guarantees a directory's MKDIR always lands before its
# children.
recursive_put() {
	local local_root="$1" remote_dest="$2"
	remote_mkdir "$remote_dest" || exit 1
	local entry rel remote_path
	while IFS= read -r entry; do
		rel="${entry#"$local_root"/}"
		remote_path=$(join_path "$remote_dest" "$rel")
		if [[ -d "$entry" ]]; then
			remote_mkdir "$remote_path" || exit 1
		elif [[ -f "$entry" ]]; then
			do_put_file "$entry" "$remote_path"
		fi
	done < <(find "$local_root" -mindepth 1)
}

# Set by recursive_get just before it calls remote_walk; read by get_one
# below. A plain global (not a function-local) is the simplest way to
# hand this one extra piece of context to a callback whose signature is
# fixed by remote_walk - this script only ever runs one transfer per
# invocation, so there's no reentrancy concern.
LOCAL_DEST=""

recursive_get() {
	local remote_root="$1"
	LOCAL_DEST="$2"
	mkdir -p -- "$LOCAL_DEST" || exit 1
	remote_walk "$remote_root" get_one
}

get_one() {
	local type="$1" size="$2" mtime="$3" relpath="$4" root="$5"
	local full_remote full_local
	full_remote=$(join_path "$root" "$relpath")
	full_local="$LOCAL_DEST/$relpath"
	if [[ "$type" == "D" ]]; then
		mkdir -p -- "$full_local"
		return
	fi
	do_get_file "$full_remote" "$full_local"
}

case "$cmd" in
	ls)
		path="${2:-}"
		if [[ "$RECURSIVE" == "1" ]]; then
			path_clean="${path%/}"
			[[ -n "$path_clean" ]] || path_clean="."
			remote_walk "$path_clean" print_recursive_listing_line
		else
			printf 'LIST %s\n' "$path" >&4
			while true; do
				if ! read -t "$TIMEOUT" -r line <&3; then
					echo >&2 "timed out (${TIMEOUT}s) or lost connection waiting for a response"
					exit 1
				fi
				[[ "$line" == "END" ]] && break
				case "$line" in
					ERR\ *) echo >&2 "server: ${line#ERR }"; exit 1 ;;
				esac
				# <type> <size> <mtime> <name>
				type=${line%% *}; rest=${line#* }
				size=${rest%% *}; rest=${rest#* }
				mtime=${rest%% *}; name=${rest#* }
				print_listing_line "$type" "$size" "$mtime" "$name"
			done
		fi
		;;
	get)
		remote_raw="${2:-}"
		dest_root="${3:-}"
		[[ -n "$remote_raw" ]] || { echo >&2 "get requires a remote path"; exit 1; }
		if [[ "$RECURSIVE" == "1" ]]; then
			local_dest=$(effective_dest "$remote_raw" "$dest_root")
			remote_clean="${remote_raw%/}"
			[[ -n "$remote_clean" ]] || remote_clean="."
			recursive_get "$remote_clean" "$local_dest"
		else
			local_path="${dest_root:-$(basename -- "$remote_raw")}"
			do_get_file "$remote_raw" "$local_path"
		fi
		;;
	put)
		local_raw="${2:-}"
		dest_root="${3:-}"
		[[ -n "$local_raw" ]] || { echo >&2 "put requires a local path"; exit 1; }
		[[ -e "$local_raw" ]] || { echo >&2 "no such file or directory: $local_raw"; exit 1; }
		if [[ "$RECURSIVE" == "1" ]] && [[ -d "$local_raw" ]]; then
			remote_dest=$(effective_dest "$local_raw" "$dest_root")
			local_clean="${local_raw%/}"
			[[ -n "$local_clean" ]] || local_clean="/"
			recursive_put "$local_clean" "$remote_dest"
		else
			[[ -f "$local_raw" ]] || { echo >&2 "not a regular file: $local_raw"; exit 1; }
			remote="${dest_root:-$(basename -- "$local_raw")}"
			do_put_file "$local_raw" "$remote"
		fi
		;;
	*)
		usage
		;;
esac
