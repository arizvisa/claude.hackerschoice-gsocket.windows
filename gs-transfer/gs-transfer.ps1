# gs-transfer (Windows) - single-deployable client+server. See
# ../PROTOCOL.md for the wire format.
#
# -Listen (alias -l, matching gs-netcat's own -l and the POSIX script's
# flag) selects server (responder) mode. Without it, this runs the client.
# The client side is new here - ../posix/gs-transfer.sh already had one,
# ported from its bash implementation to work against the same wire
# protocol.
#
# Usage:
#   gs-transfer.ps1 -Listen [-Secret <secret>] [-SecretFile <file>] [-Tor]
#       Server mode. Launches gs-netcat.exe itself (-l, plus whatever
#       secret/proxy flags were given) with -e pointing back at this same
#       script - no gs-netcat.exe command line to construct by hand. Can
#       also still be driven manually, exactly as before:
#         gs-netcat.exe -s <secret> -l -e "powershell.exe -NoProfile -ExecutionPolicy Bypass -File gs-transfer.ps1"
#
#   gs-transfer.ps1 [-Secret <secret>] [-SecretFile <file>] [-Tor] [-Timeout <seconds>] ls [-Recursive] [-FullPath] [path]
#   gs-transfer.ps1 [-Secret <secret>] [-SecretFile <file>] [-Tor] [-Timeout <seconds>] get [-Recursive] <remote-path> [local-path]
#   gs-transfer.ps1 [-Secret <secret>] [-SecretFile <file>] [-Tor] [-Timeout <seconds>] put [-Recursive] <local-path> [remote-path]
#   gs-transfer.ps1 [-Secret <secret>] [-SecretFile <file>] [-Tor] [-Timeout <seconds>] pwd
#   gs-transfer.ps1 [-Secret <secret>] [-SecretFile <file>] [-Tor] [-Timeout <seconds>] mkdir <remote-path>
#   gs-transfer.ps1 [-Secret <secret>] [-SecretFile <file>] [-Tor] [-Timeout <seconds>] stat [path]
#       Client mode (default, no -Listen). pwd reports the responder's
#       own starting directory - what "." means on the wire. mkdir
#       always creates the whole tree (mkdir -p semantics) - Do-Mkdir on
#       the responder side already works that way unconditionally (see
#       its own comment), so there's no flag needed to ask for it. stat
#       prints type/size/mtime/atime/birthtime, plus immediate file/dir
#       counts for a directory - a single STAT request, no LIST/RECURSE
#       pagination involved.
#
# Every parameter also has a single-letter alias matching the POSIX
# script's getopts flag (-l/-s/-k/-T/-r/-1... i.e. -FullPath), so the two
# are driven identically where PowerShell's own parameter-binding allows
# it. -Timeout
# has no such alias: PowerShell resolves parameter aliases
# case-insensitively, so a "t" alias on -Timeout would collide with -Tor's
# "T" (both normalize to the same key) and PowerShell throws an ambiguous-
# parameter error on every invocation, not just ones that actually use
# either flag - bash's getopts can tell -t/-T apart by case, PowerShell's
# binder can't. Use -Timeout spelled out.
#
# get/put take independent local and remote paths (sftp/scp-style) - the
# local path is whatever this machine's file is actually at, the remote
# path is what gets sent on the wire (subject to ../PROTOCOL.md's "Path
# rules"). Each defaults to the other's basename if omitted.
#
# -Recursive recurses into directories for ls/get/put, rsync -r style -
# the source path's trailing slash controls whether its own basename
# becomes an extra destination directory level - see
# ../posix/gs-transfer.sh's header comment for the worked examples
# (identical semantics here).
#
# -Recursive/-FullPath are shown above after the subcommand, to match
# ../posix/gs-transfer.sh's own getopts-enforced ordering there - but
# PowerShell's own parameter binder doesn't actually enforce that: it
# resolves named/aliased tokens wherever they appear and fills Command/
# Arg1/Arg2 positionally from whatever's left, so `get -r remote local`
# and `get remote local -Recursive` bind identically either way. There
# is also no "--" end-of-options sentinel here, unlike the POSIX
# script - "--" isn't special to this script's own parameter binding
# (PowerShell's "--%" stop-parsing operator only applies when calling a
# native executable, not this script's own declared parameters), so a
# remote/local path that itself starts with "-" has no literal escape
# on this side yet.
#
# get/put resume automatically whenever an interrupted attempt left a
# usable partial behind - no flag needed. See ../PROTOCOL.md's
# "Partial-file safety" for the full mechanism.
#
# Either way, once gs-netcat.exe's -e actually execs this script (server
# worker mode), or once this script spawns gs-netcat.exe itself (client
# mode), the raw Streams are used throughout - never Console.In/Out,
# StreamReader/StreamWriter's text wrappers, or Write-Host for protocol
# I/O - so binary payloads can't be corrupted by any TextReader's own
# buffering/newline translation. Same reason the POSIX script uses
# `head -c`/`tail -c` instead of `read` for payload bytes.
param(
	[Alias("l")][switch]$Listen,
	[Alias("s")][string]$Secret,
	[Alias("k")][string]$SecretFile,
	[Alias("T")][switch]$Tor,
	[int]$Timeout = 30,
	[Alias("r")][switch]$Recursive,
	[Alias("1")][switch]$FullPath,
	[Parameter(Position = 0)][string]$Command,
	[Parameter(Position = 1)][string]$Arg1,
	[Parameter(Position = 2)][string]$Arg2,
	[Alias("h", "?")][switch]$Help
)

# Plain stdout/stderr writes for launcher and client mode's own
# human-readable status output - deliberately not Write-Host/Write-Error.
# Write-Host writes to the Information stream (6), which a bare `>`
# (stream 1) never captures - piping/redirecting this script's stdout
# silently drops everything printed via Write-Host even though it still
# shows up live on screen. Write-Error does get captured by `2>`, but
# wraps every message in PowerShell's own multi-line ErrorRecord format
# instead of the clean single-line text a native tool's stderr would
# produce. These two write straight to the real OS-level stdout/stderr
# streams instead. Defined this early (before Show-Usage, which uses
# them) deliberately - PowerShell only defines a function once that
# `function` statement itself has executed, not hoisted to the top of
# the script, and Show-Usage can be called as early as the -Help check
# right after the param block below.
function Write-Out([string]$text) {
	[Console]::Out.WriteLine($text)
}
function Write-Err([string]$text) {
	[Console]::Error.WriteLine($text)
}

# Single source of truth for usage text - mirrors ../posix/gs-transfer.sh's
# own usage() (same two lines, same content, just PowerShell's parameter
# names in place of getopts flags) - called whenever the command verb is
# missing or unrecognized, and for an explicit -Help, instead of each call
# site keeping its own (previously out-of-sync) copy.
function Show-Usage {
	Write-Err "Usage: $PSCommandPath -Listen [-Secret <secret>|-SecretFile <file>] [-Tor]"
	Write-Err "       $PSCommandPath [-Secret <secret>|-SecretFile <file>] [-Tor] [-Timeout <sec>] ls [-Recursive] [-FullPath] [path] | get [-Recursive] <remote-path> [local-path] | put [-Recursive] <local-path> [remote-path] | pwd | mkdir <remote-path> | stat [path]"
}

$DataTimeout = 300
# Not exposed as a flag, same reasoning as $DataTimeout above: rarely the
# right thing to tune per-invocation. Used as <maxcount> for every
# LIST/RECURSE call this client makes - large enough that a typical
# directory completes in one round trip, small enough to bound
# worst-case response size for a pathological one.
$PageSize = 1000

if ($Help) {
	Show-Usage
	exit 0
}

# Worker if EITHER signal says so - see gs-transfer-server.sh's original
# header comment for the full rationale (short version: the old, manual
# invocation style must keep working, and it never sets
# $env:GSTRANSFER_WORKER - gs-netcat.exe's -e passes no arguments of its
# own either - so that marker alone can't tell "exec'd by gs-netcat's own
# -e" apart from "launched fresh by a human". stdin's own nature is the
# fallback signal. The raw Win32 GetFileType is used over .NET's
# Console.IsInputRedirected because it correctly tells a real pipe
# (gs-netcat's own -e wiring, or client mode's own subprocess pipes) apart
# from a /dev/null-redirected background launch, which
# IsInputRedirected can't.
# A type loaded via Add-Type lives for the rest of this PowerShell
# process - it can never be redefined or unloaded, so re-running this
# script in the same session (a normal workflow, not a one-off) would
# otherwise hit "type already exists" on every run after the first. The
# guard below makes re-running safe; it doesn't retroactively fix a type
# that was already loaded by an older copy of this script earlier in the
# same session (that copy's definition is what's stuck until the session
# restarts) - only new sessions get the current one.
if (-not ([System.Management.Automation.PSTypeName]"GSTransferWin32").Type) {
	Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class GSTransferWin32 {
	[DllImport("kernel32.dll", SetLastError = true)]
	public static extern uint GetFileType(IntPtr hFile);
	[DllImport("kernel32.dll", SetLastError = true)]
	public static extern IntPtr GetStdHandle(int nStdHandle);
	[DllImport("kernel32.dll", SetLastError = true)]
	public static extern IntPtr GetConsoleWindow();
}
"@
}
$FILE_TYPE_PIPE = 3
$STD_INPUT_HANDLE = -10
$stdinIsPipe = ([GSTransferWin32]::GetFileType([GSTransferWin32]::GetStdHandle($STD_INPUT_HANDLE)) -eq $FILE_TYPE_PIPE)
# GetFileType alone isn't enough: a ConPTY-backed terminal (Windows
# Terminal, VS Code's integrated terminal, anything that isn't classic
# conhost) also hands its child a pipe as stdin, so a live interactive
# session reads as FILE_TYPE_PIPE too, indistinguishable from gs-netcat's
# own -e child by that signal alone. A real -e child has no console
# window at all; an interactive ConPTY session still does, even though
# its stdio handles are pipes under the hood - so both must hold before
# this is treated as the worker, not stdin-is-a-pipe by itself.
$hasNoConsole = ([GSTransferWin32]::GetConsoleWindow() -eq [IntPtr]::Zero)

# ============================================================================
# Shared local-filesystem helpers - used by both the server's PUT handler
# and the client's get/put handlers below (partial-file staging/resume
# safety is identical on both sides of the wire).
# ============================================================================

# Deterministic staging path for a GET/PUT target - known in advance,
# never scanned for. Safety against a planted symlink at this exact,
# guessable path comes from New-ExclusiveFile's atomicity and
# Test-SafePartial's vetting below, not from making the name
# unpredictable (see ../PROTOCOL.md's "Partial-file safety").
function Get-PartialPath([string]$target) {
	$dir = Split-Path -Parent $target
	$base = Split-Path -Leaf $target
	if ([string]::IsNullOrEmpty($dir)) {
		return ".$base.partial"
	}
	return (Join-Path $dir ".$base.partial")
}

# A partial is only trustworthy if it's a plain file - never a reparse
# point (symlink/junction), even one pointing at a legitimate file (it
# could be swapped out from under us, or planted by another party on a
# shared directory).
function Test-SafePartial([string]$p) {
	$item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
	if ($null -eq $item) { return $false }
	if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $false }
	return -not $item.PSIsContainer
}

# True only if nothing exists at $p, or what's there is a plain file we
# can safely remove ourselves. Never touches a reparse point or
# anything else - that might not be ours to remove.
function Reset-Partial([string]$p) {
	if (Test-Path -LiteralPath $p) {
		if (-not (Test-SafePartial $p)) { return $false }
		Remove-Item -LiteralPath $p -Force
	}
	return $true
}

# Atomically creates $p only if nothing exists there yet - never
# follows or overwrites a pre-existing path of any kind, reparse point
# included. Returns the open stream (ready to write) on success, $null
# on failure - the caller must close it.
function New-ExclusiveFile([string]$p) {
	try {
		return [System.IO.File]::Open($p, [System.IO.FileMode]::CreateNew)
	} catch {
		return $null
	}
}

# Hash of just the first $n bytes of $p - bounded by how much has
# actually been transferred so far, never the whole file, so resume
# validation never costs more than the resume itself already did.
function Get-PrefixHash([string]$p, [int64]$n) {
	$sha = [System.Security.Cryptography.SHA256]::Create()
	$fs = [System.IO.File]::OpenRead($p)
	try {
		$buf = New-Object byte[] 65536
		$remaining = $n
		while ($remaining -gt 0) {
			$toRead = [Math]::Min($buf.Length, $remaining)
			$read = $fs.Read($buf, 0, $toRead)
			if ($read -le 0) { break }
			[void]$sha.TransformBlock($buf, 0, $read, $buf, 0)
			$remaining -= $read
		}
		[void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
		return [BitConverter]::ToString($sha.Hash).Replace("-", "").ToLower()
	} finally {
		$fs.Close()
	}
}

# Byte-oriented line/stream I/O, parameterized over an explicit stream
# instead of closing over a fixed global - shared between server worker
# mode (stdin/stdout of the tunnel) and client mode (the gs-netcat.exe
# subprocess's piped stdin/stdout).
function Write-Line([System.IO.Stream]$stream, [string]$text) {
	$bytes = [System.Text.Encoding]::ASCII.GetBytes($text + "`n")
	$stream.Write($bytes, 0, $bytes.Length)
	$stream.Flush()
}

function Read-Line([System.IO.Stream]$stream) {
	$bytes = New-Object System.Collections.Generic.List[byte]
	while ($true) {
		$b = $stream.ReadByte()
		if ($b -eq -1) { if ($bytes.Count -eq 0) { return $null } else { break } }
		if ($b -eq 10) { break }  # LF
		$bytes.Add([byte]$b)
	}
	return [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
}

function Read-ExactBytes([System.IO.Stream]$stream, [int64]$count) {
	$buf = New-Object byte[] $count
	$off = 0
	while ($off -lt $count) {
		$n = $stream.Read($buf, $off, $count - $off)
		if ($n -le 0) { break }
		$off += $n
	}
	return $buf
}

function Copy-ExactBytes([System.IO.Stream]$src, [System.IO.Stream]$dst, [int64]$count) {
	$bufSize = 65536
	$buf = New-Object byte[] $bufSize
	$remaining = $count
	while ($remaining -gt 0) {
		$toRead = [Math]::Min($bufSize, $remaining)
		$n = $src.Read($buf, 0, $toRead)
		if ($n -le 0) { break }
		$dst.Write($buf, 0, $n)
		$remaining -= $n
	}
	$dst.Flush()
}

if (($env:GSTRANSFER_WORKER -ne "1") -and (-not ($stdinIsPipe -and $hasNoConsole))) {
	# ========================================================================
	# Outer mode: either launcher (server, if -Listen) or client. -Listen
	# is the discriminator - everything else about the flags is shared.
	# ========================================================================
	if ($Listen) {
		# --- Server (launcher) mode: become gs-netcat.exe -l, which will
		# later exec a fresh copy of this same script (in worker mode, via
		# -e) for each connection it accepts. ---
		$scriptDir = Split-Path -Parent $PSCommandPath
		$netcatExe = Join-Path $scriptDir "gs-netcat.exe"
		if (-not (Test-Path -LiteralPath $netcatExe -PathType Leaf)) {
			$found = Get-Command "gs-netcat.exe" -ErrorAction SilentlyContinue
			if ($null -eq $found) {
				Write-Err "gs-netcat.exe not found. Check PATH=?"
				exit 1
			}
			$netcatExe = $found.Source
		}

		$gsncArgs = @("-l")
		if ($Secret) { $gsncArgs += @("-s", $Secret) }
		if ($SecretFile) { $gsncArgs += @("-k", $SecretFile) }
		if ($Tor) { $gsncArgs += "-T" }

		# -e's value is passed verbatim as the raw CreateProcess command
		# line - no extra shell layer - so it has to already be a
		# correctly-quoted Win32 command line, not just a bare path.
		$innerCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
		$gsncArgs += @("-e", $innerCmd)

		# Scoped to this one listener run: running ./gs-transfer.ps1 directly
		# in an interactive console executes in that SAME PowerShell process
		# (no new process the way bash forking a script would), so setting
		# $env:GSTRANSFER_WORKER here otherwise permanently mutates the
		# calling session's real environment block - every later invocation
		# in that same window would see it still "=1", skip this whole
		# outer-mode block unconditionally (never even checking -Listen),
		# and fall straight into the worker read-loop on the user's actual
		# keyboard. The cleanup has to be in a finally, not just the next
		# statement after `&` - Ctrl+C while the listener is running raises
		# a pipeline-stop that unwinds straight out of the script, skipping
		# any cleanup that isn't guaranteed to run during that unwind; a
		# finally block is - that's the one thing Ctrl+C can't skip.
		$ncExitCode = 0
		$env:GSTRANSFER_WORKER = "1"
		try {
			& $netcatExe @gsncArgs
			$ncExitCode = $LASTEXITCODE
		} finally {
			Remove-Item Env:\GSTRANSFER_WORKER -ErrorAction SilentlyContinue
		}
		exit $ncExitCode
	}

	# ========================================================================
	# Client mode (default, no -Listen).
	# ========================================================================
	if (-not $Command) {
		Show-Usage
		exit 1
	}

	$scriptDir = Split-Path -Parent $PSCommandPath
	$netcatExe = Join-Path $scriptDir "gs-netcat.exe"
	if (-not (Test-Path -LiteralPath $netcatExe -PathType Leaf)) {
		$found = Get-Command "gs-netcat.exe" -ErrorAction SilentlyContinue
		if ($null -eq $found) {
			Write-Err "gs-netcat.exe not found. Check PATH=?"
			exit 1
		}
		$netcatExe = $found.Source
	}

	$gsncArgs = @()
	if ($Secret) { $gsncArgs += @("-s", $Secret) }
	if ($SecretFile) { $gsncArgs += @("-k", $SecretFile) }
	if ($Tor) { $gsncArgs += "-T" }

	$psi = New-Object System.Diagnostics.ProcessStartInfo
	$psi.FileName = $netcatExe
	# Built as a single pre-quoted command-line string, not .ArgumentList -
	# that property is absent on older Windows PowerShell/.NET Framework
	# combinations (returns $null instead of throwing, which is why a
	# missing one surfaces as "cannot call a method on a null-valued
	# expression" rather than a clearer "property not found").
	$psi.Arguments = ($gsncArgs | ForEach-Object {
		$escaped = $_ -replace '"', '\"'
		if ($escaped -eq "" -or $escaped -match '\s') { '"' + $escaped + '"' } else { $escaped }
	}) -join " "
	$psi.RedirectStandardInput = $true
	$psi.RedirectStandardOutput = $true
	$psi.UseShellExecute = $false
	$gsncProc = [System.Diagnostics.Process]::Start($psi)

	# .BaseStream on both - raw bytes, same rationale as the module header
	# comment (never the StreamReader/StreamWriter text wrappers).
	$clientIn = $gsncProc.StandardOutput.BaseStream
	$clientOut = $gsncProc.StandardInput.BaseStream

	function Quit-Client {
		try {
			Write-Line $clientOut "QUIT"
		} catch { }
		if (-not $gsncProc.WaitForExit(3000)) {
			# Kill this exact process - never by image name (a shared-
			# machine "taskkill by name" mistake took down unrelated
			# processes earlier in this project; this only ever targets
			# the specific process this script itself just spawned).
			try { $gsncProc.Kill() } catch { }
		}
	}

	# Bytes -> "118KB"/"3.4MB" style (IEC units).
	function Format-HumanSize([int64]$n) {
		$units = @("B", "KB", "MB", "GB", "TB")
		$val = [double]$n
		$i = 0
		while ($val -ge 1024 -and $i -lt $units.Length - 1) { $val /= 1024; $i++ }
		if ($i -eq 0) { return "$n B" }
		return ("{0:N1}{1}" -f $val, $units[$i])
	}

	# Unix epoch -> "2026-11-02 14:30" style, local time.
	function Format-HumanDate([int64]$epoch) {
		return [DateTimeOffset]::FromUnixTimeSeconds($epoch).ToLocalTime().ToString("yyyy-MM-dd HH:mm")
	}

	# Reads one control line bounded by $Timeout seconds - the ReadAsync +
	# Task.Wait(ms) pattern is the .NET equivalent of bash's `read -t`:
	# each byte-read is given its own bounded wait, so a responder that
	# never answers (crash, protocol mismatch, dead connection) can't leave
	# this blocked forever. Returns $null on timeout/EOF.
	function Read-LineTimeout([System.IO.Stream]$stream, [int]$timeoutSec) {
		$bytes = New-Object System.Collections.Generic.List[byte]
		$buf = New-Object byte[] 1
		while ($true) {
			$task = $stream.ReadAsync($buf, 0, 1)
			if (-not $task.Wait($timeoutSec * 1000)) { return $null }
			$n = $task.Result
			if ($n -eq 0) { if ($bytes.Count -eq 0) { return $null } else { break } }
			if ($buf[0] -eq 10) { break }
			$bytes.Add($buf[0])
		}
		return [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
	}

	# Receive-direction counterpart of Copy-ExactBytes, bounded by
	# $timeoutSec per chunk instead of running unbounded - matches the
	# POSIX client wrapping its data phase in `timeout "$DATA_TIMEOUT"`.
	# Returns $false (instead of throwing) on timeout/short-read so
	# callers can leave a partial in place for a later resume.
	function Copy-ExactBytesTimeout([System.IO.Stream]$src, [System.IO.Stream]$dst, [int64]$count, [int]$timeoutSec) {
		$bufSize = 65536
		$buf = New-Object byte[] $bufSize
		$remaining = $count
		while ($remaining -gt 0) {
			$toRead = [Math]::Min($bufSize, $remaining)
			$task = $src.ReadAsync($buf, 0, $toRead)
			if (-not $task.Wait($timeoutSec * 1000)) { return $false }
			$n = $task.Result
			if ($n -le 0) { return $false }
			$dst.Write($buf, 0, $n)
			$remaining -= $n
		}
		$dst.Flush()
		return $true
	}

	# Send-direction counterpart - same per-chunk timeout bound, in case
	# the far end stops draining mid-transfer.
	function Send-ExactBytesTimeout([System.IO.Stream]$src, [System.IO.Stream]$dst, [int64]$count, [int]$timeoutSec) {
		$bufSize = 65536
		$buf = New-Object byte[] $bufSize
		$remaining = $count
		while ($remaining -gt 0) {
			$toRead = [Math]::Min($bufSize, $remaining)
			$n = $src.Read($buf, 0, $toRead)
			if ($n -le 0) { break }
			$task = $dst.WriteAsync($buf, 0, $n)
			if (-not $task.Wait($timeoutSec * 1000)) { return $false }
			$remaining -= $n
		}
		$dst.Flush()
		return $true
	}

	# Joins a wire-format remote path, collapsing a "." (or empty) base
	# so the result doesn't carry an ugly "./" prefix.
	function Join-RemotePath([string]$base, [string]$name) {
		if ([string]::IsNullOrEmpty($base) -or $base -eq ".") { return $name }
		return "$base/$name"
	}

	# rsync -r trailing-slash semantics: if $src ends with / or \, its own
	# contents land directly in $destRoot; otherwise $src's basename is
	# appended as an extra destination directory level. -RemoteOutput
	# picks forward-slash joining (wire-format remote paths, used by
	# `put -r`) vs native Join-Path (local filesystem paths, used by
	# `get -r`) - $src's own basename extraction works the same either
	# way since Split-Path -Leaf accepts both separators.
	function Get-EffectiveDest([string]$src, [string]$destRoot, [switch]$RemoteOutput) {
		if ([string]::IsNullOrEmpty($destRoot)) {
			$destRoot = "."
		} elseif ($RemoteOutput) {
			$destRoot = $destRoot.TrimEnd('/')
		} else {
			$destRoot = $destRoot.TrimEnd('\', '/')
		}
		if ($src.EndsWith("/") -or $src.EndsWith("\")) { return $destRoot }
		$base = Split-Path -Leaf ($src.TrimEnd('/', '\'))
		if ($destRoot -eq ".") { return $base }
		if ($RemoteOutput) { return "$destRoot/$base" }
		return (Join-Path $destRoot $base)
	}

	function Write-ListingLine([string]$type, [int64]$size, [int64]$mtime, [string]$name) {
		$dateStr = Format-HumanDate $mtime
		if ($type -eq "D") {
			Write-Out ("{0,-10}  {1,-16}  {2}/" -f "-", $dateStr, "$name")
		} else {
			Write-Out ("{0,-10}  {1,-16}  {2}" -f (Format-HumanSize $size), $dateStr, "$name")
		}
	}

	# -FullPath's "no columns, just the path" renderer - the point is a
	# clean, one-path-per-line list that's safe to capture/redirect and
	# reuse later, matching real bash `ls -1`'s own bare-name-per-line
	# output (just using the full server-relative path instead of a bare
	# name, since gs-transfer's glob/recursive listings can span multiple
	# directories where a bare name alone would be ambiguous). Applies
	# uniformly to every listing path - plain, glob, and recursive - not
	# just the plain case.
	function Write-PathOnlyLine([string]$type, [int64]$size, [int64]$mtime, [string]$name) {
		Write-Out $name
	}

	# True if $path contains a glob metacharacter (* or ?) anywhere - the
	# trigger for glob matching in ls/get. Accepted tradeoff, same one
	# every shell glob already makes: a real remote filename literally
	# containing * or ? can no longer be fetched by exact name.
	# True if $path contains an *unescaped* glob metacharacter (*, ?,
	# [, or {) anywhere - the trigger for glob matching in ls/get. A
	# backslash escapes the very next character unconditionally (bash's
	# own rule, not just before a special char), so an escaped "\*" etc.
	# never counts. Deliberately conservative about [ and {: even a
	# malformed one (no matching close, or otherwise unparseable) still
	# triggers "treat as glob" here - ConvertTo-GlobRegexBody below
	# degrades a malformed one back to a literal character anyway, so
	# at worst this costs an unnecessary LIST/RECURSE round trip for
	# what turns out to be an exact match, never an incorrect result.
	function Test-IsGlob([string]$path) {
		$i = 0; $n = $path.Length
		while ($i -lt $n) {
			$c = $path.Substring($i, 1)
			if ($c -eq '\' -and ($i + 1) -lt $n) { $i += 2; continue }
			if ($c -in @('*', '?', '[', '{')) { return $true }
			$i++
		}
		return $false
	}

	# Strips backslash-escapes from a path that Test-IsGlob already said
	# isn't a glob at all - a user may still type e.g. "weird\*file" to
	# be unambiguous about a literal special character even when the
	# path as a whole has no real wildcard elsewhere, and that backslash
	# must never reach the wire: the protocol has no escape-sequence
	# concept of its own (Test-SafePath rejects a literal "\" outright),
	# so every non-glob path ls/get actually sends - plain or -Recursive
	# - runs through this first.
	function Remove-GlobEscapes([string]$path) {
		$out = ""
		$i = 0; $n = $path.Length
		while ($i -lt $n) {
			$c = $path.Substring($i, 1)
			if ($c -eq '\' -and ($i + 1) -lt $n) {
				$out += $path.Substring($i + 1, 1)
				$i += 2
				continue
			}
			$out += $c
			$i++
		}
		return $out
	}

	# Splits $pattern into .Prefix (literal segments before the first
	# wildcard segment, "." if none) and .Suffix (that segment through
	# the end) - see docs/gs-transfer-client-plan.md (kept local, not
	# part of this repo) for the full design. Only ever called after
	# Test-IsGlob confirms a wildcard exists somewhere. Per-segment
	# wildcard test reuses Test-IsGlob directly, so escaping stays
	# consistent between "where does the literal prefix end" and "is
	# this a glob at all".
	function Split-GlobPattern([string]$pattern) {
		$segs = $pattern.Split('/')
		$i = 0
		$prefixParts = @()
		while ($i -lt $segs.Length) {
			if (Test-IsGlob $segs[$i]) { break }
			$prefixParts += $segs[$i]
			$i++
		}
		$prefix = if ($prefixParts.Length -eq 0) { "." } else { $prefixParts -join '/' }
		$suffix = ($segs[$i..($segs.Length - 1)]) -join '/'
		return [PSCustomObject]@{ Prefix = $prefix; Suffix = $suffix }
	}

	# Splits $s on unescaped "," into a list of alternative substrings -
	# an escaped comma (\,) stays part of its own alternative untouched,
	# so the recursive ConvertTo-GlobRegexBody call on that alternative
	# is what actually interprets the escape.
	function Split-GlobCommas([string]$s) {
		$alts = New-Object System.Collections.Generic.List[string]
		$i = 0; $n = $s.Length; $cur = ""
		while ($i -lt $n) {
			$c = $s.Substring($i, 1)
			if ($c -eq '\' -and ($i + 1) -lt $n) { $cur += $s.Substring($i, 2); $i += 2; continue }
			if ($c -eq ',') { $alts.Add($cur); $cur = ""; $i++; continue }
			$cur += $c; $i++
		}
		$alts.Add($cur)
		return $alts
	}

	# Parses $inner as a brace sequence expression ("x..y" or
	# "x..y..incr") into a list of literal terms, or $null if it isn't
	# one - bash's own rule: x and y must be the same type (both integer
	# or both a single letter); if either has a leading zero, every
	# generated term is zero-padded to match the widest of the two; the
	# default increment is 1 (direction inferred from x <= y), an
	# explicit increment's magnitude is used with the inferred direction
	# (not replicating bash's exact behavior for a *given* increment
	# whose sign already contradicts the x/y direction - vanishingly
	# rare, not worth chasing).
	function Get-GlobBraceSequenceTerms([string]$inner) {
		$m = [regex]::Match($inner, '^(-?[0-9]+|[A-Za-z])\.\.(-?[0-9]+|[A-Za-z])(\.\.(-?[0-9]+))?$')
		if (-not $m.Success) { return $null }
		$x = $m.Groups[1].Value
		$y = $m.Groups[2].Value
		$incrRaw = $m.Groups[4].Value
		$terms = New-Object System.Collections.Generic.List[string]
		if ($x -match '^-?[0-9]+$') {
			if ($y -notmatch '^-?[0-9]+$') { return $null }
			$xa = $x.TrimStart('-')
			$ya = $y.TrimStart('-')
			$width = 0
			if (($xa.StartsWith("0") -and $xa.Length -gt 1) -or ($ya.StartsWith("0") -and $ya.Length -gt 1)) {
				$width = [Math]::Max($xa.Length, $ya.Length)
			}
			$xNum = [int64]$xa; if ($x.StartsWith("-")) { $xNum = -$xNum }
			$yNum = [int64]$ya; if ($y.StartsWith("-")) { $yNum = -$yNum }
			$incr = 1
			if ($incrRaw) { $incr = [int64]($incrRaw.TrimStart('-')) }
			if ($incr -eq 0) { $incr = 1 }
			$step = if ($xNum -le $yNum) { $incr } else { -$incr }
			$i = $xNum
			while ($true) {
				if ($step -gt 0 -and $i -gt $yNum) { break }
				if ($step -lt 0 -and $i -lt $yNum) { break }
				$neg = $i -lt 0
				$term = [Math]::Abs($i).ToString()
				while ($width -gt 0 -and $term.Length -lt $width) { $term = "0$term" }
				if ($neg) { $term = "-$term" }
				$terms.Add($term)
				$i += $step
			}
		} else {
			if ($x -notmatch '^[A-Za-z]$' -or $y -notmatch '^[A-Za-z]$') { return $null }
			$xo = [int][char]$x
			$yo = [int][char]$y
			$stepc = 1
			if ($incrRaw) { $stepc = [int]($incrRaw.TrimStart('-')) }
			if ($stepc -eq 0) { $stepc = 1 }
			$step = if ($xo -le $yo) { $stepc } else { -$stepc }
			$co = $xo
			while ($true) {
				if ($step -gt 0 -and $co -gt $yo) { break }
				if ($step -lt 0 -and $co -lt $yo) { break }
				$terms.Add([char]$co)
				$co += $step
			}
		}
		return $terms
	}

	# Translates $pattern (a glob suffix - see Split-GlobPattern) into a
	# .NET regex body (no anchors - ConvertTo-GlobRegex below adds
	# ^...$ at the top level; recursive calls for brace alternatives
	# call this directly to get just the body). * -> [^/]*, ? -> [^/],
	# **/ -> zero-or-more whole segments ((.*/)?) - makes **/*.txt
	# match both readme.txt (root) and a/b/readme.txt (any depth) -
	# bare ** (no following /) -> .*, everything else escaped via
	# [regex]::Escape. Known, accepted asymmetry: a *trailing* bare **
	# with nothing after it (photos/**) falls through to the generic .*
	# branch rather than getting the same "optional" treatment - not
	# worth special-casing for a pattern shape nobody asked for.
	#
	# \X escapes the very next character unconditionally, not just
	# before a special one - the escaping backslash is discarded, same
	# rule bash itself uses.
	#
	# [...] bracket expressions translate almost verbatim - .NET regex
	# already supports the same plain set/range/negation syntax bash's
	# own bracket expressions use. Only normalization needed: bash
	# accepts *either* "!" or "^" for negation, .NET only recognizes
	# "^". A "]" immediately after "[" or after a leading "!"/"^" is a
	# literal member of the set, not the closing bracket (bash's own
	# rule). No matching "]" at all -> malformed, falls through to a
	# literal "\[" (matches bash's "incorrectly formed... left
	# unchanged" philosophy). No POSIX named-class ([:alpha:] etc.)
	# support - a literal "[:" sequence just becomes ordinary
	# bracket-set characters in the output, a known, accepted quirk
	# rather than an error.
	#
	# {...} brace expansion - one, non-nested, same-segment group per
	# pattern (no "/" inside an alternative - that would need a
	# different prefix/suffix per alternative, which is exactly the
	# rearchitecture this design deliberately avoids). No matching "}",
	# or a "/" inside -> malformed, same literal "\{" fallback as a bad
	# bracket. Comma-list alternatives (Split-GlobCommas) and sequence
	# expressions (Get-GlobBraceSequenceTerms) are the two recognized
	# forms - neither -> malformed, same fallback. Each alternative/term
	# is recursively run back through this same function (so
	# "*.{txt,log}" or "img{1,[2-4]}.png" work - an alternative can
	# itself contain "*"/"?"/"[...]", just not another "{...}" or a
	# "/"), joined with "|". .NET regex actually tolerates an empty
	# alternative inside a group ("(|txt)"), but POSIX ERE (bash's own
	# [[ =~ ]] engine) does not - to keep both clients' behavior
	# identical rather than quietly diverging, an empty alternative
	# (e.g. "{,txt}") is handled the same way on both sides: it makes
	# the whole group optional over the remaining ones ("(txt)?"); if
	# every alternative was empty, the group contributes nothing at all.
	function ConvertTo-GlobRegexBody([string]$pattern) {
		$out = ""
		$i = 0
		$n = $pattern.Length
		while ($i -lt $n) {
			$c = $pattern.Substring($i, 1)
			if ($c -eq '\' -and ($i + 1) -lt $n) {
				$nc = $pattern.Substring($i + 1, 1)
				$out += [regex]::Escape($nc)
				$i += 2
				continue
			}
			if ($c -eq '*' -and $pattern.Substring($i, [Math]::Min(2, $n - $i)) -eq '**') {
				if ($i + 2 -lt $n -and $pattern.Substring($i + 2, 1) -eq '/') {
					$out += "(.*/)?"
					$i += 3
				} else {
					$out += ".*"
					$i += 2
				}
				continue
			}
			if ($c -eq '*') { $out += "[^/]*"; $i++; continue }
			if ($c -eq '?') { $out += "[^/]"; $i++; continue }
			if ($c -eq '[') {
				$j = $i + 1; $close = -1
				if ($j -lt $n -and ($pattern.Substring($j, 1) -eq '!' -or $pattern.Substring($j, 1) -eq '^')) { $j++ }
				if ($j -lt $n -and $pattern.Substring($j, 1) -eq ']') { $j++ }
				while ($j -lt $n) {
					if ($pattern.Substring($j, 1) -eq ']') { $close = $j; break }
					$j++
				}
				if ($close -lt 0) { $out += "\["; $i++; continue }
				$inner = $pattern.Substring($i + 1, $close - $i - 1)
				if ($inner.StartsWith("!")) { $inner = "^" + $inner.Substring(1) }
				$out += "[$inner]"
				$i = $close + 1
				continue
			}
			if ($c -eq '{') {
				$j = $i + 1; $close = -1
				while ($j -lt $n) {
					$cj = $pattern.Substring($j, 1)
					if ($cj -eq '\' -and ($j + 1) -lt $n) { $j += 2; continue }
					if ($cj -eq '}') { $close = $j; break }
					$j++
				}
				$inner = ""; $hasSlash = $false
				if ($close -ge 0) {
					$inner = $pattern.Substring($i + 1, $close - $i - 1)
					$hasSlash = $inner.Contains('/')
				}
				if ($close -lt 0 -or $hasSlash) { $out += "\{"; $i++; continue }
				$subRegexes = New-Object System.Collections.Generic.List[string]
				$matched = $false
				if ($inner.Contains(',')) {
					$alts = Split-GlobCommas $inner
					foreach ($alt in $alts) { $subRegexes.Add((ConvertTo-GlobRegexBody $alt)) }
					$matched = $true
				} else {
					$terms = Get-GlobBraceSequenceTerms $inner
					if ($null -ne $terms) {
						foreach ($term in $terms) { $subRegexes.Add((ConvertTo-GlobRegexBody $term)) }
						$matched = $true
					}
				}
				if (-not $matched) { $out += "\{"; $i++; continue }
				$nonempty = New-Object System.Collections.Generic.List[string]
				$hasEmpty = $false
				foreach ($sr in $subRegexes) {
					if ([string]::IsNullOrEmpty($sr)) { $hasEmpty = $true } else { $nonempty.Add($sr) }
				}
				if ($nonempty.Count -gt 0) {
					$joined = [string]::Join("|", $nonempty)
					if ($hasEmpty) { $out += "($joined)?" } else { $out += "($joined)" }
				}
				$i = $close + 1
				continue
			}
			$out += [regex]::Escape($c)
			$i++
		}
		return $out
	}

	function ConvertTo-GlobRegex([string]$suffix) {
		return "^" + (ConvertTo-GlobRegexBody $suffix) + '$'
	}

	# True if $suffix (a glob suffix) needs a full recursive walk
	# (RECURSE) rather than a single-level LIST - either it spans
	# multiple segments, or it contains an unescaped "**" anywhere (a
	# bare "**" is itself one segment but still needs the full walk,
	# since it can match any depth). Escape-aware like Test-IsGlob
	# above, so a literal "\*\*" (an actual two-asterisk filename)
	# doesn't get misread as the trigger.
	function Test-GlobIsComplex([string]$suffix) {
		$i = 0; $n = $suffix.Length
		while ($i -lt $n) {
			$c = $suffix.Substring($i, 1)
			if ($c -eq '\' -and ($i + 1) -lt $n) { $i += 2; continue }
			if ($c -eq '/') { return $true }
			if ($c -eq '*' -and $suffix.Substring($i, [Math]::Min(2, $n - $i)) -eq '**') { return $true }
			$i++
		}
		return $false
	}

	# Shared by Invoke-RemoteWalk (RECURSE) and Invoke-PaginatedList
	# (LIST): sends "<verb> <path> <pageSize> [<cursor>]" repeatedly,
	# fully draining each page (through END/MORE) before invoking
	# $Callback once per entry - the wire protocol is strictly
	# request/response, and a callback that issues its own request (GET)
	# must never race a still-in-flight page. $Callback receives (type,
	# size, mtime, name) where name is whatever the responder returned
	# verbatim - a bare basename for LIST, a full relpath for RECURSE;
	# Invoke-RemoteWalk below is responsible for translating that into
	# its own callback's richer signature.
	function Invoke-PaginatedRequest([System.IO.Stream]$inStream, [System.IO.Stream]$outStream, [string]$verb, [string]$path, [int]$pageSize, [int]$timeoutSec, [scriptblock]$Callback) {
		$cursor = $null
		while ($true) {
			if ($cursor) {
				Write-Line $outStream "$verb $path $pageSize $cursor"
			} else {
				Write-Line $outStream "$verb $path $pageSize"
			}
			$entries = @()
			$atEnd = $false
			$moreCursor = $null
			while ($true) {
				$line = Read-LineTimeout $inStream $timeoutSec
				if ($null -eq $line) { Write-Err "timed out (${timeoutSec}s) or lost connection waiting for a response"; exit 1 }
				if ($line -eq "END") { $atEnd = $true; break }
				if ($line.StartsWith("MORE ")) { $moreCursor = $line.Substring(5); break }
				if ($line.StartsWith("ERR ")) { Write-Err "server: $($line.Substring(4)) ($path)"; exit 1 }
				$parts = $line.Split(" ", 4)
				$entries += [PSCustomObject]@{ Type = $parts[0]; Size = [int64]$parts[1]; Mtime = [int64]$parts[2]; Name = $parts[3] }
			}
			foreach ($e in $entries) {
				& $Callback $e.Type $e.Size $e.Mtime $e.Name
			}
			if ($atEnd) { break }
			$cursor = $moreCursor
		}
	}

	# Recursively walks $remoteRoot (a directory on the responder) via
	# RECURSE, paginated ($PageSize entries per page - the server does
	# the actual recursion now, this just pages through a flat result
	# stream via Invoke-PaginatedRequest above). Invokes $Callback once
	# per entry found, as:
	#   & $Callback <type> <size> <mtime> <relpath> <remoteRoot>
	# where <relpath> is always relative to $remoteRoot and always /-
	# separated, regardless of the responder's own platform.
	function Invoke-RemoteWalk([System.IO.Stream]$inStream, [System.IO.Stream]$outStream, [string]$remoteRoot, [int]$timeoutSec, [scriptblock]$Callback) {
		$inner = {
			param($type, $size, $mtime, $relpath)
			& $Callback $type $size $mtime $relpath $remoteRoot
		}.GetNewClosure()
		Invoke-PaginatedRequest $inStream $outStream "RECURSE" $remoteRoot $PageSize $timeoutSec $inner
	}

	# Paginated single-level LIST - one directory's immediate children
	# only (name is already bare, no root/relpath to compute). Used by
	# plain `ls` (no -Recursive, no glob) and the glob "simple case" (a
	# pattern whose suffix can only ever match one level deep, where a
	# full RECURSE would walk an irrelevant subtree for nothing).
	# Invokes $Callback once per entry found, as:
	#   & $Callback <type> <size> <mtime> <name>
	function Invoke-PaginatedList([System.IO.Stream]$inStream, [System.IO.Stream]$outStream, [string]$dir, [int]$timeoutSec, [scriptblock]$Callback) {
		Invoke-PaginatedRequest $inStream $outStream "LIST" $dir $PageSize $timeoutSec $Callback
	}

	function Send-RemoteMkdir([System.IO.Stream]$inStream, [System.IO.Stream]$outStream, [string]$path, [int]$timeoutSec) {
		Write-Line $outStream "MKDIR $path"
		$resp = Read-LineTimeout $inStream $timeoutSec
		if ($null -eq $resp) { Write-Err "timed out (${timeoutSec}s) or lost connection waiting for a response"; exit 1 }
		if ($resp -eq "OK") { return }
		if ($resp.StartsWith("ERR ")) { Write-Err "server: $($resp.Substring(4)) (mkdir $path)"; exit 1 }
		Write-Err "unexpected response: $resp"
		exit 1
	}

	# Shared single-file GET - used directly by the `get` command and, via
	# Receive-DirectoryRecursive's callback, by `get -Recursive` too, so
	# resume behaves identically either way. See ../PROTOCOL.md's
	# "Partial-file safety".
	function Receive-File([System.IO.Stream]$inStream, [System.IO.Stream]$outStream, [string]$remote, [string]$localPath, [int]$timeoutSec, [int]$dataTimeoutSec) {
		$localDir = Split-Path -Parent $localPath
		if (-not [string]::IsNullOrEmpty($localDir)) { New-Item -ItemType Directory -Path $localDir -Force | Out-Null }
		$partial = Get-PartialPath $localPath

		$offset = $null
		if (Test-SafePartial $partial) {
			$sz = (Get-Item -LiteralPath $partial).Length
			if ($sz -gt 0) { $offset = $sz }
		}

		if ($offset) {
			$claimedHash = Get-PrefixHash $partial $offset
			Write-Line $outStream "GET $remote $offset $claimedHash"
		} else {
			Write-Line $outStream "GET $remote"
		}

		$resp = Read-LineTimeout $inStream $timeoutSec
		if ($null -eq $resp) { Write-Err "timed out (${timeoutSec}s) or lost connection waiting for a response"; exit 1 }

		if ($resp.StartsWith("OK ")) {
			$n = [int64]$resp.Substring(3)
			if ($offset) {
				$fs = [System.IO.File]::Open($partial, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write)
				try {
					[void]$fs.Seek(0, [System.IO.SeekOrigin]::End)
					if (-not (Copy-ExactBytesTimeout $inStream $fs $n $dataTimeoutSec)) {
						Write-Err "timed out (${dataTimeoutSec}s) or lost connection while receiving data - partial kept for a later resume"
						exit 1
					}
				} finally { $fs.Close() }
			} else {
				$fs = New-ExclusiveFile $partial
				if ($null -eq $fs) { Write-Err "staging path blocked: $partial already exists and isn't a plain file"; exit 1 }
				try {
					if (-not (Copy-ExactBytesTimeout $inStream $fs $n $dataTimeoutSec)) {
						Write-Err "timed out (${dataTimeoutSec}s) or lost connection while receiving data - partial kept for a later resume"
						exit 1
					}
				} finally { $fs.Close() }
			}
			Move-Item -LiteralPath $partial -Destination $localPath -Force
			if ($offset) {
				Write-Out "got $remote -> $localPath ($(Format-HumanSize ($offset + $n)), resumed from $(Format-HumanSize $offset))"
			} else {
				Write-Out "got $remote -> $localPath ($(Format-HumanSize $n))"
			}
		} elseif ($resp.StartsWith("ERR ")) {
			if ($offset) {
				Write-Err "resume rejected ($($resp.Substring(4))); discarding partial and retrying fresh"
				Remove-Item -LiteralPath $partial -Force
				Receive-File $inStream $outStream $remote $localPath $timeoutSec $dataTimeoutSec
				return
			}
			Write-Err "server: $($resp.Substring(4))"
			exit 1
		} else {
			Write-Err "unexpected response: $resp"
			exit 1
		}
	}

	# Shared single-file PUT - used directly by the `put` command and, via
	# Send-DirectoryRecursive's loop body, by `put -Recursive` too. PUT is
	# a 4-step handshake because, unlike GET, the side with the partial
	# (the responder) isn't the side that knows what to do about it (us) -
	# so it has to offer first.
	function Send-File([System.IO.Stream]$inStream, [System.IO.Stream]$outStream, [string]$localPath, [string]$remote, [int]$timeoutSec, [int]$dataTimeoutSec) {
		$size = (Get-Item -LiteralPath $localPath).Length
		Write-Line $outStream "PUT $remote $size"

		$resumeOffset = $null
		$resp = Read-LineTimeout $inStream $timeoutSec
		if ($null -eq $resp) { Write-Err "timed out (${timeoutSec}s) or lost connection waiting for a response"; exit 1 }

		if ($resp -eq "FRESH") {
			# nothing to do
		} elseif ($resp.StartsWith("RESUME ")) {
			$rparts = $resp.Substring(7).Split(" ", 2)
			$offerOffsetNum = 0L
			if ([int64]::TryParse($rparts[0], [ref]$offerOffsetNum) -and $offerOffsetNum -le $size) {
				$localHash = Get-PrefixHash $localPath $offerOffsetNum
				if ($localHash -eq $rparts[1]) { $resumeOffset = $offerOffsetNum }
			}
		} elseif ($resp.StartsWith("ERR ")) {
			Write-Err "server: $($resp.Substring(4))"
			exit 1
		} else {
			Write-Err "unexpected response: $resp"
			exit 1
		}

		if ($resumeOffset) {
			Write-Line $outStream "RESUME $resumeOffset"
		} else {
			Write-Line $outStream "RESTART"
			$resumeOffset = 0L
		}
		$remaining = $size - $resumeOffset

		if ($remaining -gt 0) {
			$fs = [System.IO.File]::OpenRead($localPath)
			try {
				[void]$fs.Seek($resumeOffset, [System.IO.SeekOrigin]::Begin)
				if (-not (Send-ExactBytesTimeout $fs $outStream $remaining $dataTimeoutSec)) {
					Write-Err "timed out (${dataTimeoutSec}s) or lost connection while sending data"
					exit 1
				}
			} finally { $fs.Close() }
		}

		$resp = Read-LineTimeout $inStream $timeoutSec
		if ($null -eq $resp) { Write-Err "timed out (${timeoutSec}s) or lost connection waiting for a response"; exit 1 }
		if ($resp -eq "OK") {
			if ($resumeOffset -gt 0) {
				Write-Out "put $localPath -> $remote ($(Format-HumanSize $size), resumed from $(Format-HumanSize $resumeOffset))"
			} else {
				Write-Out "put $localPath -> $remote ($(Format-HumanSize $size))"
			}
		} elseif ($resp.StartsWith("ERR ")) {
			Write-Err "server: $($resp.Substring(4))"
			exit 1
		} else {
			Write-Err "unexpected response: $resp"
			exit 1
		}
	}

	# Uploads $localRoot (a directory) to $remoteDest (already run through
	# Get-EffectiveDest), preserving the local tree structure. Every
	# directory - including empty ones - gets an explicit MKDIR; files go
	# through Send-File. Get-ChildItem -Recurse's default pre-order
	# traversal guarantees a directory's MKDIR always lands before its
	# children.
	function Send-DirectoryRecursive([System.IO.Stream]$inStream, [System.IO.Stream]$outStream, [string]$localRoot, [string]$remoteDest, [int]$timeoutSec, [int]$dataTimeoutSec) {
		Send-RemoteMkdir $inStream $outStream $remoteDest $timeoutSec
		$localRootFull = (Resolve-Path -LiteralPath $localRoot).Path
		Get-ChildItem -LiteralPath $localRoot -Recurse | ForEach-Object {
			$rel = ($_.FullName.Substring($localRootFull.Length).TrimStart('\', '/')) -replace '\\', '/'
			$remotePath = Join-RemotePath $remoteDest $rel
			if ($_.PSIsContainer) {
				Send-RemoteMkdir $inStream $outStream $remotePath $timeoutSec
			} else {
				Send-File $inStream $outStream $_.FullName $remotePath $timeoutSec $dataTimeoutSec
			}
		}
	}

	function Receive-DirectoryRecursive([System.IO.Stream]$inStream, [System.IO.Stream]$outStream, [string]$remoteRoot, [string]$localDest, [int]$timeoutSec, [int]$dataTimeoutSec) {
		New-Item -ItemType Directory -Path $localDest -Force | Out-Null
		$callback = {
			param($type, $size, $mtime, $relpath, $root)
			$fullRemote = Join-RemotePath $root $relpath
			$fullLocal = Join-Path $localDest ($relpath -replace '/', '\')
			if ($type -eq "D") {
				New-Item -ItemType Directory -Path $fullLocal -Force | Out-Null
			} else {
				Receive-File $inStream $outStream $fullRemote $fullLocal $timeoutSec $dataTimeoutSec
			}
		}.GetNewClosure()
		Invoke-RemoteWalk $inStream $outStream $remoteRoot $timeoutSec $callback
	}

	try {
		switch ($Command) {
			"ls" {
				$path = if ($Arg1) { $Arg1 } else { "" }
				if (Test-IsGlob $path) {
					$split = Split-GlobPattern $path
					$regex = ConvertTo-GlobRegex $split.Suffix
					if (Test-GlobIsComplex $split.Suffix) {
						$callback = {
							param($type, $size, $mtime, $relpath, $root)
							if ($relpath -notmatch $regex) { return }
							$full = Join-RemotePath $root $relpath
							if ($FullPath) { Write-PathOnlyLine $type $size $mtime $full } else { Write-ListingLine $type $size $mtime $full }
						}.GetNewClosure()
						Invoke-RemoteWalk $clientIn $clientOut $split.Prefix $Timeout $callback
					} else {
						$callback = {
							param($type, $size, $mtime, $name)
							if ($name -notmatch $regex) { return }
							$full = Join-RemotePath $split.Prefix $name
							if ($FullPath) { Write-PathOnlyLine $type $size $mtime $full } else { Write-ListingLine $type $size $mtime $full }
						}.GetNewClosure()
						Invoke-PaginatedList $clientIn $clientOut $split.Prefix $Timeout $callback
					}
				} elseif ($Recursive) {
					$pathClean = (Remove-GlobEscapes $path).TrimEnd('/')
					if ([string]::IsNullOrEmpty($pathClean)) { $pathClean = "." }
					$callback = {
						param($type, $size, $mtime, $relpath, $root)
						$full = Join-RemotePath $root $relpath
						if ($FullPath) { Write-PathOnlyLine $type $size $mtime $full } else { Write-ListingLine $type $size $mtime $full }
					}.GetNewClosure()
					Invoke-RemoteWalk $clientIn $clientOut $pathClean $Timeout $callback
				} else {
					$path = Remove-GlobEscapes $path
					$callback = {
						param($type, $size, $mtime, $name)
						if ($FullPath) {
							Write-PathOnlyLine $type $size $mtime (Join-RemotePath $path $name)
						} else {
							Write-ListingLine $type $size $mtime $name
						}
					}.GetNewClosure()
					Invoke-PaginatedList $clientIn $clientOut $path $Timeout $callback
				}
			}
			"get" {
				$remoteRaw = $Arg1
				$destRoot = $Arg2
				if ([string]::IsNullOrEmpty($remoteRaw)) { Write-Err "get requires a remote path"; exit 1 }
				if (Test-IsGlob $remoteRaw) {
					$split = Split-GlobPattern $remoteRaw
					$regex = ConvertTo-GlobRegex $split.Suffix
					$globDestRoot = if ($destRoot) { $destRoot } else { "." }
					if (Test-GlobIsComplex $split.Suffix) {
						$callback = {
							param($type, $size, $mtime, $relpath, $root)
							if ($relpath -notmatch $regex) { return }
							if ($type -ne "F") { return }
							$fullRemote = Join-RemotePath $root $relpath
							Receive-File $clientIn $clientOut $fullRemote (Join-Path $globDestRoot ($fullRemote -replace '/', '\')) $Timeout $DataTimeout
						}.GetNewClosure()
						Invoke-RemoteWalk $clientIn $clientOut $split.Prefix $Timeout $callback
					} else {
						$callback = {
							param($type, $size, $mtime, $name)
							if ($name -notmatch $regex) { return }
							if ($type -ne "F") { return }
							$fullRemote = Join-RemotePath $split.Prefix $name
							Receive-File $clientIn $clientOut $fullRemote (Join-Path $globDestRoot ($fullRemote -replace '/', '\')) $Timeout $DataTimeout
						}.GetNewClosure()
						Invoke-PaginatedList $clientIn $clientOut $split.Prefix $Timeout $callback
					}
				} elseif ($Recursive) {
					$remoteRaw = Remove-GlobEscapes $remoteRaw
					$localDest = Get-EffectiveDest $remoteRaw $destRoot
					$remoteClean = $remoteRaw.TrimEnd('/')
					if ([string]::IsNullOrEmpty($remoteClean)) { $remoteClean = "." }
					Receive-DirectoryRecursive $clientIn $clientOut $remoteClean $localDest $Timeout $DataTimeout
				} else {
					$remoteRaw = Remove-GlobEscapes $remoteRaw
					$localPath = if ($destRoot) { $destRoot } else { Split-Path -Leaf $remoteRaw }
					Receive-File $clientIn $clientOut $remoteRaw $localPath $Timeout $DataTimeout
				}
			}
			"put" {
				$localRaw = $Arg1
				$destRoot = $Arg2
				if ([string]::IsNullOrEmpty($localRaw)) { Write-Err "put requires a local path"; exit 1 }
				if (-not (Test-Path -LiteralPath $localRaw)) { Write-Err "no such file or directory: $localRaw"; exit 1 }
				if ($Recursive -and (Test-Path -LiteralPath $localRaw -PathType Container)) {
					$remoteDest = Get-EffectiveDest $localRaw $destRoot -RemoteOutput
					Send-DirectoryRecursive $clientIn $clientOut $localRaw $remoteDest $Timeout $DataTimeout
				} else {
					if (-not (Test-Path -LiteralPath $localRaw -PathType Leaf)) { Write-Err "not a regular file: $localRaw"; exit 1 }
					$remote = if ($destRoot) { $destRoot } else { Split-Path -Leaf $localRaw }
					Send-File $clientIn $clientOut $localRaw $remote $Timeout $DataTimeout
				}
			}
			"pwd" {
				Write-Line $clientOut "PWD"
				$resp = Read-LineTimeout $clientIn $Timeout
				if ($null -eq $resp) { Write-Err "timed out (${Timeout}s) or lost connection waiting for a response"; exit 1 }
				if ($resp.StartsWith("OK ")) {
					Write-Out $resp.Substring(3)
				} elseif ($resp.StartsWith("ERR ")) {
					Write-Err "server: $($resp.Substring(4))"
					exit 1
				} else {
					Write-Err "unexpected response: $resp"
					exit 1
				}
			}
			"mkdir" {
				# No -MkdirP flag: Do-Mkdir on the responder side already
				# creates the whole tree unconditionally (see its own
				# comment), so every mkdir here does too.
				$remotePath = $Arg1
				if ([string]::IsNullOrEmpty($remotePath)) { Write-Err "mkdir requires a remote path"; exit 1 }
				Send-RemoteMkdir $clientIn $clientOut $remotePath $Timeout
				Write-Out "mkdir $remotePath"
			}
			"stat" {
				$remotePath = if ($Arg1) { $Arg1 } else { "." }
				Write-Line $clientOut "STAT $remotePath"
				$resp = Read-LineTimeout $clientIn $Timeout
				if ($null -eq $resp) { Write-Err "timed out (${Timeout}s) or lost connection waiting for a response"; exit 1 }
				if ($resp.StartsWith("OK ")) {
					# OK <type> <size> <mtime> <atime> <birthtime> <file_count> <dir_count>
					$fields = $resp.Substring(3).Split(" ")
					$stType = $fields[0]; $stSize = [int64]$fields[1]; $stMtime = [int64]$fields[2]
					$stAtime = [int64]$fields[3]; $stBtime = [int64]$fields[4]
					$stFiles = $fields[5]; $stDirs = $fields[6]
					# "path:" shows the responder's real absolute filesystem
					# path, not just whatever (possibly relative, possibly
					# bare) argument the user typed - resolved via a second
					# request, PWD, same wire verb the `pwd` subcommand
					# already uses, joined with the now-known-valid remote
					# path. "." (or a path that trims down to it) means the
					# root itself, no "/." suffix.
					Write-Line $clientOut "PWD"
					$pwdResp = Read-LineTimeout $clientIn $Timeout
					$pwdRoot = if ($null -ne $pwdResp -and $pwdResp.StartsWith("OK ")) { $pwdResp.Substring(3) } else { "" }
					$remoteClean = $remotePath.TrimEnd('/')
					if ([string]::IsNullOrEmpty($pwdRoot)) {
						$absPath = $remotePath
					} elseif ([string]::IsNullOrEmpty($remoteClean) -or $remoteClean -eq ".") {
						$absPath = $pwdRoot
					} else {
						$absPath = "$pwdRoot/$remoteClean"
					}
					Write-Out "path:       $absPath"
					if ($stType -eq "D") {
						Write-Out "type:       directory"
					} else {
						Write-Out "type:       file"
						Write-Out "size:       $stSize ($(Format-HumanSize $stSize))"
					}
					Write-Out "mtime:      $(Format-HumanDate $stMtime)"
					Write-Out "atime:      $(Format-HumanDate $stAtime)"
					if ($stBtime -eq 0) {
						Write-Out "birthtime:  unknown"
					} else {
						Write-Out "birthtime:  $(Format-HumanDate $stBtime)"
					}
					if ($stType -eq "D") {
						Write-Out "files:      $stFiles"
						Write-Out "dirs:       $stDirs"
					}
				} elseif ($resp.StartsWith("ERR ")) {
					Write-Err "server: $($resp.Substring(4))"
					exit 1
				} else {
					Write-Err "unexpected response: $resp"
					exit 1
				}
			}
			default {
				Show-Usage
				exit 1
			}
		}
	} finally {
		Quit-Client
	}
	exit 0
}

# ============================================================================
# Worker mode: gs-netcat.exe's own -e just exec'd this same script fresh
# (GSTRANSFER_WORKER=1 inherited from the launcher's own process
# environment through gs-netcat.exe's child-process creation), with
# stdin/stdout now wired to the tunnel. Unchanged from before standalone
# launching existed - this part has no idea whether it got here via the
# launcher above or a manually-typed gs-netcat.exe -e invocation, and
# doesn't need to. ---
# ============================================================================

$stdin = [Console]::OpenStandardInput()
$stdout = [Console]::OpenStandardOutput()

# Mirrors the POSIX responder's is_safe_path exactly - see
# ../PROTOCOL.md's "Path rules". / is the only separator accepted on the
# wire even here; a literal \ anywhere is rejected outright rather than
# treated as a separator, so the wire format stays cross-platform
# identical.
function Test-SafePath([string]$p) {
	if ([string]::IsNullOrEmpty($p)) { return $false }
	if ($p.StartsWith("/")) { return $false }
	if ($p.Contains("\")) { return $false }
	if ($p.EndsWith("/")) { return $false }
	if ($p -match "^[A-Za-z]:") { return $false }  # drive-letter-rooted
	foreach ($seg in $p.Split("/")) {
		if ($seg -eq "" -or $seg -eq "..") { return $false }
	}
	return $true
}

# Reports the responder's own starting directory - what "." on the wire
# actually resolves to from the caller's side, since every path
# LIST/GET/PUT/MKDIR accepts is relative to it.
function Do-Pwd {
	Write-Line $stdout "OK $((Get-Location).Path)"
}

# Shared by Do-List/Do-Recurse: given $dir and an already
# [StringComparer]::Ordinal-sorted array of names relative to it (bare
# basenames for Do-List, full /-joined relpaths for Do-Recurse), streams
# "<type> <size> <mtime> <name>" per entry - honoring an optional
# <maxcount>/<cursor> page window - then a plain "END" or "MORE <cursor>"
# if more remain. Sort order must be stable across calls for cursor-
# skipping to mean anything, which is why both callers force Ordinal
# comparison rather than Sort-Object's culture-aware default.
#
# Cursor matching is exact-equality, never an ordering comparison (a
# culture-aware -lt/-gt could disagree with the Ordinal sort that
# produced this list) - skip everything through the entry equal to
# <cursor>, resume right after. Known, accepted edge case: if the tree
# changed between pages and <cursor>'s exact value no longer exists, the
# rest of this page is skipped entirely rather than guessing a nearby
# resume point.
function Send-PaginatedListing([string]$dir, [Nullable[int]]$maxcount, [string]$cursor, [string[]]$names) {
	$skipping = -not [string]::IsNullOrEmpty($cursor)
	$count = 0
	$last = $null
	for ($i = 0; $i -lt $names.Length; $i++) {
		$name = $names[$i]
		if ($skipping) {
			if ($name -eq $cursor) { $skipping = $false }
			continue
		}
		$full = if ($dir -eq ".") { $name } else { Join-Path $dir $name }
		$item = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
		if ($null -eq $item) { continue }
		$mtime = [DateTimeOffset]::new($item.LastWriteTimeUtc, [TimeSpan]::Zero).ToUnixTimeSeconds()
		if ($item.PSIsContainer) {
			Write-Line $stdout "D 0 $mtime $name"
		} else {
			Write-Line $stdout "F $($item.Length) $mtime $name"
		}
		$last = $name
		$count++
		if ($maxcount -and $count -ge $maxcount) {
			# Peek for anything left; each page re-walks from scratch so
			# discarding this one peeked entry costs nothing - it's simply
			# re-produced (and re-skipped-past-cursor) next page.
			if ($i + 1 -lt $names.Length) {
				Write-Line $stdout "MORE $last"
				return
			}
			break
		}
	}
	Write-Line $stdout "END"
}

# A trailing "/" is meaningful here (unlike every other verb, which
# just trims it) - it's what disambiguates "list this directory's own
# entry" from "list its contents", the same distinction real shells
# make (`ls junk` vs `ls junk/`). "." (root) has no parent to show it
# relative to, so it always means contents, slash or not.
function Do-List([string]$dir, [Nullable[int]]$maxcount, [string]$cursor) {
	if ([string]::IsNullOrEmpty($dir)) { $dir = "." }
	$wantContents = ($dir -eq ".")
	if ($dir.EndsWith("/") -and $dir -ne ".") {
		$dir = $dir.TrimEnd('/')
		$wantContents = $true
	}
	if ($dir -ne ".") {
		if (-not (Test-SafePath $dir)) { Write-Line $stdout "ERR invalid path"; return }
		if (Test-Path -LiteralPath $dir -PathType Leaf) {
			if ($wantContents) {
				# Trailing "/" on a path that's actually a file - mirrors
				# real `ls file.txt/` rather than silently falling back
				# to a single-file listing.
				Write-Line $stdout "ERR not a directory"
				return
			}
			# A single file, not a directory - matches real `ls <file>`:
			# list just that one entry instead of erroring. Re-split into
			# parent/leaf so Send-PaginatedListing's own Join-Path-based
			# lookup resolves it exactly like any other entry.
			$parent = Split-Path -Path $dir -Parent
			if ([string]::IsNullOrEmpty($parent)) { $parent = "." }
			Send-PaginatedListing $parent $maxcount $cursor @((Split-Path -Path $dir -Leaf))
			return
		}
		if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Write-Line $stdout "ERR not found"; return }
		if (-not $wantContents) {
			# Bare directory name, no trailing "/": list just this one
			# entry (the directory itself), same as the single-file case
			# above - a trailing "/" is what asks for contents instead.
			$parent = Split-Path -Path $dir -Parent
			if ([string]::IsNullOrEmpty($parent)) { $parent = "." }
			Send-PaginatedListing $parent $maxcount $cursor @((Split-Path -Path $dir -Leaf))
			return
		}
	}
	# Dot-prefixed names are excluded - Windows has no equivalent "hidden
	# by naming convention" rule the way a bare shell glob does on POSIX
	# (a leading dot alone doesn't set the Hidden attribute here), so
	# without this, this responder's own .<name>.partial staging files
	# would leak into listings on Windows but not POSIX.
	$names = @(Get-ChildItem -LiteralPath $dir | Where-Object { $_.Name -notmatch '(^|/)\.' } | ForEach-Object { $_.Name })
	[Array]::Sort($names, [StringComparer]::Ordinal)
	Send-PaginatedListing $dir $maxcount $cursor $names
}

# Recursive counterpart of Do-List - walks the whole subtree natively
# (Get-ChildItem -Recurse doesn't follow reparse points/symlinks into a
# directory by default, same as the single-level Do-List above never has
# to think about it either) instead of the client doing a BFS via
# repeated LIST calls. Same dot-prefix exclusion as Do-List, applied to
# every path segment, not just the leaf name - see its own comment.
function Do-Recurse([string]$dir, [Nullable[int]]$maxcount, [string]$cursor) {
	if ([string]::IsNullOrEmpty($dir)) { $dir = "." }
	if ($dir -ne ".") { $dir = $dir.TrimEnd('/') }
	if ($dir -ne ".") {
		if (-not (Test-SafePath $dir)) { Write-Line $stdout "ERR invalid path"; return }
		if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Write-Line $stdout "ERR not found"; return }
	}
	$rootFull = (Resolve-Path -LiteralPath $dir).Path
	$names = @(Get-ChildItem -LiteralPath $dir -Recurse | ForEach-Object {
		($_.FullName.Substring($rootFull.Length).TrimStart('\', '/')) -replace '\\', '/'
	} | Where-Object { $_ -notmatch '(^|/)\.' })
	[Array]::Sort($names, [StringComparer]::Ordinal)
	Send-PaginatedListing $dir $maxcount $cursor $names
}

# Cheap single-path metadata - every field exists to let the client make
# some specific decision without an extra round trip (see
# docs/gs-transfer-backend-plan.md for the full per-field reasoning, not
# just "it was available"): <type> decides GET vs RECURSE/LIST next;
# <size> decides whether to even attempt a transfer; <mtime> enables
# sync-style skip-if-unchanged logic; <atime> is included but known-
# unreliable on both platforms (Windows disables last-access tracking by
# default since Vista, Linux commonly mounts noatime/relatime) - don't
# trust it for anything load-bearing; <birthtime> is cleanly available
# via .CreationTimeUtc (NTFS always tracks it); <file_count>/<dir_count>
# (immediate children only, directories only - 0/0 for a file) size
# whether a client should bother paginating a later LIST/RECURSE at all.
function Do-Stat([string]$path) {
	$path = $path.TrimEnd('/')
	if (-not (Test-SafePath $path)) { Write-Line $stdout "ERR invalid path"; return }
	$item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
	if ($null -eq $item) { Write-Line $stdout "ERR not found"; return }
	$mtime = [DateTimeOffset]::new($item.LastWriteTimeUtc, [TimeSpan]::Zero).ToUnixTimeSeconds()
	$atime = [DateTimeOffset]::new($item.LastAccessTimeUtc, [TimeSpan]::Zero).ToUnixTimeSeconds()
	$btime = [DateTimeOffset]::new($item.CreationTimeUtc, [TimeSpan]::Zero).ToUnixTimeSeconds()
	if ($item.PSIsContainer) {
		$children = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '(^|/)\.' })
		$fileCount = @($children | Where-Object { -not $_.PSIsContainer }).Count
		$dirCount = @($children | Where-Object { $_.PSIsContainer }).Count
		Write-Line $stdout "OK D 0 $mtime $atime $btime $fileCount $dirCount"
	} else {
		Write-Line $stdout "OK F $($item.Length) $mtime $atime $btime 0 0"
	}
}

# Deliberately separate from Do-Stat, not an optional extra on it -
# reading a whole file to hash it costs O(file size), the opposite of
# Do-Stat's cheap-lookup nature. Reuses Get-PrefixHash completely
# unchanged: hashing the whole file is just n = the full size instead of
# a resume offset, not new crypto code.
function Do-Hash([string]$path) {
	$path = $path.TrimEnd('/')
	if (-not (Test-SafePath $path)) { Write-Line $stdout "ERR invalid path"; return }
	if (Test-Path -LiteralPath $path -PathType Container) { Write-Line $stdout "ERR is a directory"; return }
	if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Write-Line $stdout "ERR not found"; return }
	$hash = Get-PrefixHash $path (Get-Item -LiteralPath $path).Length
	Write-Line $stdout "OK $hash"
}

function Do-Get([string]$path, [string]$offsetStr, [string]$claimedHash) {
	$path = $path.TrimEnd('/')
	if (-not (Test-SafePath $path)) { Write-Line $stdout "ERR invalid path"; return }
	if (Test-Path -LiteralPath $path -PathType Container) { Write-Line $stdout "ERR is a directory - use recursive get (-r) instead"; return }
	if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Write-Line $stdout "ERR not found"; return }
	$size = (Get-Item -LiteralPath $path).Length

	if ([string]::IsNullOrEmpty($offsetStr)) {
		Write-Line $stdout "OK $size"
		$fs = [System.IO.File]::OpenRead($path)
		try { Copy-ExactBytes $fs $stdout $size } finally { $fs.Close() }
		return
	}

	# Resume request: offsetStr/claimedHash describe the bytes the
	# client already has. Only the overlap gets hashed here, never the
	# whole file - see ../PROTOCOL.md's "Partial-file safety".
	$offset = 0L
	if (-not [int64]::TryParse($offsetStr, [ref]$offset) -or $offset -lt 0 -or $offset -gt $size) {
		Write-Line $stdout "ERR invalid offset"
		return
	}
	$actualHash = Get-PrefixHash $path $offset
	if ($actualHash -ne $claimedHash) {
		Write-Line $stdout "ERR resume mismatch"
		return
	}
	$remaining = $size - $offset
	Write-Line $stdout "OK $remaining"
	if ($remaining -gt 0) {
		$fs = [System.IO.File]::OpenRead($path)
		try {
			[void]$fs.Seek($offset, [System.IO.SeekOrigin]::Begin)
			Copy-ExactBytes $fs $stdout $remaining
		} finally { $fs.Close() }
	}
}

function Do-Mkdir([string]$path) {
	$path = $path.TrimEnd('/')
	if (-not (Test-SafePath $path)) { Write-Line $stdout "ERR invalid path"; return }
	try {
		New-Item -ItemType Directory -Path $path -Force | Out-Null
		Write-Line $stdout "OK"
	} catch {
		Write-Line $stdout "ERR mkdir failed"
	}
}

# PUT is a 4-step handshake, not a single fire-and-forget request -
# see ../PROTOCOL.md's "Wire format". Unlike GET, the client can't
# unilaterally decide whether to resume: the partial lives on *this*
# side, so this side has to offer its state first, before any bytes
# flow, which is also why path validation can fail here with no
# draining needed at all (nothing's been sent yet):
#   1. client:  PUT <path> <size>
#   2. us:      FRESH | RESUME <offset> <hash> | ERR <reason>
#   3. client:  RESTART | RESUME <offset>
#   4. client streams <size> bytes (RESTART) or <size-offset> bytes
#      (RESUME); us: OK | ERR <reason>
function Do-Put([string]$path, [int64]$size) {
	if (-not (Test-SafePath $path)) {
		Write-Line $stdout "ERR invalid path"
		return
	}

	$partial = Get-PartialPath $path
	$offerOffset = 0L
	if (Test-SafePartial $partial) {
		$offerOffset = (Get-Item -LiteralPath $partial).Length
	}
	if ($offerOffset -gt 0 -and $offerOffset -le $size) {
		$offerHash = Get-PrefixHash $partial $offerOffset
		Write-Line $stdout "RESUME $offerOffset $offerHash"
	} else {
		$offerOffset = 0L
		Write-Line $stdout "FRESH"
	}

	$decision = Read-Line $stdin
	if ($null -eq $decision) { return }

	$decParts = $decision.Split(" ", 2)
	$decVerb = $decParts[0]
	$decOffset = 0L
	if ($decVerb -eq "RESTART") {
		$decOffset = 0L
	} elseif ($decVerb -eq "RESUME" -and $decParts.Length -gt 1 -and
			[int64]::TryParse($decParts[1], [ref]$decOffset) -and $decOffset -ge 0 -and $decOffset -le $size) {
		# parsed into $decOffset above
	} else {
		Write-Line $stdout "ERR unexpected reply"
		return
	}
	$remaining = $size - $decOffset

	if ($decVerb -eq "RESUME" -and $decOffset -gt 0 -and $decOffset -eq $offerOffset -and (Test-SafePartial $partial)) {
		$fs = [System.IO.File]::Open($partial, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write)
		try {
			[void]$fs.Seek(0, [System.IO.SeekOrigin]::End)
			if ($remaining -gt 0) { Copy-ExactBytes $stdin $fs $remaining }
		} finally { $fs.Close() }
	} elseif ($decVerb -eq "RESUME") {
		# Client echoed an offset we never offered (stale/confused) -
		# drain to stay in sync, but don't write anything anywhere: the
		# incoming bytes are only the *tail* past some offset, never
		# safe to treat as if they were the whole file.
		if ($remaining -gt 0) { [void](Read-ExactBytes $stdin $remaining) }
		Write-Line $stdout "ERR offset mismatch"
		return
	} else {
		if (-not (Reset-Partial $partial)) {
			if ($remaining -gt 0) { [void](Read-ExactBytes $stdin $remaining) }
			Write-Line $stdout "ERR staging blocked"
			return
		}
		$fs = New-ExclusiveFile $partial
		if ($null -eq $fs) {
			if ($remaining -gt 0) { [void](Read-ExactBytes $stdin $remaining) }
			Write-Line $stdout "ERR staging blocked"
			return
		}
		try {
			if ($remaining -gt 0) { Copy-ExactBytes $stdin $fs $remaining }
		} finally { $fs.Close() }
	}

	$dir = Split-Path -Parent $path
	if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
		New-Item -ItemType Directory -Path $dir -Force | Out-Null
	}
	Move-Item -LiteralPath $partial -Destination $path -Force
	Write-Line $stdout "OK"
}

while ($true) {
	$line = Read-Line $stdin
	if ($null -eq $line) { break }  # EOF
	$parts = $line.Split(" ", 2)
	$cmd = $parts[0]
	switch ($cmd) {
		"PWD"  { Do-Pwd }
		"LIST" {
			# [<path>] [<maxcount> [<cursor>]] - same trailing-field-
			# peeling idiom as GET/PUT below; <cursor> is free-form (may
			# itself contain spaces/slashes), so it's only ever
			# "whatever's left after peeling a leading <maxcount>
			# token", never split further itself.
			$rest = if ($parts.Length -gt 1) { $parts[1] } else { "" }
			if ($rest -match '^(.*) (\d+) (.+)$') {
				Do-List $matches[1] ([int]$matches[2]) $matches[3]
			} elseif ($rest -match '^(.*) (\d+)$') {
				Do-List $matches[1] ([int]$matches[2]) $null
			} else {
				Do-List $rest $null $null
			}
		}
		"RECURSE" {
			# <path> [<maxcount> [<cursor>]] - identical parsing shape to
			# LIST above, see its own comment.
			$rest = if ($parts.Length -gt 1) { $parts[1] } else { "" }
			if ($rest -match '^(.*) (\d+) (.+)$') {
				Do-Recurse $matches[1] ([int]$matches[2]) $matches[3]
			} elseif ($rest -match '^(.*) (\d+)$') {
				Do-Recurse $matches[1] ([int]$matches[2]) $null
			} else {
				Do-Recurse $rest $null $null
			}
		}
		"STAT" { Do-Stat $(if ($parts.Length -gt 1) { $parts[1] } else { "" }) }
		"HASH" { Do-Hash $(if ($parts.Length -gt 1) { $parts[1] } else { "" }) }
		"GET"  {
			# <path> [<offset> <hash>] - path may itself contain spaces
			# (already supported elsewhere, e.g. Do-List's entries), so
			# this can only ever split off a trailing "<digits>
			# <64-hex-chars>" pair, never blindly split the whole line
			# on whitespace.
			$rest = if ($parts.Length -gt 1) { $parts[1] } else { "" }
			if ($rest -match '^(.*) (\d+) ([0-9a-f]{64})$') {
				Do-Get $matches[1] $matches[2] $matches[3]
			} else {
				Do-Get $rest "" ""
			}
		}
		"MKDIR" { Do-Mkdir $parts[1] }
		"PUT"  {
			$rest = $parts[1]
			if ($rest -match '^(.*) (\d+)$') {
				Do-Put $matches[1] ([int64]$matches[2])
			} else {
				Write-Line $stdout "ERR invalid path"
			}
		}
		"QUIT" { exit 0 }
		default {
			# Every request must get a response, even a bad one - see the
			# matching comment in gs-transfer.sh for why (an unanswered
			# request leaves the client's read blocked forever).
			Write-Line $stdout "ERR unknown command"
		}
	}
}
