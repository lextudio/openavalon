#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    PowerShell entry point for openavalon's local NuGet feed build on Windows.

.DESCRIPTION
    `dist.local.sh` is the single source of truth for the feed, and it must run under Git for
    Windows Bash: it uses `sed`, `uname`, `cygpath`, bash arrays and `set -euo pipefail`, and the
    feed lane itself shells out to Git Bash for its own checks. This wrapper does not reimplement
    any of that. It only removes the awkward part of calling it from Windows:

      * locates Git for Windows Bash (rejecting WSL's bash, which cannot run the lane),
      * sets the Windows lane's environment knobs from friendly parameters,
      * forwards every remaining argument to `dist.local.sh` unchanged,
      * streams output live and returns the child's exact exit code.

    Because the wrapper is a launcher, Git for Windows Bash is still required - that is a
    constraint of the lane, not of this script. A native PowerShell port would have to duplicate
    the whole ~900-line lane and would drift from the bash original; keep `dist.local.sh`
    authoritative.

.PARAMETER Bash
    Explicit path to Git for Windows `bash.exe`. Auto-detected when omitted.

.PARAMETER TargetPlatform
    Sets DIST_LOCAL_TARGET_PLATFORM (`windows`, `macos` or `all`). Omit to let the lane pick the
    host's lane, which is what you normally want on Windows.

.PARAMETER Feed
    Sets DIST_LOCAL_FEED to build into a non-default feed directory.

.PARAMETER Force
    Sets DIST_LOCAL_FORCE=1 and forwards `--force`, ignoring every incremental stage receipt and
    rebuilding the whole feed.

.PARAMETER RemainingArgs
    Any further arguments are passed straight to `dist.local.sh` (e.g. `--force`).

.EXAMPLE
    ./dist.local.ps1

.EXAMPLE
    ./dist.local.ps1 -Force

.EXAMPLE
    ./dist.local.ps1 -Bash 'D:\Tools\Git\bin\bash.exe' -TargetPlatform windows
#>
[CmdletBinding()]
param(
    [string]$Bash,

    [ValidateSet('windows', 'macos', 'all')]
    [string]$TargetPlatform,

    [string]$Feed,

    [switch]$Force,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs = @()
)

$ErrorActionPreference = 'Stop'

function Resolve-GitBash {
    <#
      Find a Git for Windows bash.exe. `bash.exe` on PATH may be WSL's, which reports `uname -s`
      as `Linux` and cannot run this lane, so every candidate is probed and only MINGW/MSYS/CYGWIN
      is accepted.
    #>
    param([string]$Explicit)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($Explicit) { $candidates.Add($Explicit) }

    $onPath = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($onPath) { $candidates.Add($onPath.Source) }

    $candidates.Add('C:\Program Files\Git\bin\bash.exe')
    $candidates.Add('C:\Program Files (x86)\Git\bin\bash.exe')
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'))
    }

    # Derive from git.exe when it is the only Git component on PATH.
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
        $candidates.Add((Join-Path $gitRoot 'bin\bash.exe'))
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $uname = & $candidate -c 'uname -s' 2>$null | Select-Object -First 1
            if ($uname -match '^(MINGW|MSYS|CYGWIN)') {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
        catch {
            # Not runnable as bash (or not a shell at all); try the next candidate.
        }
    }

    throw "Could not find Git for Windows Bash. Install Git for Windows, or pass -Bash <path to bash.exe>."
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$distScript = Join-Path $scriptDir 'dist.local.sh'
if (-not (Test-Path -LiteralPath $distScript -PathType Leaf)) {
    throw "dist.local.sh not found next to this script: $distScript"
}

$bashPath = Resolve-GitBash -Explicit $Bash

if ($TargetPlatform) { $env:DIST_LOCAL_TARGET_PLATFORM = $TargetPlatform }
if ($Feed) { $env:DIST_LOCAL_FEED = $Feed }
if ($Force) { $env:DIST_LOCAL_FORCE = '1' }

$forwarded = [System.Collections.Generic.List[string]]::new()
if ($Force) { $forwarded.Add('--force') }
foreach ($arg in $RemainingArgs) { $forwarded.Add($arg) }

Write-Host "==> bash: $bashPath"
Write-Host "==> script: $distScript"
if ($forwarded.Count -gt 0) { Write-Host "==> args: $($forwarded -join ' ')" }

Push-Location -LiteralPath $scriptDir
try {
    # './dist.local.sh' rather than the Windows path: the child's cwd is already the repo root,
    # so this avoids relying on MSYS path conversion of a C:\... argument.
    & $bashPath './dist.local.sh' @forwarded
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}

exit $exitCode
