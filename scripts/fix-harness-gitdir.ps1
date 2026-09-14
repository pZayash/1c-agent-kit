#Requires -Version 5.1
<#
.SYNOPSIS
  Rewrite harness/.git for git worktrees (consumer .git is a file).
.PARAMETER ConsumerRoot
  Consumer worktree root.
.PARAMETER CopyFrom
  Optional path to another worktree's modules/harness to copy if missing.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsumerRoot,

    [string]$HarnessRel = "harness",

    [string]$CopyFrom = "",

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = (Resolve-Path $ConsumerRoot).Path
$gitFile = Join-Path $root ".git"
$harnessDir = Join-Path $root $HarnessRel
$harnessGit = Join-Path $harnessDir ".git"

if (-not (Test-Path -LiteralPath $gitFile)) {
    throw "FAIL: no .git at $root"
}

function ConvertTo-AbsPath([string]$base, [string]$rel) {
    $rel = $rel.Trim()
    if ([System.IO.Path]::IsPathRooted($rel)) {
        return [System.IO.Path]::GetFullPath($rel)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $base $rel))
}

if ((Get-Item -LiteralPath $gitFile).PSIsContainer) {
    $wtGitdir = $gitFile
} else {
    $line = (Get-Content -LiteralPath $gitFile -TotalCount 1).Trim()
    if ($line -notmatch '^gitdir:\s*(.+)$') {
        throw "FAIL: cannot parse $gitFile"
    }
    $wtGitdir = ConvertTo-AbsPath $root $Matches[1]
}

$candidateWt = Join-Path $wtGitdir "modules\harness"
$candidateCommon = $null
$commonFile = Join-Path $wtGitdir "commondir"
if (Test-Path -LiteralPath $commonFile) {
    $commonRaw = (Get-Content -LiteralPath $commonFile -TotalCount 1).Trim()
    $commonAbs = ConvertTo-AbsPath $wtGitdir $commonRaw
    $candidateCommon = Join-Path $commonAbs "modules\harness"
}

$target = $null
if (Test-Path -LiteralPath $candidateWt) {
    $target = $candidateWt
} elseif ($CopyFrom) {
    if (-not (Test-Path -LiteralPath $CopyFrom)) {
        throw "FAIL: CopyFrom not a directory: $CopyFrom"
    }
    Write-Host "copy modules/harness from $CopyFrom -> $candidateWt"
    if (-not $DryRun) {
        $parent = Split-Path $candidateWt -Parent
        if (-not (Test-Path $parent)) {
            New-Item -ItemType Directory -Path $parent | Out-Null
        }
        Copy-Item -LiteralPath $CopyFrom -Destination $candidateWt -Recurse -Force
    }
    $target = $candidateWt
} elseif ($candidateCommon -and (Test-Path -LiteralPath $candidateCommon)) {
    $target = $candidateCommon
    Write-Host "WARN: using shared $target (not worktree-local). Checkout SHA here moves HEAD for every consumer of this gitdir."
} else {
    Write-Host "FAIL: harness gitdir missing."
    Write-Host "  tried: $candidateWt"
    if ($candidateCommon) { Write-Host "  tried: $candidateCommon" }
    Write-Host "  fix: -CopyFrom <other-wt>\modules\harness or git submodule update --init after git works"
    Write-Host "  emergency: rename $harnessDir to $($harnessDir).bak (unblocks parent git)"
    exit 1
}

# gitdir file prefers forward slashes (matches git worktree on Windows)
$targetGit = ($target -replace '\\', '/')

Write-Host "consumer .git -> $wtGitdir"
Write-Host "harness gitdir -> $targetGit"

if (-not ((Get-Item -LiteralPath $gitFile).PSIsContainer) -and (Test-Path -LiteralPath $harnessGit)) {
    $current = (Get-Content -LiteralPath $harnessGit -TotalCount 1 -ErrorAction SilentlyContinue)
    if ($current -match 'gitdir:\s*\.\./\.git/modules/harness') {
        Write-Host "PITFALL: relative gitdir ../.git/modules/harness with file-gitdir (parent git broken on Windows)"
    }
}

if ($DryRun) {
    Write-Host "DRY_RUN: would write $harnessGit"
    exit 0
}

if (-not (Test-Path -LiteralPath $harnessDir)) {
    New-Item -ItemType Directory -Path $harnessDir | Out-Null
}
Set-Content -LiteralPath $harnessGit -Value "gitdir: $targetGit" -Encoding ascii -NoNewline
Add-Content -LiteralPath $harnessGit -Value "" -Encoding ascii
Write-Host "wrote $harnessGit"
