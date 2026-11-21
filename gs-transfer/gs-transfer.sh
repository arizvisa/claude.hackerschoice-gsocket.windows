#!/usr/bin/env bash
# gs-transfer (POSIX) - single-deployable client+server. See ../PROTOCOL.md
# for the wire format.
#
# -l selects server (responder) mode, exactly like gs-netcat's own -l.
# Without -l, this runs the client.
#
# Usage:
#   gs-transfer.sh -l [-s <secret>|-k <file>] [-T]
#       Server mode. Launches gs-netcat itself (-l, plus whatever secret/
#       proxy flags were given) with -e pointing back at this same script -
#       no gs-netcat command line to construct by hand. Can also still be
#       driven manually, exactly as before this script could launch
#       gs-netcat on its own:
#         GSTRANSFER_WORKER=1 gs-netcat -s <secret> -l -e /path/to/gs-transfer.sh
#       (see the GSTRANSFER_WORKER check below - that path never sets -l,
#       it re-execs this same script with no args at all, so
#       GSTRANSFER_WORKER=1 has to be set explicitly to tell it to run as
#       a worker instead of a client).
#
#   gs-transfer.sh [-s <secret>|-k <file>] [-T] [-t <timeout>] ls [-r] [-1] [--] [path]
#   gs-transfer.sh [-s <secret>|-k <file>] [-T] [-t <timeout>] get [-r] [--] <remote-path> [local-path]
#   gs-transfer.sh [-s <secret>|-k <file>] [-T] [-t <timeout>] put [-r] [--] <local-path> [remote-path]
#   gs-transfer.sh [-s <secret>|-k <file>] [-T] [-t <timeout>] pwd
#   gs-transfer.sh [-s <secret>|-k <file>] [-T] [-t <timeout>] mkdir <remote-path>
#   gs-transfer.sh [-s <secret>|-k <file>] [-T] [-t <timeout>] stat [path]
#       Client mode (default, no -l). pwd reports the responder's own
#       starting directory - what "." means on the wire. mkdir always
#       creates the whole tree (mkdir -p semantics) - the responder's
#       MKDIR already works that way unconditionally (see do_mkdir's own
#       comment), so there's no flag needed to ask for it. stat prints
#       type/size/mtime/atime/birthtime, plus immediate file/dir counts
#       for a directory - a single STAT request, no LIST/RECURSE
#       pagination involved.
#
#       -r/-1 are subcommand-local flags, parsed after the subcommand
#       name (not before, like -s/-k/-T/-t above) - ls/get/put each run
#       their own getopts pass on their own argv. A literal "--" there
#       forces everything after it to be read as a positional argument,
#       never a flag - e.g. `ls -- -oddly-named-file` for a remote file
#       that actually starts with a dash.
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
# -t sets how long (seconds, client only) to wait for a control-line
# response before giving up - default 30. Without this, a request the
# responder never answers (a crash, a protocol mismatch, a dead
# connection) left this script blocked forever. Actual data transfer (a
# GET/PUT payload) gets its own, larger bound - DATA_TIMEOUT below -
# since it has to cover the whole file, not just the first byte.
set -u

# Computed once, not per-check - uname -o spawns a subprocess, and
# is_safe_partial below can run many times during a transfer. uname -o
# is a GNU/MSYS/Cygwin extension (absent on macOS/BSD, where the
# lookup fails safely to "no") - it's what distinguishes a real MSYS/
# Cygwin environment from a native Linux/macOS one.
case "$(uname -o 2>/dev/null)" in
	Msys | Cygwin) IS_MSYS_LIKE=1 ;;
	*) IS_MSYS_LIKE=0 ;;
esac

DATA_TIMEOUT=300

# ============================================================================
# Shared helpers - identical between what used to be the separate client and
# server scripts, kept as one copy here.
# ============================================================================

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
# and to -f/-L, which see nothing but a plain regular file.
is_cygwin_symlink() {
	local p="$1"
	[[ "$IS_MSYS_LIKE" == "1" ]] || return 1
	[[ "$(head -c 10 -- "$p" 2>/dev/null)" == '!<symlink>' ]]
}

# A partial is only trustworthy if it's a plain regular file - never a
# symlink, even one pointing at a legitimate file (it could be swapped
# out from under us, or planted by another party on a shared
# directory). is_cygwin_symlink above covers the other kind of
# "symlink" -L can't see at all.
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

# ============================================================================
# Worker mode - gs-netcat's own -e exec'd this same script fresh, with
# stdin/stdout now wired to the tunnel. Checked first, unconditionally,
# before any argv parsing: gs-netcat's -e passes no arguments at all, so
# this has to be detected from the environment, not from -l - the -l
# launcher branch below sets GSTRANSFER_WORKER=1 itself right before
# exec'ing gs-netcat, so it's inherited by every worker -e spawns.
#
# This used to also accept "stdin is a pipe" ([[ -p /dev/stdin ]]) as a
# second, fallback signal, to keep the old manual-launch style working
# without requiring the env var:
#   gs-netcat -s <secret> -l -e /path/to/gs-transfer.sh
# Dropped: a pipe-type (or pipe-like) stdin is not unique to gs-netcat's
# -e - e.g. `parallel -j1 --ungroup gs-transfer.sh -s secret ls {} ::: ...`
# triggered this for an ordinary client invocation, which then read EOF
# immediately and exited instead of running the client at all. The
# manual-launch style above now needs GSTRANSFER_WORKER=1 set explicitly
# (see the server-mode header comment above) - the single unambiguous
# signal, not a heuristic that happens to also match other tools.
# ============================================================================
if [[ "${GSTRANSFER_WORKER:-}" == "1" ]]; then
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

	# Reports the responder's own starting directory - what "." on the
	# wire actually resolves to from the caller's side, since every path
	# LIST/GET/PUT/MKDIR accepts is relative to it.
	do_pwd() {
		printf 'OK %s\n' "$(pwd)"
	}

	# Shared by do_list/do_recurse: reads a newline-separated, already
	# LC_ALL=C-sorted list of names relative to $dir from stdin (bare
	# basenames for do_list, full /-joined relpaths for do_recurse), and
	# streams "<type> <size> <mtime> <name>" per entry - honoring an
	# optional <maxcount>/<cursor> page window - then a plain "END" or
	# "MORE <cursor>" if more remain. Sort order must be stable across
	# calls for cursor-skipping to mean anything, which is why the two
	# callers both force LC_ALL=C rather than the locale-dependent default.
	#
	# Cursor matching is exact-equality, never an ordering comparison
	# ([[ a < b ]] in bash is itself locale-collation-dependent, which
	# would silently disagree with the LC_ALL=C sort that produced this
	# list) - skip everything through the line equal to <cursor>, resume
	# right after. Known, accepted edge case: if the tree changed between
	# pages and <cursor>'s exact value no longer exists, the rest of this
	# page is skipped entirely (nothing after it will ever match) rather
	# than guessing a nearby resume point - same "document it, don't
	# engineer around it" spirit as this file's other edge-case notes.
	emit_paginated_listing() {
		local dir="$1" maxcount="$2" cursor="$3"
		local name full type size mtime count=0 last="" skipping=0 next_name
		[ -n "$cursor" ] && skipping=1
		while IFS= read -r name; do
			[ -n "$name" ] || continue
			if [ "$skipping" = "1" ]; then
				[ "$name" = "$cursor" ] && skipping=0
				continue
			fi
			if [ "$dir" = "." ]; then
				full="$name"
			else
				full="$dir/$name"
			fi
			if [ -d "$full" ]; then
				type="D"; size=0
			elif [ -f "$full" ]; then
				type="F"
				size=$(stat --format='%s' -- "$full" 2>/dev/null) || continue
			else
				continue   # skip symlinks/devices/etc.
			fi
			mtime=$(stat --format='%Y' -- "$full" 2>/dev/null) || continue
			printf '%s %s %s %s\n' "$type" "$size" "$mtime" "$name"
			last="$name"
			count=$((count + 1))
			if [ -n "$maxcount" ] && [ "$count" -ge "$maxcount" ]; then
				# Peek for anything left; each page re-walks from scratch
				# so discarding this one peeked line costs nothing - it's
				# simply re-produced (and re-skipped-past-cursor) next page.
				if IFS= read -r next_name; then
					printf 'MORE %s\n' "$last"
					return
				fi
				break
			fi
		done
		printf 'END\n'
	}

	# A trailing "/" is meaningful here (unlike every other verb, which
	# just trims it) - it's what disambiguates "list this directory's
	# own entry" from "list its contents", the same distinction real
	# shells make (`ls junk` vs `ls junk/`). "." (root) has no parent to
	# show it relative to, so it always means contents, slash or not.
	do_list() {
		local dir="${1:-.}" maxcount="${2:-}" cursor="${3:-}" f want_contents=0
		[ "$dir" = "." ] && want_contents=1
		if [[ "$dir" == */ ]] && [ "$dir" != "." ]; then
			dir="${dir%/}"
			want_contents=1
		fi
		if [ "$dir" != "." ]; then
			if ! is_safe_path "$dir"; then
				printf 'ERR invalid path\n'
				return
			fi
			if [ -f "$dir" ]; then
				if [ "$want_contents" = "1" ]; then
					# Trailing "/" on a path that's actually a file -
					# mirrors real `ls file.txt/` rather than silently
					# falling back to a single-file listing.
					printf 'ERR not a directory\n'
					return
				fi
				# A single file, not a directory - matches real `ls
				# <file>`: list just that one entry instead of erroring,
				# reusing the exact same emission emit_paginated_listing
				# already does for a directory's own contents.
				emit_paginated_listing "$(dirname -- "$dir")" "$maxcount" "$cursor" < <(basename -- "$dir")
				return
			fi
			if [ ! -d "$dir" ]; then
				printf 'ERR not found\n'
				return
			fi
			if [ "$want_contents" != "1" ]; then
				# Bare directory name, no trailing "/": list just this
				# one entry (the directory itself), same as the
				# single-file case above - a trailing "/" is what asks
				# for contents instead.
				emit_paginated_listing "$(dirname -- "$dir")" "$maxcount" "$cursor" < <(basename -- "$dir")
				return
			fi
		fi
		emit_paginated_listing "$dir" "$maxcount" "$cursor" < <(
			for f in "$dir"/*; do
				[ -e "$f" ] || continue   # unmatched glob (empty directory)
				basename -- "$f"
			done | LC_ALL=C sort
		)
	}

	# Recursive counterpart of do_list - walks the whole subtree natively
	# (never follows symlinks by default, same as the glob loop above
	# never descends into one either) instead of the client doing a BFS
	# via repeated LIST calls. Dotfiles/dotdirs (at any depth) are
	# excluded explicitly, since find has no such built-in convention the
	# way a bare glob does - do_list's "$dir"/* loop already hides them
	# for free via bash's own default (non-dotglob) glob behavior, and
	# this must match that, not least because it's what keeps this
	# project's own .<name>.partial staging files from leaking into a
	# recursive listing.
	do_recurse() {
		local dir="${1:-.}" maxcount="${2:-}" cursor="${3:-}"
		dir="${dir%/}"
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
		emit_paginated_listing "$dir" "$maxcount" "$cursor" < <(
			find "$dir" -mindepth 1 -printf '%P\n' 2>/dev/null | while IFS= read -r p; do
				case "/$p" in
					*/.*) continue ;;   # dotfile/dotdir at any depth
				esac
				printf '%s\n' "$p"
			done | LC_ALL=C sort
		)
	}

	# Cheap single-path metadata - every field exists to let the client
	# make some specific decision without an extra round trip (see
	# docs/gs-transfer-backend-plan.md for the full per-field reasoning,
	# not just "it was available"): <type> decides GET vs
	# RECURSE/LIST next; <size> decides whether to even attempt a
	# transfer; <mtime> enables sync-style skip-if-unchanged logic;
	# <atime> is included but known-unreliable on both platforms (Linux
	# noatime/relatime, Windows disables last-access tracking by default
	# since Vista) - don't trust it for anything load-bearing; <birthtime>
	# is GNU stat's own "%W ... 0 if unknown" fallback passed straight
	# through, no translation needed; <file_count>/<dir_count> (immediate
	# children only, directories only - 0/0 for a file) size whether a
	# client should bother paginating a later LIST/RECURSE at all.
	do_stat() {
		local path="$1" type size mtime atime btime file_count=0 dir_count=0 f
		path="${path%/}"
		if ! is_safe_path "$path"; then
			printf 'ERR invalid path\n'
			return
		fi
		if [ -d "$path" ]; then
			type="D"; size=0
			for f in "$path"/*; do
				[ -e "$f" ] || continue
				if [ -d "$f" ]; then
					dir_count=$((dir_count + 1))
				elif [ -f "$f" ]; then
					file_count=$((file_count + 1))
				fi
			done
		elif [ -f "$path" ]; then
			type="F"
			size=$(stat --format='%s' -- "$path" 2>/dev/null) || { printf 'ERR stat failed\n'; return; }
		else
			printf 'ERR not found\n'
			return
		fi
		mtime=$(stat --format='%Y' -- "$path" 2>/dev/null) || { printf 'ERR stat failed\n'; return; }
		atime=$(stat --format='%X' -- "$path" 2>/dev/null) || atime=0
		btime=$(stat --format='%W' -- "$path" 2>/dev/null) || btime=0
		printf 'OK %s %s %s %s %s %s %s\n' "$type" "$size" "$mtime" "$atime" "$btime" "$file_count" "$dir_count"
	}

	# Deliberately separate from do_stat, not an optional extra on it -
	# reading a whole file to hash it costs O(file size), the opposite of
	# do_stat's cheap-lookup nature. Reuses prefix_hash completely
	# unchanged: hashing the whole file is just n = the full size instead
	# of a resume offset, not new crypto code.
	do_hash() {
		local path="$1" size
		path="${path%/}"
		if ! is_safe_path "$path"; then
			printf 'ERR invalid path\n'
			return
		fi
		if [ -d "$path" ]; then
			printf 'ERR is a directory\n'
			return
		fi
		if [ ! -f "$path" ]; then
			printf 'ERR not found\n'
			return
		fi
		size=$(stat --format='%s' -- "$path" 2>/dev/null) || { printf 'ERR stat failed\n'; return; }
		printf 'OK %s\n' "$(prefix_hash "$path" "$size")"
	}

	do_get() {
		local path="$1" offset="${2:-}" claimed_hash="${3:-}" size actual_hash remaining
		path="${path%/}"
		if ! is_safe_path "$path"; then
			printf 'ERR invalid path\n'
			return
		fi
		if [ -d "$path" ]; then
			printf 'ERR is a directory - use recursive get (-r) instead\n'
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
		path="${path%/}"
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
			log "gs-transfer: client vanished mid-PUT handshake for '$path'"
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
			log "gs-transfer: unexpected PUT handshake reply '$decision'"
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
			log "gs-transfer: PUT resume offset mismatch for '$path' (offered $offer_offset, client said $dec_offset)"
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
			PWD) do_pwd ;;
			LIST)
				# [<path>] [<maxcount> [<cursor>]] - same trailing-field-
				# peeling idiom as GET/PUT below; <cursor> is free-form (may
				# itself contain spaces/slashes), so it's only ever
				# "whatever's left after peeling a leading <maxcount>
				# token", never split further itself.
				if [[ "$rest" =~ ^(.*)\ ([0-9]+)\ (.+)$ ]]; then
					do_list "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
				elif [[ "$rest" =~ ^(.*)\ ([0-9]+)$ ]]; then
					do_list "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" ""
				else
					do_list "$rest" "" ""
				fi
				;;
			RECURSE)
				# <path> [<maxcount> [<cursor>]] - identical parsing shape
				# to LIST above, see its own comment.
				if [[ "$rest" =~ ^(.*)\ ([0-9]+)\ (.+)$ ]]; then
					do_recurse "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
				elif [[ "$rest" =~ ^(.*)\ ([0-9]+)$ ]]; then
					do_recurse "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" ""
				else
					do_recurse "$rest" "" ""
				fi
				;;
			STAT) do_stat "$rest" ;;
			HASH) do_hash "$rest" ;;
			GET)
				# <path> [<offset> <hash>] - path may itself contain spaces
				# (already supported elsewhere, e.g. do_list's entries), so
				# this can only ever split off a trailing "<digits>
				# <64-hex-chars>" pair, never blindly split the whole line
				# on whitespace.
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
			QUIT) log "gs-transfer: QUIT"; exit 0 ;;
			*)
				# Every request must get a response, even a bad one - otherwise
				# the client's read blocks forever waiting for something that
				# will never arrive.
				log "gs-transfer: unknown command '$cmd'"
				printf 'ERR unknown command\n'
				;;
		esac
	done
	log "gs-transfer: EOF on stdin, exiting"
	exit 0
fi

# ============================================================================
# Argv parsing - shared between server (launcher) mode and client mode.
# -l is the discriminator: present -> server, absent -> client.
# ============================================================================
GS_NETCAT_BIN="gs-netcat"
# Prefer a gs-netcat sitting next to this script.
BIN="$(cd "$(dirname "${0}")" >/dev/null 2>&1 && pwd)/${GS_NETCAT_BIN}"
[[ -f "${BIN}" ]] && GS_NETCAT_BIN="${BIN}"
command -v "${GS_NETCAT_BIN}" >/dev/null 2>&1 || { echo >&2 "${GS_NETCAT_BIN} not found. Check PATH=?"; exit 1; }

usage() {
	echo >&2 "Usage: $0 -l [-s <secret>|-k <file>] [-T]"
	echo >&2 "       $0 [-s <secret>|-k <file>] [-T] [-t <timeout>] ls [-r] [-1] [--] [path] | get [-r] [--] <remote-path> [local-path] | put [-r] [--] <local-path> [remote-path] | pwd | mkdir <remote-path> | stat [path]"
	exit 1
}

LISTEN=0
SECRET=""
SECFILE=""
USE_TOR=0
TIMEOUT=30
while getopts ":ls:k:Tt:" opt; do
	case "$opt" in
		l) LISTEN=1 ;;
		s) SECRET="$OPTARG" ;;
		k) SECFILE="$OPTARG" ;;
		T) USE_TOR=1 ;;
		t) TIMEOUT="$OPTARG" ;;
		*) usage ;;
	esac
done
shift $((OPTIND - 1))

if [[ "$LISTEN" == "1" ]]; then
	# --- Server (launcher) mode: become gs-netcat -l, which will later
	# exec a fresh copy of this same script (in worker mode, via -e) for
	# each connection it accepts. ---
	GSNC_ARGS=(-l)
	[[ -n "$SECRET" ]] && GSNC_ARGS+=(-s "$SECRET")
	[[ -n "$SECFILE" ]] && GSNC_ARGS+=(-k "$SECFILE")
	[[ "$USE_TOR" == "1" ]] && GSNC_ARGS+=(-T)

	SELF="$(cd "$(dirname "${0}")" >/dev/null 2>&1 && pwd)/$(basename "${0}")"
	BASH_BIN="$(command -v bash)"

	# -e's value becomes whatever the underlying gs-netcat execs - never
	# bare "$SELF": a shebang is a #!-line convention the *kernel*
	# interprets on exec(), which a Windows CreateProcess (what
	# gs-netcat.exe actually calls) has no concept of at all. Explicitly
	# naming the interpreter works unconditionally on real POSIX too. Only
	# the *path style* depends on platform: on MSYS/Cygwin, $SELF and
	# $BASH_BIN are POSIX-style (/c/Users/...), which Windows'
	# CreateProcess can't resolve at all - cygpath -w converts both to the
	# Windows-style path CreateProcess actually needs.
	if [[ "$IS_MSYS_LIKE" == "1" ]]; then
		SELF="$(cygpath -w "$SELF")"
		BASH_BIN="$(cygpath -w "$BASH_BIN")"
	fi
	E_VALUE="\"$BASH_BIN\" \"$SELF\""

	export GSTRANSFER_WORKER=1
	exec "$GS_NETCAT_BIN" "${GSNC_ARGS[@]}" -e "$E_VALUE"
fi

# --- Client mode (default, no -l) ---

# Not exposed as a flag, same reasoning as DATA_TIMEOUT above: rarely the
# right thing to tune per-invocation. Used as <maxcount> for every
# LIST/RECURSE call this client makes - large enough that a typical
# directory completes in one round trip, small enough to bound
# worst-case response size for a pathological one.
PAGE_SIZE=1000

cmd="${1:-}"
[[ -n "$cmd" ]] || usage
cmd="${cmd,,}"
shift

# -r/-1 are subcommand-local flags (ls/get/put for -r, ls only for -1) -
# parsed one level down from the global getopts above, now that $@ is
# just this subcommand's own argv. OPTIND must be reset to 1 first -
# getopts doesn't do that automatically between calls, and without it
# this would resume from the global loop's stale index instead of
# starting over on the new $@. A bare "--" here is handled by getopts
# itself for free, same as above - it stops option parsing, so a
# dash-prefixed path (e.g. "-foo") can still be passed as "-- -foo".
RECURSIVE=0
SHOW_FULL_PATH=0
OPTIND=1
while getopts ":r1" opt; do
	case "$opt" in
		r) RECURSIVE=1 ;;
		1) SHOW_FULL_PATH=1 ;;
		*) usage ;;
	esac
done
shift $((OPTIND - 1))

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

# Joins a wire-format remote path, collapsing a "." (or empty) base so
# the result doesn't carry an ugly "./" prefix - "." and "" both mean
# "the responder's own starting directory" on the wire.
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
# appended as an extra destination directory level.
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

# -1's "no columns, just the path" renderer - the point is a clean,
# one-path-per-line list that's safe to capture/redirect and reuse
# later, matching real bash `ls -1`'s own bare-name-per-line output
# (just using the full server-relative path instead of a bare name,
# since gs-transfer's glob/recursive listings can span multiple
# directories where a bare name alone would be ambiguous). Applies
# uniformly to every listing path - plain, glob, and recursive - not
# just the plain case; see each callback below.
print_path_only_line() {
	printf '%s\n' "$4"
}

print_recursive_listing_line() {
	local type="$1" size="$2" mtime="$3" relpath="$4" root="$5"
	local full
	full=$(join_path "$root" "$relpath")
	if [[ "$SHOW_FULL_PATH" == "1" ]]; then
		print_path_only_line "$type" "$size" "$mtime" "$full"
	else
		print_listing_line "$type" "$size" "$mtime" "$full"
	fi
}

# True if $1 contains an *unescaped* glob metacharacter (*, ?, [, or {)
# anywhere - the trigger for glob matching in ls/get. A backslash
# escapes the very next character unconditionally (bash's own rule,
# not just before a special char), so an escaped "\*" etc. never
# counts. Deliberately conservative about [ and {: even a malformed
# one (no matching close, or otherwise unparseable) still triggers
# "treat as glob" here - glob_to_regex below degrades a malformed one
# back to a literal character anyway, so at worst this costs an
# unnecessary LIST/RECURSE round trip for what turns out to be an
# exact match, never an incorrect result. Accepted tradeoff, same one
# every shell glob already makes: a real remote filename literally
# containing one of these (unescaped) can no longer be fetched by
# exact name - escaping is the way out.
is_glob() {
	local s="$1"
	local i=0 n=${#s} c
	while ((i < n)); do
		c="${s:i:1}"
		if [[ "$c" == '\' ]] && ((i + 1 < n)); then
			i=$((i + 2))
			continue
		fi
		case "$c" in
			'*' | '?' | '[' | '{') return 0 ;;
		esac
		i=$((i + 1))
	done
	return 1
}

# Strips backslash-escapes from a path that is_glob already said isn't
# a glob at all - a user may still type e.g. "weird\*file" to be
# unambiguous about a literal special character even when the path as
# a whole has no real wildcard elsewhere, and that backslash must never
# reach the wire: the protocol has no escape-sequence concept of its
# own (is_safe_path rejects a literal "\" outright), so every non-glob
# path ls/get actually sends - plain or -r - runs through this first.
glob_unescape() {
	local s="$1"
	local out="" i=0 n=${#s} c
	while ((i < n)); do
		c="${s:i:1}"
		if [[ "$c" == '\' ]] && ((i + 1 < n)); then
			out+="${s:i+1:1}"
			i=$((i + 2))
			continue
		fi
		out+="$c"
		i=$((i + 1))
	done
	printf '%s' "$out"
}

# Splits $1 (a glob pattern) into GLOB_PREFIX (literal segments before
# the first wildcard segment, "." if none) and GLOB_SUFFIX (that segment
# through the end) - see docs/gs-transfer-client-plan.md (kept local,
# not part of this repo) for the full design. Plain globals, not a
# return value - same "simplest way to hand extra context" idiom this
# file already uses for LOCAL_DEST. Per-segment wildcard test reuses
# is_glob directly, so escaping stays consistent between "where does
# the literal prefix end" and "is this a glob at all" - one
# implementation, no drift between the two checks.
GLOB_PREFIX=""
GLOB_SUFFIX=""
glob_split() {
	local pattern="$1"
	local -a segs
	local IFS='/'
	read -ra segs <<< "$pattern"
	local i=0
	local -a prefix_parts=()
	while [[ $i -lt ${#segs[@]} ]]; do
		is_glob "${segs[$i]}" && break
		prefix_parts+=("${segs[$i]}")
		i=$((i + 1))
	done
	if [[ ${#prefix_parts[@]} -eq 0 ]]; then
		GLOB_PREFIX="."
	else
		GLOB_PREFIX="${prefix_parts[*]}"
	fi
	GLOB_SUFFIX="${segs[*]:$i}"
}

# Converts an ASCII letter code back to its character, for brace
# sequence expressions ({a..e} etc.) - a plain lookup table, not
# printf's own octal/hex escape tricks, which are fragile to transcribe
# correctly and not needed when the only inputs are A-Z/a-z (bash's own
# restriction for brace letter ranges too).
chr_letter() {
	local code="$1"
	if ((code >= 97 && code <= 122)); then
		local alphabet="abcdefghijklmnopqrstuvwxyz"
		printf '%s' "${alphabet:code-97:1}"
	elif ((code >= 65 && code <= 90)); then
		local alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
		printf '%s' "${alphabet:code-65:1}"
	fi
}

# Splits $1 on unescaped "," into GLOB_BRACE_ALTS (global array,
# consumed immediately by the caller - same dynamic-scoping idiom as
# GLOB_PREFIX/GLOB_SUFFIX above). An escaped comma (\,) stays part of
# its own alternative untouched, so the recursive glob_to_regex_body
# call on that alternative is what actually interprets the escape.
GLOB_BRACE_ALTS=()
glob_split_commas() {
	local s="$1"
	local i=0 n=${#s} c cur=""
	GLOB_BRACE_ALTS=()
	while ((i < n)); do
		c="${s:i:1}"
		if [[ "$c" == '\' ]] && ((i + 1 < n)); then
			cur+="${s:i:2}"
			i=$((i + 2))
			continue
		fi
		if [[ "$c" == "," ]]; then
			GLOB_BRACE_ALTS+=("$cur")
			cur=""
			i=$((i + 1))
			continue
		fi
		cur+="$c"
		i=$((i + 1))
	done
	GLOB_BRACE_ALTS+=("$cur")
}

# Parses $1 as a brace sequence expression ("x..y" or "x..y..incr") into
# GLOB_SEQ_TERMS (global array, same idiom as GLOB_BRACE_ALTS) - bash's
# own rule: x and y must be the same type (both integer or both a
# single letter); if either has a leading zero, every generated term is
# zero-padded to match the widest of the two; the default increment is 1
# (direction inferred from x <= y), an explicit increment's magnitude is
# used with the inferred direction (not replicating bash's exact
# behavior for a *given* increment whose sign already contradicts the
# x/y direction - vanishingly rare, not worth chasing). Returns 1
# (GLOB_SEQ_TERMS untouched) if $1 isn't a valid sequence expression at
# all. Integer parsing forces base 10 (10#...) throughout - bash
# arithmetic otherwise treats a leading-zero numeral as octal, which
# would misparse "08"/"09" or outright error.
GLOB_SEQ_TERMS=()
glob_brace_sequence_regex() {
	local inner="$1"
	local x y incr_raw incr x_num y_num width=0 step i term
	GLOB_SEQ_TERMS=()
	if [[ ! "$inner" =~ ^(-?[0-9]+|[A-Za-z])\.\.(-?[0-9]+|[A-Za-z])(\.\.(-?[0-9]+))?$ ]]; then
		return 1
	fi
	x="${BASH_REMATCH[1]}"
	y="${BASH_REMATCH[2]}"
	incr_raw="${BASH_REMATCH[4]}"
	if [[ "$x" =~ ^-?[0-9]+$ ]]; then
		[[ "$y" =~ ^-?[0-9]+$ ]] || return 1
		local xa="${x#-}" ya="${y#-}"
		if [[ ("$xa" == 0* && ${#xa} -gt 1) || ("$ya" == 0* && ${#ya} -gt 1) ]]; then
			width=${#xa}
			((${#ya} > width)) && width=${#ya}
		fi
		x_num=$((10#$xa)); [[ "$x" == -* ]] && x_num=$((-x_num))
		y_num=$((10#$ya)); [[ "$y" == -* ]] && y_num=$((-y_num))
		incr=1
		[[ -n "$incr_raw" ]] && incr=$((10#${incr_raw#-}))
		((incr == 0)) && incr=1
		if ((x_num <= y_num)); then step=$incr; else step=$((-incr)); fi
		i=$x_num
		while :; do
			if ((step > 0 && i > y_num)); then break; fi
			if ((step < 0 && i < y_num)); then break; fi
			local neg=0 absterm="$i"
			if ((i < 0)); then neg=1; absterm="${i#-}"; fi
			term="$absterm"
			while ((width > 0 && ${#term} < width)); do term="0$term"; done
			((neg)) && term="-$term"
			GLOB_SEQ_TERMS+=("$term")
			i=$((i + step))
		done
	else
		[[ "$x" =~ ^[A-Za-z]$ ]] || return 1
		[[ "$y" =~ ^[A-Za-z]$ ]] || return 1
		local xo yo stepc co
		xo=$(printf '%d' "'$x")
		yo=$(printf '%d' "'$y")
		stepc=1
		[[ -n "$incr_raw" ]] && stepc=$((10#${incr_raw#-}))
		((stepc == 0)) && stepc=1
		if ((xo <= yo)); then step=$stepc; else step=$((-stepc)); fi
		co=$xo
		while :; do
			if ((step > 0 && co > yo)); then break; fi
			if ((step < 0 && co < yo)); then break; fi
			GLOB_SEQ_TERMS+=("$(chr_letter "$co")")
			co=$((co + step))
		done
	fi
	return 0
}

# Translates $1 (a glob suffix - see glob_split) into a POSIX ERE body
# (no anchors - glob_to_regex below adds ^...$ at the top level;
# recursive calls for brace alternatives call this directly to get just
# the body). * -> [^/]*, ? -> [^/], **/ -> zero-or-more whole segments
# ((.*/)?) - makes **/*.txt match both readme.txt (root) and
# a/b/readme.txt (any depth) - bare ** (no following /) -> .*,
# everything else escaped as a literal. Known, accepted asymmetry: a
# *trailing* bare ** with nothing after it (photos/**) falls through to
# the generic .* branch rather than getting the same "optional"
# treatment, so it requires an actual / plus something after photos -
# not worth special-casing for a pattern shape nobody asked for.
#
# \X escapes the very next character unconditionally, not just before
# a special one - the escaping backslash is discarded, same rule bash
# itself uses.
#
# [...] bracket expressions translate almost verbatim - POSIX ERE
# already supports the same plain set/range/negation syntax bash's own
# bracket expressions use. Only normalization needed: bash accepts
# *either* "!" or "^" for negation, ERE only recognizes "^". A "]"
# immediately after "[" or after a leading "!"/"^" is a literal member
# of the set, not the closing bracket (bash's own rule). No matching
# "]" at all -> malformed, falls through to a literal "\[" (matches
# bash's "incorrectly formed... left unchanged" philosophy). No POSIX
# named-class ([:alpha:] etc.) support - a literal "[:" sequence just
# becomes ordinary bracket-set characters in the output, a known,
# accepted quirk rather than an error.
#
# {...} brace expansion - one, non-nested, same-segment group per
# pattern (no "/" inside an alternative - that would need a different
# prefix/suffix per alternative, which is exactly the rearchitecture
# this design deliberately avoids). No matching "}", or a "/" inside ->
# malformed, same literal "\{" fallback as a bad bracket. Comma-list
# alternatives (glob_split_commas) and sequence expressions
# (glob_brace_sequence_regex) are the two recognized forms - neither ->
# malformed, same fallback. Each alternative/term is recursively run
# back through this same function (so "*.{txt,log}" or
# "img{1,[2-4]}.png" work - an alternative can itself contain
# "*"/"?"/"[...]", just not another "{...}" or a "/"), joined with "|".
# POSIX ERE (bash's own [[ =~ ]] engine) rejects an *empty* alternative
# inside a group outright ("(|txt)" is a syntax error, not a zero-width
# match the way PCRE would allow) - an empty alternative (e.g. "{,txt}")
# instead makes the whole group optional over the remaining ones
# ("(txt)?"); if every alternative was empty, the group contributes
# nothing at all.
glob_to_regex_body() {
	local pattern="$1"
	local out="" i=0 n=${#pattern} c
	while ((i < n)); do
		c="${pattern:i:1}"
		if [[ "$c" == '\' ]] && ((i + 1 < n)); then
			local nc="${pattern:i+1:1}"
			case "$nc" in
				'.' | '[' | ']' | '(' | ')' | '{' | '}' | '+' | '^' | '$' | '|' | '\' | '*' | '?') out+="\\$nc" ;;
				*) out+="$nc" ;;
			esac
			i=$((i + 2))
			continue
		fi
		if [[ "$c" == "*" && "${pattern:i:2}" == "**" ]]; then
			if [[ "${pattern:i+2:1}" == "/" ]]; then
				out+="(.*/)?"
				i=$((i + 3))
			else
				out+=".*"
				i=$((i + 2))
			fi
			continue
		fi
		if [[ "$c" == "*" ]]; then
			out+="[^/]*"
			i=$((i + 1))
			continue
		fi
		if [[ "$c" == "?" ]]; then
			out+="[^/]"
			i=$((i + 1))
			continue
		fi
		if [[ "$c" == "[" ]]; then
			local j=$((i + 1)) close=-1
			if ((j < n)) && [[ "${pattern:j:1}" == "!" || "${pattern:j:1}" == "^" ]]; then
				j=$((j + 1))
			fi
			if ((j < n)) && [[ "${pattern:j:1}" == "]" ]]; then
				j=$((j + 1))
			fi
			while ((j < n)); do
				[[ "${pattern:j:1}" == "]" ]] && { close=$j; break; }
				j=$((j + 1))
			done
			if ((close < 0)); then
				out+="\\["
				i=$((i + 1))
				continue
			fi
			local inner="${pattern:i+1:close-i-1}"
			if [[ "${inner:0:1}" == "!" ]]; then
				inner="^${inner:1}"
			fi
			out+="[$inner]"
			i=$((close + 1))
			continue
		fi
		if [[ "$c" == "{" ]]; then
			local j=$((i + 1)) close=-1
			while ((j < n)); do
				local cj="${pattern:j:1}"
				if [[ "$cj" == '\' ]] && ((j + 1 < n)); then
					j=$((j + 2))
					continue
				fi
				if [[ "$cj" == "}" ]]; then
					close=$j
					break
				fi
				j=$((j + 1))
			done
			local inner="" has_slash=0
			if ((close >= 0)); then
				inner="${pattern:i+1:close-i-1}"
				[[ "$inner" == */* ]] && has_slash=1
			fi
			if ((close < 0)) || ((has_slash == 1)); then
				out+="\\{"
				i=$((i + 1))
				continue
			fi
			local -a sub_regexes=()
			local matched=0
			if [[ "$inner" == *,* ]]; then
				glob_split_commas "$inner"
				local alt
				for alt in "${GLOB_BRACE_ALTS[@]}"; do
					sub_regexes+=("$(glob_to_regex_body "$alt")")
				done
				matched=1
			elif glob_brace_sequence_regex "$inner"; then
				local term
				for term in "${GLOB_SEQ_TERMS[@]}"; do
					sub_regexes+=("$(glob_to_regex_body "$term")")
				done
				matched=1
			fi
			if ((matched == 0)); then
				out+="\\{"
				i=$((i + 1))
				continue
			fi
			local -a nonempty=()
			local has_empty=0 sr
			for sr in "${sub_regexes[@]}"; do
				if [[ -z "$sr" ]]; then
					has_empty=1
				else
					nonempty+=("$sr")
				fi
			done
			if ((${#nonempty[@]} > 0)); then
				local joined="" first=1
				for sr in "${nonempty[@]}"; do
					[[ $first -eq 1 ]] || joined+="|"
					joined+="$sr"
					first=0
				done
				if ((has_empty)); then
					out+="($joined)?"
				else
					out+="($joined)"
				fi
			fi
			i=$((close + 1))
			continue
		fi
		case "$c" in
			'.' | '[' | ']' | '(' | ')' | '{' | '}' | '+' | '^' | '$' | '|' | '\') out+="\\$c" ;;
			*) out+="$c" ;;
		esac
		i=$((i + 1))
	done
	printf '%s' "$out"
}

glob_to_regex() {
	printf '^%s$\n' "$(glob_to_regex_body "$1")"
}

# True if $1 (a glob suffix) needs a full recursive walk (RECURSE)
# rather than a single-level LIST - either it spans multiple segments,
# or it contains an unescaped "**" anywhere (a bare "**" is itself one
# segment but still needs the full walk, since it can match any
# depth). Escape-aware like is_glob above, so a literal "\*\*" (an
# actual two-asterisk filename) doesn't get misread as the trigger.
glob_is_complex() {
	local s="$1"
	local i=0 n=${#s} c
	while ((i < n)); do
		c="${s:i:1}"
		if [[ "$c" == '\' ]] && ((i + 1 < n)); then
			i=$((i + 2))
			continue
		fi
		[[ "$c" == "/" ]] && return 0
		if [[ "$c" == "*" && "${s:i:2}" == "**" ]]; then
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

# Context for the glob callbacks below - set once by ls)/get) just
# before calling remote_walk/list_paginated, same dynamic-scoping idiom
# as LOCAL_DEST/get_one.
GLOB_REGEX=""
GLOB_DEST_ROOT=""

# Callback for list_paginated (glob "simple case" - suffix is one
# segment, no **): matches a bare name against $GLOB_REGEX, prints
# path-qualified (relative to $GLOB_PREFIX) on match - never a bare
# basename, since matches can come from different directories in the
# complex-case sibling below, and this should look the same either way.
glob_list_simple() {
	local type="$1" size="$2" mtime="$3" name="$4" full
	[[ "$name" =~ $GLOB_REGEX ]] || return 0
	full=$(join_path "$GLOB_PREFIX" "$name")
	if [[ "$SHOW_FULL_PATH" == "1" ]]; then
		print_path_only_line "$type" "$size" "$mtime" "$full"
	else
		print_listing_line "$type" "$size" "$mtime" "$full"
	fi
}

# Callback for remote_walk (glob "complex case"): matches a relpath
# against $GLOB_REGEX, prints path-qualified (relative to $root, which
# remote_walk always passes as the subtree root it was given) on match.
glob_list_complex() {
	local type="$1" size="$2" mtime="$3" relpath="$4" root="$5" full
	[[ "$relpath" =~ $GLOB_REGEX ]] || return 0
	full=$(join_path "$root" "$relpath")
	if [[ "$SHOW_FULL_PATH" == "1" ]]; then
		print_path_only_line "$type" "$size" "$mtime" "$full"
	else
		print_listing_line "$type" "$size" "$mtime" "$full"
	fi
}

# get-side counterparts: skip matched directories (no implicit
# recursion into them beyond what the pattern itself already expresses
# via **) and download every matched file to the complete matched
# remote path, recreated under $GLOB_DEST_ROOT - do_get_file's own
# mkdir -p-equivalent local-directory creation already handles the
# nested-destination case, so per-file resume applies exactly as it
# does for -r, no extra logic needed here.
glob_get_simple() {
	local type="$1" size="$2" mtime="$3" name="$4"
	[[ "$name" =~ $GLOB_REGEX ]] || return 0
	[[ "$type" == "F" ]] || return 0
	local full_remote
	full_remote=$(join_path "$GLOB_PREFIX" "$name")
	do_get_file "$full_remote" "$GLOB_DEST_ROOT/$full_remote"
}

glob_get_complex() {
	local type="$1" size="$2" mtime="$3" relpath="$4" root="$5"
	[[ "$relpath" =~ $GLOB_REGEX ]] || return 0
	[[ "$type" == "F" ]] || return 0
	local full_remote
	full_remote=$(join_path "$root" "$relpath")
	do_get_file "$full_remote" "$GLOB_DEST_ROOT/$full_remote"
}

# Callback for list_paginated (plain, non-glob `ls`): prints path-
# qualified relative to $LS_PLAIN_PATH and column-free (see
# print_path_only_line) when -1/SHOW_FULL_PATH is set, bare name in the
# normal columnar format otherwise.
LS_PLAIN_PATH=""
ls_plain_line() {
	local type="$1" size="$2" mtime="$3" name="$4"
	if [[ "$SHOW_FULL_PATH" == "1" ]]; then
		print_path_only_line "$type" "$size" "$mtime" "$(join_path "$LS_PLAIN_PATH" "$name")"
	else
		print_listing_line "$type" "$size" "$mtime" "$name"
	fi
}

# Recursively walks $remote_root (a directory on the responder) via
# RECURSE, paginated (PAGE_SIZE entries per page, looping on "MORE
# <cursor>" until a plain "END" - the server does the actual recursion
# now, this just pages through a flat result stream). Invokes $callback
# once per entry found, as:
#   callback <type> <size> <mtime> <relpath> <remote_root>
# where <relpath> is always relative to $remote_root and always /-
# separated, regardless of the responder's own platform. Must fully
# drain each page (through END/MORE) before invoking any callback - the
# wire protocol is strictly request/response, and a callback that issues
# its own request (GET) must never race a still-in-flight page.
remote_walk() {
	local remote_root="$1" callback="$2"
	local cursor="" line rest type size mtime relpath
	local -a ptype psize pmtime prel
	local at_end more_cursor i
	while true; do
		if [[ -n "$cursor" ]]; then
			printf 'RECURSE %s %s %s\n' "$remote_root" "$PAGE_SIZE" "$cursor" >&4
		else
			printf 'RECURSE %s %s\n' "$remote_root" "$PAGE_SIZE" >&4
		fi
		ptype=() psize=() pmtime=() prel=()
		at_end=0 more_cursor=""
		while true; do
			if ! read -t "$TIMEOUT" -r line <&3; then
				echo >&2 "timed out (${TIMEOUT}s) or lost connection waiting for a response"
				exit 1
			fi
			case "$line" in
				END) at_end=1; break ;;
				MORE\ *) more_cursor="${line#MORE }"; break ;;
				ERR\ *) echo >&2 "server: ${line#ERR } ($remote_root)"; exit 1 ;;
			esac
			type=${line%% *}; rest=${line#* }
			size=${rest%% *}; rest=${rest#* }
			mtime=${rest%% *}; relpath=${rest#* }
			ptype+=("$type"); psize+=("$size"); pmtime+=("$mtime"); prel+=("$relpath")
		done
		for ((i = 0; i < ${#prel[@]}; i++)); do
			"$callback" "${ptype[$i]}" "${psize[$i]}" "${pmtime[$i]}" "${prel[$i]}" "$remote_root"
		done
		[[ "$at_end" == "1" ]] && break
		cursor="$more_cursor"
	done
}

# Paginated single-level LIST - same pagination shape as remote_walk
# above, but one directory's immediate children only (name is already
# bare, no root/relpath to compute). Used by plain `ls` (no -r, no glob)
# and the glob "simple case" (a pattern whose suffix can only ever match
# one level deep, where a full RECURSE would walk an irrelevant subtree
# for nothing). Invokes $callback once per entry found, as:
#   callback <type> <size> <mtime> <name>
list_paginated() {
	local dir="$1" callback="$2"
	local cursor="" line rest type size mtime name
	local -a ptype psize pmtime pname
	local at_end more_cursor i
	while true; do
		if [[ -n "$cursor" ]]; then
			printf 'LIST %s %s %s\n' "$dir" "$PAGE_SIZE" "$cursor" >&4
		else
			printf 'LIST %s %s\n' "$dir" "$PAGE_SIZE" >&4
		fi
		ptype=() psize=() pmtime=() pname=()
		at_end=0 more_cursor=""
		while true; do
			if ! read -t "$TIMEOUT" -r line <&3; then
				echo >&2 "timed out (${TIMEOUT}s) or lost connection waiting for a response"
				exit 1
			fi
			case "$line" in
				END) at_end=1; break ;;
				MORE\ *) more_cursor="${line#MORE }"; break ;;
				ERR\ *) echo >&2 "server: ${line#ERR } ($dir)"; exit 1 ;;
			esac
			type=${line%% *}; rest=${line#* }
			size=${rest%% *}; rest=${rest#* }
			mtime=${rest%% *}; name=${rest#* }
			ptype+=("$type"); psize+=("$size"); pmtime+=("$mtime"); pname+=("$name")
		done
		for ((i = 0; i < ${#pname[@]}; i++)); do
			"$callback" "${ptype[$i]}" "${psize[$i]}" "${pmtime[$i]}" "${pname[$i]}"
		done
		[[ "$at_end" == "1" ]] && break
		cursor="$more_cursor"
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
# recursive_get's get_one callback, by `get -r` too.
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
# because, unlike GET, the side with the partial (the responder) isn't
# the side that knows what to do about it (us) - so it has to offer first.
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
		path="${1:-}"
		if is_glob "$path"; then
			glob_split "$path"
			GLOB_REGEX="$(glob_to_regex "$GLOB_SUFFIX")"
			if glob_is_complex "$GLOB_SUFFIX"; then
				remote_walk "$GLOB_PREFIX" glob_list_complex
			else
				list_paginated "$GLOB_PREFIX" glob_list_simple
			fi
		elif [[ "$RECURSIVE" == "1" ]]; then
			path_clean="$(glob_unescape "$path")"
			path_clean="${path_clean%/}"
			[[ -n "$path_clean" ]] || path_clean="."
			remote_walk "$path_clean" print_recursive_listing_line
		else
			path="$(glob_unescape "$path")"
			LS_PLAIN_PATH="$path"
			list_paginated "$path" ls_plain_line
		fi
		;;
	get)
		remote_raw="${1:-}"
		dest_root="${2:-}"
		[[ -n "$remote_raw" ]] || { echo >&2 "get requires a remote path"; exit 1; }
		if is_glob "$remote_raw"; then
			glob_split "$remote_raw"
			GLOB_REGEX="$(glob_to_regex "$GLOB_SUFFIX")"
			GLOB_DEST_ROOT="${dest_root:-.}"
			if glob_is_complex "$GLOB_SUFFIX"; then
				remote_walk "$GLOB_PREFIX" glob_get_complex
			else
				list_paginated "$GLOB_PREFIX" glob_get_simple
			fi
		elif [[ "$RECURSIVE" == "1" ]]; then
			remote_raw="$(glob_unescape "$remote_raw")"
			local_dest=$(effective_dest "$remote_raw" "$dest_root")
			remote_clean="${remote_raw%/}"
			[[ -n "$remote_clean" ]] || remote_clean="."
			recursive_get "$remote_clean" "$local_dest"
		else
			remote_raw="$(glob_unescape "$remote_raw")"
			local_path="${dest_root:-$(basename -- "$remote_raw")}"
			do_get_file "$remote_raw" "$local_path"
		fi
		;;
	put)
		local_raw="${1:-}"
		dest_root="${2:-}"
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
	pwd)
		printf 'PWD\n' >&4
		read_response resp || exit 1
		case "$resp" in
			OK\ *) echo "${resp#OK }" ;;
			ERR\ *) echo >&2 "server: ${resp#ERR }"; exit 1 ;;
			*) echo >&2 "unexpected response: $resp"; exit 1 ;;
		esac
		;;
	mkdir)
		# No -p flag: the responder's own do_mkdir already runs
		# `mkdir -p` unconditionally (see its own comment), so every
		# MKDIR on the wire always creates the whole tree.
		remote_path="${1:-}"
		[[ -n "$remote_path" ]] || { echo >&2 "mkdir requires a remote path"; exit 1; }
		remote_mkdir "$remote_path" || exit 1
		echo "mkdir $remote_path"
		;;
	stat)
		remote_path="${1:-.}"
		printf 'STAT %s\n' "$remote_path" >&4
		read_response resp || exit 1
		case "$resp" in
			OK\ *)
				# OK <type> <size> <mtime> <atime> <birthtime> <file_count> <dir_count>
				# - same field-splitting idiom list_paginated/remote_walk
				# already use, not `read -r ... <<<`: every field here is
				# a plain token (no embedded spaces to worry about), so
				# either approach would work, but this keeps the parsing
				# style consistent across the whole file.
				st_rest="${resp#OK }"
				st_type="${st_rest%% *}"; st_rest="${st_rest#* }"
				st_size="${st_rest%% *}"; st_rest="${st_rest#* }"
				st_mtime="${st_rest%% *}"; st_rest="${st_rest#* }"
				st_atime="${st_rest%% *}"; st_rest="${st_rest#* }"
				st_btime="${st_rest%% *}"; st_rest="${st_rest#* }"
				st_files="${st_rest%% *}"; st_rest="${st_rest#* }"
				st_dirs="$st_rest"
				# "path:" shows the responder's real absolute filesystem
				# path, not just whatever (possibly relative, possibly
				# bare) argument the user typed - resolved via a second
				# request, PWD, same wire verb the `pwd` subcommand
				# already uses, joined with the now-known-valid remote
				# path. "." (or a path that trims down to it) means the
				# root itself, no "/." suffix.
				printf 'PWD\n' >&4
				read_response pwd_resp || exit 1
				case "$pwd_resp" in
					OK\ *) pwd_root="${pwd_resp#OK }" ;;
					*) pwd_root="" ;;
				esac
				remote_clean="${remote_path%/}"
				if [[ -z "$pwd_root" ]]; then
					abs_path="$remote_path"
				elif [[ -z "$remote_clean" || "$remote_clean" == "." ]]; then
					abs_path="$pwd_root"
				else
					abs_path="$pwd_root/$remote_clean"
				fi
				printf 'path:       %s\n' "$abs_path"
				if [[ "$st_type" == "D" ]]; then
					printf 'type:       directory\n'
				else
					printf 'type:       file\n'
					printf 'size:       %s (%s)\n' "$st_size" "$(human_size "$st_size")"
				fi
				printf 'mtime:      %s\n' "$(human_date "$st_mtime")"
				printf 'atime:      %s\n' "$(human_date "$st_atime")"
				if [[ "$st_btime" == "0" ]]; then
					printf 'birthtime:  unknown\n'
				else
					printf 'birthtime:  %s\n' "$(human_date "$st_btime")"
				fi
				if [[ "$st_type" == "D" ]]; then
					printf 'files:      %s\n' "$st_files"
					printf 'dirs:       %s\n' "$st_dirs"
				fi
				;;
			ERR\ *) echo >&2 "server: ${resp#ERR }"; exit 1 ;;
			*) echo >&2 "unexpected response: $resp"; exit 1 ;;
		esac
		;;
	*)
		usage
		;;
esac
