# gs-transfer responder (Windows) - see ../PROTOCOL.md for the wire format.
#
# Two ways to run this:
#
#   1. Standalone (recommended): gs-transfer-server.ps1 [-Secret <secret>] [-SecretFile <file>] [-Tor]
#      This process launches gs-netcat.exe itself (-l, plus whatever
#      secret/proxy flags were given) with -e pointing back at this
#      same script - no gs-netcat.exe command line to construct by hand.
#   2. Manually, exactly as before:
#        gs-netcat.exe -s <secret> -l -e "powershell.exe -NoProfile -ExecutionPolicy Bypass -File gs-transfer-server.ps1"
#      Still fully supported - see the worker-detection check below.
#
# Either way, once gs-netcat.exe's -e actually execs this script, its
# stdin/stdout are the tunnel; the raw Streams are used throughout from
# that point on (never Console.In/Out or Write-Host) so binary payloads
# can't be corrupted by any TextReader's own buffering/newline
# translation - the same reason the POSIX server uses `head -c` instead
# of `read` for payload bytes.
param(
	[string]$Secret,
	[string]$SecretFile,
	[switch]$Tor
)

# Worker if EITHER signal says so - see gs-transfer-server.sh's own
# matching comment for the full rationale (short version: the old,
# pre-standalone-launching manual invocation style above must keep
# working unchanged, and it never sets $env:GSTRANSFER_WORKER - gs-
# netcat.exe's -e passes no arguments of its own either - so that
# marker alone can't tell "exec'd by gs-netcat's own -e" apart from
# "launched fresh by a human". stdin's own nature is the fallback
# signal. .NET's Console.IsInputRedirected was tried first and
# rejected: it's true for a /dev/null-redirected background launch
# too (this script's own nohup-style test harness included), which
# would misread that as a worker. The raw Win32 GetFileType is more
# precise - verified directly: it reports FILE_TYPE_PIPE (3) for both
# gs-netcat's own -e wiring (CreatePipe, confirmed against this
# project's own win_childproc.c) and a real `|`-fed pipe, but
# FILE_TYPE_CHAR (2) for both an interactive console and a /dev/null
# redirect - exactly the bash -p test's own precision, not a weaker
# .NET approximation of it.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class GSTransferWin32 {
	[DllImport("kernel32.dll", SetLastError = true)]
	public static extern uint GetFileType(IntPtr hFile);
	[DllImport("kernel32.dll", SetLastError = true)]
	public static extern IntPtr GetStdHandle(int nStdHandle);
}
"@
$FILE_TYPE_PIPE = 3
$STD_INPUT_HANDLE = -10
$stdinIsPipe = ([GSTransferWin32]::GetFileType([GSTransferWin32]::GetStdHandle($STD_INPUT_HANDLE)) -eq $FILE_TYPE_PIPE)

if (($env:GSTRANSFER_WORKER -ne "1") -and (-not $stdinIsPipe)) {
	# --- Outer/launcher mode: parse args, launch gs-netcat.exe, which
	# will later exec a fresh copy of this same script (in worker mode,
	# via -e) for each connection it accepts. ---
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

	# -Secret/-SecretFile/-Tor map straight onto gs-netcat's own -s/-k/-T
	# flags, passed through unchanged - see gs-transfer-client.sh's
	# header comment for the same rationale (no new secret-handling or
	# proxy mechanism here).
	$gsncArgs = @("-l")
	if ($Secret) { $gsncArgs += @("-s", $Secret) }
	if ($SecretFile) { $gsncArgs += @("-k", $SecretFile) }
	if ($Tor) { $gsncArgs += "-T" }

	# -e's value is passed verbatim as the raw CreateProcess command
	# line - no extra shell layer (confirmed directly against this
	# project's own win_childproc.c) - so it has to already be a
	# correctly-quoted Win32 command line, not just a bare path.
	$innerCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
	$gsncArgs += @("-e", $innerCmd)

	$env:GSTRANSFER_WORKER = "1"
	& $netcatExe @gsncArgs
	exit $LASTEXITCODE
}

# --- Worker mode: gs-netcat.exe's own -e just exec'd this same script
# fresh (GSTRANSFER_WORKER=1 inherited from the launcher's own process
# environment through gs-netcat.exe's child-process creation), with
# stdin/stdout now wired to the tunnel. Unchanged from before
# standalone launching existed - this part has no idea whether it got
# here via the launcher above or a manually-typed gs-netcat.exe -e
# invocation, and doesn't need to. ---

$stdin = [Console]::OpenStandardInput()
$stdout = [Console]::OpenStandardOutput()

function Write-Line([string]$text) {
	$bytes = [System.Text.Encoding]::ASCII.GetBytes($text + "`n")
	$stdout.Write($bytes, 0, $bytes.Length)
	$stdout.Flush()
}

function Read-Line {
	$bytes = New-Object System.Collections.Generic.List[byte]
	while ($true) {
		$b = $stdin.ReadByte()
		if ($b -eq -1) { if ($bytes.Count -eq 0) { return $null } else { break } }
		if ($b -eq 10) { break }  # LF
		$bytes.Add([byte]$b)
	}
	return [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
}

function Read-ExactBytes([int64]$count) {
	$buf = New-Object byte[] $count
	$off = 0
	while ($off -lt $count) {
		$n = $stdin.Read($buf, $off, $count - $off)
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

# Mirrors the POSIX responder's is_safe_path exactly - see
# ../PROTOCOL.md's "Path rules". / is the only separator accepted on the
# wire even here; a literal \ anywhere is rejected outright rather than
# treated as a separator, so the wire format stays cross-platform
# identical. Verified against the same adversarial inputs the bash
# version was (../, absolute, C:/-rooted, backslash, //, trailing /,
# bare "..", empty) before going anywhere near GET/PUT/LIST.
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
# shared directory). Verified directly against a real symlink made
# with mklink: Test-Path alone follows a symlink to a file and reports
# it as a leaf, so the explicit ReparsePoint check below is the part
# that actually matters.
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
# included. Verified directly: FileMode.CreateNew throws against both
# an existing plain file and a real symlink (made with mklink), with
# the symlink's target left completely untouched either way (first
# attempt at this test used a relative path after Set-Location and
# wrongly looked like CreateNew didn't protect anything - that was
# PowerShell's $PWD diverging from .NET's own process working
# directory, a well-known gotcha; redone with absolute paths, which is
# what this responder always uses anyway since it never calls
# Set-Location, it confirmed the real, correct behavior). Returns the
# open stream (ready to write) on success, $null on failure - the
# caller must close it.
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

function Do-List([string]$dir) {
	if ([string]::IsNullOrEmpty($dir)) { $dir = "." }
	if ($dir -ne ".") {
		if (-not (Test-SafePath $dir)) { Write-Line "ERR invalid path"; return }
		if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Write-Line "ERR not found"; return }
	}
	Get-ChildItem -LiteralPath $dir | ForEach-Object {
		$mtime = [DateTimeOffset]::new($_.LastWriteTimeUtc, [TimeSpan]::Zero).ToUnixTimeSeconds()
		if ($_.PSIsContainer) {
			Write-Line "D 0 $mtime $($_.Name)"
		} else {
			Write-Line "F $($_.Length) $mtime $($_.Name)"
		}
	}
	Write-Line "END"
}

function Do-Get([string]$path, [string]$offsetStr, [string]$claimedHash) {
	if (-not (Test-SafePath $path)) { Write-Line "ERR invalid path"; return }
	if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Write-Line "ERR not found"; return }
	$size = (Get-Item -LiteralPath $path).Length

	if ([string]::IsNullOrEmpty($offsetStr)) {
		Write-Line "OK $size"
		$fs = [System.IO.File]::OpenRead($path)
		try { Copy-ExactBytes $fs $stdout $size } finally { $fs.Close() }
		return
	}

	# Resume request: offsetStr/claimedHash describe the bytes the
	# client already has. Only the overlap gets hashed here, never the
	# whole file - see ../PROTOCOL.md's "Partial-file safety".
	$offset = 0L
	if (-not [int64]::TryParse($offsetStr, [ref]$offset) -or $offset -lt 0 -or $offset -gt $size) {
		Write-Line "ERR invalid offset"
		return
	}
	$actualHash = Get-PrefixHash $path $offset
	if ($actualHash -ne $claimedHash) {
		Write-Line "ERR resume mismatch"
		return
	}
	$remaining = $size - $offset
	Write-Line "OK $remaining"
	if ($remaining -gt 0) {
		$fs = [System.IO.File]::OpenRead($path)
		try {
			[void]$fs.Seek($offset, [System.IO.SeekOrigin]::Begin)
			Copy-ExactBytes $fs $stdout $remaining
		} finally { $fs.Close() }
	}
}

function Do-Mkdir([string]$path) {
	if (-not (Test-SafePath $path)) { Write-Line "ERR invalid path"; return }
	try {
		New-Item -ItemType Directory -Path $path -Force | Out-Null
		Write-Line "OK"
	} catch {
		Write-Line "ERR mkdir failed"
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
		Write-Line "ERR invalid path"
		return
	}

	$partial = Get-PartialPath $path
	$offerOffset = 0L
	if (Test-SafePartial $partial) {
		$offerOffset = (Get-Item -LiteralPath $partial).Length
	}
	if ($offerOffset -gt 0 -and $offerOffset -le $size) {
		$offerHash = Get-PrefixHash $partial $offerOffset
		Write-Line "RESUME $offerOffset $offerHash"
	} else {
		$offerOffset = 0L
		Write-Line "FRESH"
	}

	$decision = Read-Line
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
		Write-Line "ERR unexpected reply"
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
		if ($remaining -gt 0) { [void](Read-ExactBytes $remaining) }
		Write-Line "ERR offset mismatch"
		return
	} else {
		if (-not (Reset-Partial $partial)) {
			if ($remaining -gt 0) { [void](Read-ExactBytes $remaining) }
			Write-Line "ERR staging blocked"
			return
		}
		$fs = New-ExclusiveFile $partial
		if ($null -eq $fs) {
			if ($remaining -gt 0) { [void](Read-ExactBytes $remaining) }
			Write-Line "ERR staging blocked"
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
	Write-Line "OK"
}

while ($true) {
	$line = Read-Line
	if ($null -eq $line) { break }  # EOF
	$parts = $line.Split(" ", 2)
	$cmd = $parts[0]
	switch ($cmd) {
		"LIST" { Do-List $(if ($parts.Length -gt 1) { $parts[1] } else { "" }) }
		"GET"  {
			# <path> [<offset> <hash>] - path may itself contain spaces
			# (already supported elsewhere, e.g. Do-List's entries), so
			# this can only ever split off a trailing "<digits>
			# <64-hex-chars>" pair, never blindly split the whole line
			# on whitespace (a naive split broke exactly this case
			# during development - caught before it shipped, same bug
			# as the POSIX responder's original GET/PUT splitting).
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
				Write-Line "ERR invalid path"
			}
		}
		"QUIT" { exit 0 }
		default {
			# Every request must get a response, even a bad one - see the
			# matching comment in gs-transfer-server.sh for why (confirmed by
			# direct testing there: an unanswered request leaves the
			# client's read blocked forever).
			Write-Line "ERR unknown command"
		}
	}
}
