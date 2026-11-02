# gs-transfer protocol

A minimal, text-based file-transfer protocol designed to run entirely
inside an already-established `gsocket`/`gs-netcat` tunnel. It does not
touch GSRN rendezvous or SRP-TLS itself - `gs-netcat` (the real upstream
binary on POSIX, `gs-netcat.exe` on Windows) is used unmodified, purely as
the transport, in one of two ways:

- **Responder** (the `-l` / listening side): `gs-netcat` execs a gs-transfer
  responder script via its existing `-e <command>` flag. The script's
  stdin/stdout are the tunnel - no socket code needed in the script at all.
  The responder script is itself both halves of this: run standalone
  (`gs-transfer-server.sh`/`.ps1 [-s <secret>|-k <file>] [-T]`), it launches
  `gs-netcat` itself with `-e` pointing back at itself, so there's no
  `gs-netcat` command line to construct by hand - or it can still be
  exec'd manually exactly as above, unchanged. See **Standalone launching**
  below for how one script manages to be both the launcher and the `-e`
  target.
- **Dialer** (the client side): a gs-transfer client script spawns
  `gs-netcat`/`gs-netcat.exe` itself as a subprocess (a bash `coproc`, or
  the platform equivalent) to get a pipe to the tunnel, then speaks this
  protocol over it.

This keeps gs-transfer purely supplemental: it never modifies `gs-netcat`,
`gs-tunnel`, or any file under `lib/`/`tools/`.

## Secret handling

Same convention as the rest of this project - `gs-transfer-client.sh` and
the standalone-launcher half of each responder script accept `gs-netcat`'s
own secret/proxy flags directly and pass them straight through unmodified,
inventing nothing new:

- `-s <secret>`: the secret as a literal argument.
- `-k <file>`: the secret read from a file's contents instead - `gs-netcat`'s
  own man page recommends this specifically, since a secret on the command
  line is visible in `ps`/shell history (`-k` wins if both `-s` and `-k` are
  given - `gs-netcat`'s own precedence, not reimplemented here).
- `-T`: route the connection through a SOCKS5 proxy (normally TOR, default
  `127.0.0.1:9050`, overridable via `gs-netcat`'s own `GSOCKET_SOCKS_IP`/
  `GSOCKET_SOCKS_PORT` environment variables - not flags of `-T` itself).

If none of `-s`/`-k` are given, falls through to the `gs-netcat` subprocess's
own `GSOCKET_ARGS` environment-variable handling (`tools/utils.c`'s
`GS_getenv("GSOCKET_ARGS")` - the same mechanism upstream's own `blitz`
script uses to avoid putting secrets in `ps` output). gs-transfer does not
add any new secret-storage or alias mechanism.

## Standalone launching

Each responder script (`gs-transfer-server.sh`, `gs-transfer-server.ps1`)
is both the thing a user runs directly *and* the thing `gs-netcat`'s `-e`
execs - the same file plays both roles, detected at runtime rather than
split into two files, so there's nothing extra to deploy:

1. **Launcher**: run with no special environment/stdin state, it parses
   `-s`/`-k`/`-T`, builds `gs-netcat -l [those flags] -e <itself>`, and
   execs/launches that.
2. **Worker**: `gs-netcat`'s own `-e` then runs that same script again,
   this time with stdin/stdout wired to the tunnel - this half is
   completely unchanged from before standalone launching existed, and
   has no idea whether it was reached via the launcher above or a
   manually-typed `gs-netcat -l -e /path/to/this/script` (still fully
   supported, unchanged).

### Telling the two apart

Neither a command-line flag nor an environment variable can do this
alone, because the manual invocation path above - which has to keep
working exactly as it always has - never sets anything special at all:
`gs-netcat`'s `-e` passes no arguments of its own, and nothing in that
flow ever touches the environment either. So each script uses two
signals together, worker if *either* fires:

- **An explicit marker** (`GSTRANSFER_WORKER=1` / `$env:GSTRANSFER_WORKER`)
  the launcher sets on itself just before becoming `gs-netcat` - inherited
  through `gs-netcat`'s own child-process creation for its `-e` command,
  so by the time *that* process starts, the marker is already there.
- **Whether stdin looks like a pipe** - `gs-netcat` wires a `-e` child's
  stdin to a pipe (confirmed directly against this project's own
  `win_childproc.c`: `CreatePipe`, not a console or file handle), which a
  fresh launch from an interactive shell, or a backgrounded/redirected one
  with no explicit stdin redirect, never is. This is deliberately a
  precise pipe-or-not check (bash's own `-p` test; on Windows, the raw
  Win32 `GetFileType`, checked for exactly `FILE_TYPE_PIPE` i.e. `3`) -
  not .NET's `Console.IsInputRedirected`, which was tried first and
  rejected: it's also true for a plain `/dev/null` redirect (a
  backgrounded launch with no console attached, not a `-e` child at all),
  which would have been misread as a worker.

The explicit marker alone covers the standalone-launch path; the pipe
check is what keeps the pre-existing manual path working without ever
needing to know this launcher logic exists at all.

### Windows: a bare script path doesn't work as `-e`'s value

`-e`'s value becomes whatever the underlying `gs-netcat` directly execs -
on Windows, confirmed against this project's own `win_childproc.c`,
that's a raw Win32 `CreateProcess` call with the value passed through
*verbatim* as the command line, no shell in between at all. A shebang
line is a convention the *kernel* interprets on `exec()` - Windows'
`CreateProcess` has no concept of it, so a bare `.sh` path there isn't
something it can run directly, and (confirmed by direct testing) isn't
even a path it can resolve at all if it's POSIX-style (`/c/Users/...` -
a leading `/` means "root of the current drive" to Win32, not an MSYS
path). The bash launcher works around both problems together: on
MSYS/Cygwin specifically (detected via `uname -o`), it resolves its own
interpreter (`command -v bash`) and its own script path, converts both to
Windows-style via `cygpath -w`, and builds the `-e` value as
`"<bash.exe>" "<script.ps1-or-.sh path>"` - naming the interpreter
explicitly rather than relying on execute-bit-plus-shebang, which also
works unconditionally on real POSIX (`bash <path>` needs neither a
shebang nor `+x`), so there's no reason to make this MSYS-only beyond the
path-style conversion. The PowerShell launcher never had this problem in
the first place - `$PSCommandPath` is already native Windows-style, and
it already explicitly names `powershell.exe` rather than relying on any
exec-by-association convention.

## Wire format

Line-oriented for control (one request/response per line, LF-terminated),
exact-byte-count for data - never delimiter-based for binary payloads, so
a file's own content can never be confused with protocol framing.

### Requests (client -> responder)

```
LIST [path]
GET <path> [<offset> <hash>]
PUT <path> <size>
MKDIR <path>
QUIT
```
`LIST` with no argument lists the responder's current working directory;
`LIST <path>` lists a subdirectory relative to it. `<path>` in
`GET`/`PUT`/`MKDIR` may include `/`-separated subdirectories (e.g.
`logs/2026-11-01.txt`) - see **Path rules** below for exactly what's
allowed. `GET`'s optional `<offset> <hash>` is a resume request - see
**Resume and partial-file safety** below; plain `GET <path>` is still a
complete, from-scratch request exactly as always. A `PUT` request line
is *not* immediately followed by data the way it used to be - see the
same section for the handshake that now sits in between. `MKDIR <path>`
creates a directory, plus any missing intermediate parents
(`mkdir -p`-equivalent, same as `PUT`'s own auto-created parent
directories). It exists so a recursive upload can preserve an empty
directory - a plain `PUT` only ever creates the parents of a file it's
actually writing, so a directory with nothing in it would otherwise be
silently dropped.

Note: `<path>` here is always the single *remote* path - there's no
concept of a local path at the wire-protocol level at all. A client tool
is free to expose separate local/remote arguments on its own CLI (e.g.
`gs-transfer-client.sh put <local-path> [remote-path]`, defaulting one from
the other's basename) - that's purely a client-side UX decision, not
something the wire format needs to know about.

### Responses (responder -> client)

```
LIST success   : zero or more "<type> <size> <mtime> <name>" lines, then "END"
GET success    : "OK <n>" followed by exactly <n> raw bytes - <n> is the
                  full file size for a plain GET, or just the remaining
                  bytes for a resume GET (see below)
GET failure    : "ERR <reason>"
PUT, step 1    : "FRESH" | "RESUME <offset> <hash>" | "ERR <reason>"
PUT, step 2    : (final) "OK" | "ERR <reason>"
MKDIR success  : "OK"
MKDIR failure  : "ERR <reason>"
QUIT           : no response - the responder process exits, which ends the
                 gs-netcat -e child and tears down the tunnel session
```
`PUT` now gets *two* responses, not one - see **Resume and partial-file
safety** for the full 4-step exchange this implies.

`<type>` is `F` (regular file) or `D` (subdirectory) - entries of any
other type (symlinks, devices, etc.) are omitted. `<size>` is a decimal
byte count (`0` for directories - their size isn't meaningful here).
`<mtime>` is a decimal Unix timestamp. `<name>` in a `LIST` response is
always a bare name (no path prefix), relative to whatever directory was
listed.

### Path rules

Applied identically by both responders (`gs-transfer-server.sh`,
`gs-transfer-server.ps1`) to every `path` in `LIST`/`GET`/`PUT`/`MKDIR`, to
stay within the responder's starting directory:

- Must be relative - no leading `/` (or a drive letter/`\\` on Windows).
- No `..` path component, anywhere in the path.
- `/` is the only separator accepted on the wire, even when the
  responder is Windows - a literal `\` anywhere in the path is rejected
  outright rather than treated as a separator, so the wire format stays
  identical cross-platform.
- No empty components (`a//b`, a trailing `/`) and no empty path.
- A bare `.` component is allowed (resolves to "this directory").

Anything failing these checks gets `ERR invalid path` (or, on a `PUT`
with a bad path, the responder still drains exactly `<size>` bytes from
the stream first, to stay in sync for whatever request comes next).

`PUT` creates any missing intermediate directories for its target path
(`mkdir -p`-equivalent) before writing the file.

### Every request gets a response

Both responders guarantee this, including for a request they don't
recognize (`ERR unknown command`) - confirmed necessary by direct
testing: before this was enforced, an unrecognized command left the
*client* blocked forever on its next read, even though the connection
itself stayed healthy for later requests. A responder that silently
drops any request (a bug, a future protocol extension the other side
doesn't know about yet) will hang whatever's waiting on a reply - this
is a hard protocol invariant, not just a style preference. `PUT`'s two
responses (the `FRESH`/`RESUME`/`ERR` offer, then the final `OK`/`ERR`)
are each held to this just as strictly as any other response.

This is a strictly synchronous, non-pipelined protocol: a responder reads
one request, fully writes that request's entire response, and only then
reads the next request. A client must fully drain a response (read
through `END` for `LIST`, or through all `<size>` payload bytes for
`GET`) before sending its next request - never send request *N+1* while
any part of response *N* might still be in flight. This bit the client's
own `-r` implementation during development: a first draft issued a `GET`
for a file as soon as that file's `LIST` entry line was read, without
waiting for `LIST`'s trailing entries and `END` - the responder hadn't
even read the `GET` yet, so the bytes the client next read back were the
rest of the still-in-flight `LIST` response, misread as the `GET`'s
reply. Fixed by buffering an entire `LIST` response before acting on any
of it. Any client implementation that recurses (or otherwise issues a
request in response to something read mid-stream) needs the same
discipline.

### Client-side timeouts

`gs-transfer-client.sh` bounds every blocking read: control-line responses
default to 30s (`-t <seconds>` to change), and an in-progress data
transfer gets a separate, larger bound (`DATA_TIMEOUT`, 300s by default,
edit the script to change - not exposed as a flag since it's rarely the
right thing to tune per-invocation). A `GET` or `PUT` that times out
mid-transfer never corrupts the target at its real name - see **Resume
and partial-file safety** below for exactly where the in-progress bytes
go instead, and why that same mechanism is what later lets the transfer
pick up where it left off rather than starting over. This is purely a
dialer-side concern (the one issuing requests and waiting on replies) -
a responder invoked via `-e` has no equivalent "give up and move on"
since gsocket's own connection/ping handling already governs how long a
`-e` child's tunnel stays alive. `MKDIR` has no equivalent partial-state
concern - it either completes or fails atomically, there's no byte
stream to truncate.

## Resume and partial-file safety

`get`/`put` resume automatically whenever an interrupted attempt left a
usable partial behind - there's no flag for it, and no cost at all on
the common, uninterrupted path.

### Where the partial lives

A deterministic sibling of the target, `.<basename>.partial` - computed
directly from the target path, never discovered by scanning a
directory. This is a deliberate departure from the obvious alternative
(a `mktemp`-random name, which is what an earlier version of this
mechanism used): resume needs to find the *same* staging file on a
later attempt, which a random name defeats by design, and globbing a
whole directory for candidates is unnecessary when the name can just be
computed. Making the name predictable again looks like it reopens the
exact symlink-planting hazard the random name existed to close - a
party with write access to the destination directory could pre-create
a symlink at this exact, guessable path. It doesn't, because safety
here comes from two independent checks performed every time, not from
the name being hard to guess:

1. **Exclusive, atomic creation.** A brand-new partial is created with
   bash's `noclobber` (`set -C; : > path`) or, on Windows,
   `[System.IO.File]::Open(path, [System.IO.FileMode]::CreateNew)`.
   Both refuse outright if *anything* already exists at that exact
   path - a plain file, a directory, or a symlink/reparse point, it
   doesn't matter which - rather than following or truncating it. This
   is the same `O_EXCL`-style guarantee `mktemp` relies on, just at a
   path this code chose instead of one `mktemp` randomized.
2. **Vetting before trusting an existing one.** Before a partial is
   ever appended to, hashed, or removed-and-replaced, both sides check
   that it's a plain regular file - bash's `[[ -f "$p" && ! -L "$p" ]]`,
   or on Windows an explicit `(Get-Item -Force $p).Attributes` check
   for `ReparsePoint`. A symlink (even one pointing at a wholly
   legitimate file) always fails this check and is never touched -
   not read, not removed, not written through. If vetting fails, the
   operation errors out (`ERR staging blocked` / a local "staging path
   blocked" message) rather than trying to automatically clean up or
   work around whatever's there - a path that fails this check might
   not be this code's to touch at all.

   On MSYS/Cygwin specifically (detected via `uname -o`, which reports
   `Msys` or `Cygwin` there and fails safely to neither on real
   Linux/macOS), there's a second kind of "symlink" `-L` can't see at
   all: their own symlink emulation represents one as an ordinary file
   starting with the literal bytes `!<symlink>` followed by a
   UTF-16LE-encoded target - not a Windows reparse point, so invisible
   to both Windows itself and to `-f`/`-L`, which see nothing but a
   plain regular file. Confirmed directly with a hand-built file in
   this exact format: it passes `[[ -f "$p" && ! -L "$p" ]]` cleanly.
   Both POSIX-side scripts check for this magic prefix too, but only
   when `uname -o` says it's worth looking - the check is meaningless
   (and never runs) anywhere else. Git-for-Windows' own `ln -s` doesn't
   actually produce this format by default (see the environment traps
   below), but other MSYS2/Cygwin configurations can.

Both of these were verified directly against a *real* symlink, not
assumed from documentation - and doing so surfaced two environment
traps worth knowing about if this is ever re-verified:

- Git-Bash's own `ln -s` silently falls back to **copying** the target
  instead of creating a real symlink when it lacks the privilege to do
  so, with no error - confirmed against Git for Windows' own
  documentation, which states this plainly: it's the documented
  default, not a one-off fluke of this particular install. A noclobber
  test against a "symlink" made this way looks like it passed (the
  "victim" file is untouched) without having tested anything at all,
  since there was never a real symlink in play. Use `cmd /c mklink` to
  get a genuine one for testing on Windows - and note this also means
  Git for Windows' bundled bash won't produce the `!<symlink>`-style
  pseudo-symlink described above either; that failure mode needed a
  hand-built file to verify, not `ln -s`.
- PowerShell's `Set-Location` does **not** update .NET's own process
  working directory, which raw static calls like
  `[System.IO.File]::Open` resolve relative paths against. A test that
  calls `Set-Location` and then passes a bare relative path to a .NET
  API can silently operate on a same-named file in a *different*
  directory than intended, making `CreateNew` look like it isn't
  protecting anything when it actually is. Always use fully-resolved
  absolute paths with raw .NET file APIs - which is what this
  responder already does throughout, since it never calls
  `Set-Location` in the first place.

### Validating a resume with a bounded hash

A partial existing and passing vetting isn't enough on its own - it
also has to actually be the right bytes, not a stale leftover from
transferring a *different* version of the same-named file, and not
silently corrupted. Both sides hash **only the overlap** - the bytes
already transferred - never the whole file, so validating a resume
never costs more than the resume itself already did, and an ordinary,
never-interrupted transfer pays nothing extra at all (there's no
partial to validate in the first place). Hashing the whole file to
*name* the partial (an earlier design considered for this) was rejected
for exactly this reason: it would have charged every single transfer
the cost of hashing the entire file, whether or not resume ever mattered
for it.

### GET resume

The client already knows everything it needs before sending anything -
its own local partial, if any, is right there on disk - so there's no
extra round-trip:

```
GET <path>                  - no local partial: fresh, as always
GET <path> <offset> <hash>  - local partial of <offset> bytes exists;
                               <hash> is its content hash
```
The responder hashes its own first `<offset>` bytes of `<path>` and
compares. Match: `OK <size-offset>` followed by just the remaining
bytes, which the client appends to its partial. Mismatch or an offset
larger than the real file: `ERR resume mismatch` / `ERR invalid offset`
- the client discards its partial and retries as a plain `GET <path>`.

### PUT resume

Here the roles don't line up the same way: the partial lives on the
*responder's* side, but the responder isn't the one who gets to decide
what to do about it - only the client (which holds the complete file)
can verify a resume is safe. That forces an extra round-trip before any
bytes move, turning `PUT` into a 4-step exchange instead of a
fire-and-forget request:

```
client:    PUT <path> <size>
responder: FRESH                      - no usable partial
         | RESUME <offset> <hash>     - partial of <offset> bytes, this hash
         | ERR <reason>               - bad path; handshake ends here
client:    RESTART                    - send all <size> bytes from byte 0
         | RESUME <offset>            - send just the remaining bytes
[client streams the declared byte count]
responder: OK | ERR <reason>
```
The client only replies `RESUME <offset>` if hashing its own first
`<offset>` bytes matches the hash the responder just offered; otherwise
it replies `RESTART` and sends the whole file. The responder, on
`RESTART`, resets its partial (vetting it first, per above) and creates
a fresh one; on a `RESUME <offset>` that doesn't match what it actually
offered (a confused or stale client), it drains the declared byte count
to stay in sync but writes nothing anywhere - those bytes are only ever
a *tail*, never safe to treat as a complete file.

### What a resumed completion does *not* re-check

The overlap hash proves the already-transferred prefix is intact before
trusting it; the freshly-streamed remainder in the same session carries
the same trust as any ordinary, non-resumed transfer always has - there
is no additional whole-file hash of the finished result. Adding one
would be a reasonable belt-and-suspenders option but was left out to
keep the common case free of avoidable hashing, consistent with the
bounded-overlap reasoning above.

## Recursion (`-r`)

The wire protocol has no recursion primitive of its own - `gs-transfer-
client.sh -r` builds it entirely client-side out of repeated `LIST`
calls (to walk a remote directory tree) plus one `GET`/`PUT`/`MKDIR` per
entry found. Responders need nothing beyond the `MKDIR` verb above; they
have no notion of "recursive" requests at all.

- `ls -r [path]`: walks `path` (the responder's own directory if
  omitted) via repeated `LIST`, printing every file and subdirectory
  found, with paths shown relative to `path`.
- `get -r <remote> [local]` / `put -r <local> [remote]`: replicates a
  whole directory tree across the tunnel, creating directories (via
  `MKDIR`) and files (via `PUT`/`GET`) to match. If the source argument
  is a plain file rather than a directory, `-r` is a no-op and the
  single-file behavior applies unchanged. Each file in the tree goes
  through the same single-file `GET`/`PUT` implementation the
  non-recursive commands use, so **Resume and partial-file safety**
  above applies per-file here too - an interrupted recursive transfer
  resumes the one file it was on, not the whole tree from scratch.

### Trailing-slash destination rule (matches `rsync -r`)

The *source* path's trailing slash controls whether its own basename
becomes an extra level in the destination, exactly like `rsync -r`;
whether or not an explicit destination argument was given doesn't change
the rule - only the default destination root does (`.` when omitted):

```
put -r photos     dst   ->  dst/photos/...   (no trailing slash: source's
                                               own name is kept as a level)
put -r photos/    dst   ->  dst/...          (trailing slash: only the
                                               contents move, flattened
                                               directly into dst)
put -r photos         (no dst, no slash)  ->  ./photos/...
put -r photos/        (no dst, w/ slash)  ->  . itself (contents land in cwd)
```
`get -r <remote> [local]` applies the identical rule with remote/local
swapped (the remote path is the source, the local path is the
destination). This is a purely client-side UX convention, resolved
before anything is put on the wire - the trailing slash itself is never
sent as part of a `path` (it would fail **Path rules**' "no trailing /"
check anyway); the client strips it locally and uses it only to decide
the destination layout.

## Scope / accepted limitations

Deliberately minimal, matching this tool's "very minimalistic" brief:

- Filenames must not contain newlines (undefined behavior if they do -
  not escaped/validated beyond that).
- No recursion at the wire level - `-r` (see **Recursion** above) is
  entirely a client-side construction on top of plain
  `LIST`/`GET`/`PUT`/`MKDIR`; the protocol itself only ever transfers one
  file or lists one directory per request. No server-side glob
  expansion - a client can glob locally (shell globbing) and issue one
  `PUT`/`GET` per matched file.
- Resume (see **Resume and partial-file safety** above) only ever
  validates the already-transferred overlap, never the whole finished
  file, and only ever resumes a byte-for-byte contiguous prefix - there's
  no block-level resume for a prefix that's *partly* wrong (unlike
  `rsync`'s own rolling-checksum delta algorithm, which this protocol
  deliberately doesn't reimplement). A partial that fails vetting (not a
  plain regular file - most likely a symlink) is never auto-removed or
  worked around; the transfer errors out until a human clears it.
- The responder's starting directory is its own current working
  directory - same convention gsocket's own native file-transfer
  protocol uses - and no `path` can ever resolve outside of it.
- No authentication beyond the gsocket secret itself (whoever can
  establish the tunnel can list/get/put - identical trust model to every
  other gsocket tool in this project).
- `get -r` always assumes its remote source is a directory and starts
  with a `LIST` - there's no `STAT` verb to check first. Pointed at a
  remote path that's actually a plain file, it gets back `ERR not found`
  (the same error `LIST` gives for a missing directory, since the
  responder's directory check also fails for a file) rather than falling
  back to a single-file `GET`. Use plain `get` (no `-r`) for a single
  remote file.
