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
#   gs-transfer.ps1 [-Secret <secret>] [-SecretFile <file>] [-Tor] [-Timeout <seconds>] [-Recursive] ls [path]
#   gs-transfer.ps1 [-Secret <secret>] [-SecretFile <file>] [-Tor] [-Timeout <seconds>] [-Recursive] get <remote-path> [local-path]
#   gs-transfer.ps1 [-Secret <secret>] [-SecretFile <file>] [-Tor] [-Timeout <seconds>] [-Recursive] put <local-path> [remote-path]
#   gs-transfer.ps1 [-Secret <secret>] [-SecretFile <file>] [-Tor] [-Timeout <seconds>] pwd
#   gs-transfer.ps1 [-Secret <secret>] [-SecretFile <file>] [-Tor] [-Timeout <seconds>] mkdir <remote-path>
#       Client mode (default, no -Listen). pwd reports the responder's
#       own starting directory - what "." means on the wire. mkdir
#       always creates the whole tree (mkdir -p semantics) - Do-Mkdir on
#       the responder side already works that way unconditionally (see
#       its own comment), so there's no flag needed to ask for it.
#
# Every parameter also has a single-letter alias matching the POSIX
# script's getopts flag (-l/-s/-k/-T/-r), so the two are driven
# identically where PowerShell's own parameter-binding allows it. -Timeout
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
	[Parameter(Position = 0)][string]$Command,
	[Parameter(Position = 1)][string]$Arg1,
	[Parameter(Position = 2)][string]$Arg2,
	[Alias("h", "?")][switch]$Help
)

# Single source of truth for usage text - mirrors ../posix/gs-transfer.sh's
# own usage() (same two lines, same content, just PowerShell's parameter
# names in place of getopts flags) - called whenever the command verb is
# missing or unrecognized, and for an explicit -Help, instead of each call
# site keeping its own (previously out-of-sync) copy.
function Show-Usage {
	Write-Error "Usage: $PSCommandPath -Listen [-Secret <secret>|-SecretFile <file>] [-Tor]"
	Write-Error "       $PSCommandPath [-Secret <secret>|-SecretFile <file>] [-Tor] [-Timeout <sec>] [-Recursive] ls [path] | get <remote-path> [local-path] | put <local-path> [remote-path] | pwd | mkdir <remote-path>"
}

$DataTimeout = 300

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
				Write-Error "gs-netcat.exe not found. Check PATH=?"
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

		$env:GSTRANSFER_WORKER = "1"
		& $netcatExe @gsncArgs
		exit $LASTEXITCODE
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
			Write-Error "gs-netcat.exe not found. Check PATH=?"
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
			Write-Host ("{0,-10}  {1,-16}  {2}/" -f "-", $dateStr, "$name")
		} else {
			Write-Host ("{0,-10}  {1,-16}  {2}" -f (Format-HumanSize $size), $dateStr, "$name")
		}
	}

	# Recursively walks $remoteRoot (a directory on the responder) via
	# repeated LIST calls - the wire protocol has no recursion of its own.
	# Invokes $Callback once per entry found, as:
	#   & $Callback <type> <size> <mtime> <relpath> <remoteRoot>
	# where <relpath> is always relative to $remoteRoot and always /-
	# separated. Fully drains each LIST's response (through END) before
	# invoking any callback - the wire protocol is strictly
	# request/response, and a callback that issues its own request (GET)
	# must never collide with a still-in-flight LIST response.
	function Invoke-RemoteWalk([System.IO.Stream]$inStream, [System.IO.Stream]$outStream, [string]$remoteRoot, [int]$timeoutSec, [scriptblock]$Callback) {
		$dirs = New-Object System.Collections.Generic.Queue[string]
		$dirs.Enqueue("")
		while ($dirs.Count -gt 0) {
			$rel = $dirs.Dequeue()
			if ([string]::IsNullOrEmpty($rel)) { $full = $remoteRoot } else { $full = Join-RemotePath $remoteRoot $rel }
			Write-Line $outStream "LIST $full"
			$entries = @()
			while ($true) {
				$line = Read-LineTimeout $inStream $timeoutSec
				if ($null -eq $line) { Write-Error "timed out (${timeoutSec}s) or lost connection waiting for a response"; exit 1 }
				if ($line -eq "END") { break }
				if ($line.StartsWith("ERR ")) { Write-Error "server: $($line.Substring(4)) ($full)"; exit 1 }
				$parts = $line.Split(" ", 4)
				$relpath = if ([string]::IsNullOrEmpty($rel)) { $parts[3] } else { "$rel/$($parts[3])" }
				$entries += [PSCustomObject]@{ Type = $parts[0]; Size = [int64]$parts[1]; Mtime = [int64]$parts[2]; RelPath = $relpath }
			}
			foreach ($e in $entries) {
				& $Callback $e.Type $e.Size $e.Mtime $e.RelPath $remoteRoot
				if ($e.Type -eq "D") { $dirs.Enqueue($e.RelPath) }
			}
		}
	}

	function Send-RemoteMkdir([System.IO.Stream]$inStream, [System.IO.Stream]$outStream, [string]$path, [int]$timeoutSec) {
		Write-Line $outStream "MKDIR $path"
		$resp = Read-LineTimeout $inStream $timeoutSec
		if ($null -eq $resp) { Write-Error "timed out (${timeoutSec}s) or lost connection waiting for a response"; exit 1 }
		if ($resp -eq "OK") { return }
		if ($resp.StartsWith("ERR ")) { Write-Error "server: $($resp.Substring(4)) (mkdir $path)"; exit 1 }
		Write-Error "unexpected response: $resp"
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
		if ($null -eq $resp) { Write-Error "timed out (${timeoutSec}s) or lost connection waiting for a response"; exit 1 }

		if ($resp.StartsWith("OK ")) {
			$n = [int64]$resp.Substring(3)
			if ($offset) {
				$fs = [System.IO.File]::Open($partial, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write)
				try {
					[void]$fs.Seek(0, [System.IO.SeekOrigin]::End)
					if (-not (Copy-ExactBytesTimeout $inStream $fs $n $dataTimeoutSec)) {
						Write-Error "timed out (${dataTimeoutSec}s) or lost connection while receiving data - partial kept for a later resume"
						exit 1
					}
				} finally { $fs.Close() }
			} else {
				$fs = New-ExclusiveFile $partial
				if ($null -eq $fs) { Write-Error "staging path blocked: $partial already exists and isn't a plain file"; exit 1 }
				try {
					if (-not (Copy-ExactBytesTimeout $inStream $fs $n $dataTimeoutSec)) {
						Write-Error "timed out (${dataTimeoutSec}s) or lost connection while receiving data - partial kept for a later resume"
						exit 1
					}
				} finally { $fs.Close() }
			}
			Move-Item -LiteralPath $partial -Destination $localPath -Force
			if ($offset) {
				Write-Host "got $remote -> $localPath ($(Format-HumanSize ($offset + $n)), resumed from $(Format-HumanSize $offset))"
			} else {
				Write-Host "got $remote -> $localPath ($(Format-HumanSize $n))"
			}
		} elseif ($resp.StartsWith("ERR ")) {
			if ($offset) {
				Write-Warning "resume rejected ($($resp.Substring(4))); discarding partial and retrying fresh"
				Remove-Item -LiteralPath $partial -Force
				Receive-File $inStream $outStream $remote $localPath $timeoutSec $dataTimeoutSec
				return
			}
			Write-Error "server: $($resp.Substring(4))"
			exit 1
		} else {
			Write-Error "unexpected response: $resp"
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
		if ($null -eq $resp) { Write-Error "timed out (${timeoutSec}s) or lost connection waiting for a response"; exit 1 }

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
			Write-Error "server: $($resp.Substring(4))"
			exit 1
		} else {
			Write-Error "unexpected response: $resp"
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
					Write-Error "timed out (${dataTimeoutSec}s) or lost connection while sending data"
					exit 1
				}
			} finally { $fs.Close() }
		}

		$resp = Read-LineTimeout $inStream $timeoutSec
		if ($null -eq $resp) { Write-Error "timed out (${timeoutSec}s) or lost connection waiting for a response"; exit 1 }
		if ($resp -eq "OK") {
			if ($resumeOffset -gt 0) {
				Write-Host "put $localPath -> $remote ($(Format-HumanSize $size), resumed from $(Format-HumanSize $resumeOffset))"
			} else {
				Write-Host "put $localPath -> $remote ($(Format-HumanSize $size))"
			}
		} elseif ($resp.StartsWith("ERR ")) {
			Write-Error "server: $($resp.Substring(4))"
			exit 1
		} else {
			Write-Error "unexpected response: $resp"
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
				if ($Recursive) {
					$pathClean = $path.TrimEnd('/')
					if ([string]::IsNullOrEmpty($pathClean)) { $pathClean = "." }
					$callback = {
						param($type, $size, $mtime, $relpath, $root)
						Write-ListingLine $type $size $mtime (Join-RemotePath $root $relpath)
					}.GetNewClosure()
					Invoke-RemoteWalk $clientIn $clientOut $pathClean $Timeout $callback
				} else {
					Write-Line $clientOut "LIST $path"
					while ($true) {
						$line = Read-LineTimeout $clientIn $Timeout
						if ($null -eq $line) { Write-Error "timed out (${Timeout}s) or lost connection waiting for a response"; exit 1 }
						if ($line -eq "END") { break }
						if ($line.StartsWith("ERR ")) { Write-Error "server: $($line.Substring(4))"; exit 1 }
						$parts = $line.Split(" ", 4)
						Write-ListingLine $parts[0] ([int64]$parts[1]) ([int64]$parts[2]) $parts[3]
					}
				}
			}
			"get" {
				$remoteRaw = $Arg1
				$destRoot = $Arg2
				if ([string]::IsNullOrEmpty($remoteRaw)) { Write-Error "get requires a remote path"; exit 1 }
				if ($Recursive) {
					$localDest = Get-EffectiveDest $remoteRaw $destRoot
					$remoteClean = $remoteRaw.TrimEnd('/')
					if ([string]::IsNullOrEmpty($remoteClean)) { $remoteClean = "." }
					Receive-DirectoryRecursive $clientIn $clientOut $remoteClean $localDest $Timeout $DataTimeout
				} else {
					$localPath = if ($destRoot) { $destRoot } else { Split-Path -Leaf $remoteRaw }
					Receive-File $clientIn $clientOut $remoteRaw $localPath $Timeout $DataTimeout
				}
			}
			"put" {
				$localRaw = $Arg1
				$destRoot = $Arg2
				if ([string]::IsNullOrEmpty($localRaw)) { Write-Error "put requires a local path"; exit 1 }
				if (-not (Test-Path -LiteralPath $localRaw)) { Write-Error "no such file or directory: $localRaw"; exit 1 }
				if ($Recursive -and (Test-Path -LiteralPath $localRaw -PathType Container)) {
					$remoteDest = Get-EffectiveDest $localRaw $destRoot -RemoteOutput
					Send-DirectoryRecursive $clientIn $clientOut $localRaw $remoteDest $Timeout $DataTimeout
				} else {
					if (-not (Test-Path -LiteralPath $localRaw -PathType Leaf)) { Write-Error "not a regular file: $localRaw"; exit 1 }
					$remote = if ($destRoot) { $destRoot } else { Split-Path -Leaf $localRaw }
					Send-File $clientIn $clientOut $localRaw $remote $Timeout $DataTimeout
				}
			}
			"pwd" {
				Write-Line $clientOut "PWD"
				$resp = Read-LineTimeout $clientIn $Timeout
				if ($null -eq $resp) { Write-Error "timed out (${Timeout}s) or lost connection waiting for a response"; exit 1 }
				if ($resp.StartsWith("OK ")) {
					Write-Host $resp.Substring(3)
				} elseif ($resp.StartsWith("ERR ")) {
					Write-Error "server: $($resp.Substring(4))"
					exit 1
				} else {
					Write-Error "unexpected response: $resp"
					exit 1
				}
			}
			"mkdir" {
				# No -MkdirP flag: Do-Mkdir on the responder side already
				# creates the whole tree unconditionally (see its own
				# comment), so every mkdir here does too.
				$remotePath = $Arg1
				if ([string]::IsNullOrEmpty($remotePath)) { Write-Error "mkdir requires a remote path"; exit 1 }
				Send-RemoteMkdir $clientIn $clientOut $remotePath $Timeout
				Write-Host "mkdir $remotePath"
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

function Do-List([string]$dir) {
	if ([string]::IsNullOrEmpty($dir)) { $dir = "." }
	if ($dir -ne ".") {
		if (-not (Test-SafePath $dir)) { Write-Line $stdout "ERR invalid path"; return }
		if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Write-Line $stdout "ERR not found"; return }
	}
	Get-ChildItem -LiteralPath $dir | ForEach-Object {
		$mtime = [DateTimeOffset]::new($_.LastWriteTimeUtc, [TimeSpan]::Zero).ToUnixTimeSeconds()
		if ($_.PSIsContainer) {
			Write-Line $stdout "D 0 $mtime $($_.Name)"
		} else {
			Write-Line $stdout "F $($_.Length) $mtime $($_.Name)"
		}
	}
	Write-Line $stdout "END"
}

function Do-Get([string]$path, [string]$offsetStr, [string]$claimedHash) {
	if (-not (Test-SafePath $path)) { Write-Line $stdout "ERR invalid path"; return }
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
		"LIST" { Do-List $(if ($parts.Length -gt 1) { $parts[1] } else { "" }) }
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
