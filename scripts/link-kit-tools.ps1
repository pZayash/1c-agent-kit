#Requires -Version 5.1
<#
.SYNOPSIS
  Junction consumer tools/<name> -> harness/{core,stacks/<s>}/tools/<name>
  (Windows mklink /J). File link for git-partial-stage.py.
  Stack sources only when the stack is selected (.kit.json); without it - legacy.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsumerRoot,

    [string]$HarnessRel = "harness",

    [string]$LocalManifest = "",

    [switch]$DryRun,

    [switch]$ReplaceCopies
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot "_win-reparse.ps1")

function Read-LocalNames([string]$path) {
    $map = @{}
    if (-not $path -or -not (Test-Path $path)) { return $map }
    Get-Content -LiteralPath $path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) { $map[$line] = $true }
    }
    return $map
}

function New-DirJunction([string]$link, [string]$target, [string]$name) {
    if ($DryRun) {
        Write-Host "WOULD JUNCTION: $link -> $target"
        return
    }
    if (Test-Path $link) {
        if (Test-KitReparse $link) {
            Remove-KitReparseOrTree $link
        } elseif (-not $ReplaceCopies) {
            Write-Host "SKIP consumer-owned exists (-ReplaceCopies to overwrite): $link"
            return
        } else {
            Write-Host "REPLACE COPY: $name"
            Remove-KitReparseOrTree $link
        }
    }
    cmd /c "mklink /J `"$link`" `"$target`"" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "mklink /J failed: $name" }
    Write-Host "JUNCTION: $name"
}

function New-FileLink([string]$link, [string]$target, [string]$name, [string]$rel, [string]$sourceRel) {
    if ($DryRun) {
        Write-Host "WOULD FILELINK: $link -> $target"
        return
    }
    $parent = Split-Path $link -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path $link) {
        if (Test-KitReparse $link) {
            Remove-KitReparseOrTree $link
        } elseif (Test-KitFileEqual $link $target) {
            Write-Host "OK (fallback, in sync): $name"
            Set-KitFallbackEntry -Map $script:FallbackMap -Rel $rel -Source $sourceRel -Sha (Get-KitFileHash $target)
            return
        } else {
            $rec = $script:FallbackMap[$rel]
            $linkHash = Get-KitFileHash $link
            if ($rec -and $linkHash -ne $rec.sha -and $linkHash -ne (Get-KitFileHash $target)) {
                Write-Host "WARN KEEP LOCAL EDITS in fallback: $name (not overwritten; move it to local manifest to own it)"
                return
            }
            if (-not $rec -and -not $ReplaceCopies) {
                Write-Host "SKIP consumer-owned exists (-ReplaceCopies to overwrite): $link"
                return
            }
            Write-Host "WARN REFRESH stale fallback: $name"
            Remove-KitReparseOrTree $link
        }
    }
    $how = New-KitFileLink $target $link
    if ($how -eq 'FILELINK') {
        Write-Host "FILELINK: $name"
    } else {
        Write-Host "WARN $how (no symlink privilege): $name"
        Set-KitFallbackEntry -Map $script:FallbackMap -Rel $rel -Source $sourceRel -Sha (Get-KitFileHash $target)
    }
}

$root = (Resolve-Path $ConsumerRoot).Path
if (-not $LocalManifest) { $LocalManifest = Get-KitLocalManifest $root "tools" }
$consumerTools = Join-Path $root "tools"
if (-not (Test-Path $consumerTools)) {
    New-Item -ItemType Directory -Path $consumerTools -Force | Out-Null
}

# name@srcdir pairs: core for everyone; stacks by selection (config via
# print-config only); docs-links is a legacy kit-internal extra.
$coreTools = Join-Path $root "$HarnessRel\core\tools"
$tools1c = Join-Path $root "$HarnessRel\stacks\1c\tools"
$kitTools = Join-Path $root "$HarnessRel\tools"
$linkable = @(
    @{ name = "sandbox"; src = $coreTools },
    @{ name = "docs-links"; src = $kitTools }
)
if (Test-KitStackSelected $root "1c" $HarnessRel) {
    foreach ($n in @("bsl-check", "load-changed-files", "mcp-call", "answer42", "rights-xml-lint")) {
        $linkable += @{ name = $n; src = $tools1c }
    }
}

$local = Read-LocalNames $LocalManifest
$script:FallbackMap = Read-KitFallbackManifest $root
$script:ManagedPaths = New-Object System.Collections.Generic.List[string]
$srcDirs = @{}

foreach ($e in $linkable) {
    $name = $e.name
    $srcDirs[$e.src] = $true
    if ($local.ContainsKey($name)) {
        Write-Host "SKIP LOCAL: $name"
        continue
    }
    $target = Join-Path $e.src $name
    if (-not (Test-Path $target)) {
        Write-Host "SKIP missing in kit: $name"
        continue
    }
    New-DirJunction (Join-Path $consumerTools $name) $target $name
    [void]$script:ManagedPaths.Add("tools/$name")
}

if (-not $local.ContainsKey("git-partial-stage.py")) {
    $pyTarget = Join-Path $coreTools "git-partial-stage.py"
    if (Test-Path $pyTarget) {
        New-FileLink (Join-Path $consumerTools "git-partial-stage.py") $pyTarget "git-partial-stage.py" "tools/git-partial-stage.py" "$HarnessRel/core/tools/git-partial-stage.py"
        [void]$script:ManagedPaths.Add("tools/git-partial-stage.py")
    }
}

# Prune kit-owned links whose tool vanished upstream (tombstones), per source.
foreach ($src in $srcDirs.Keys) {
    Remove-KitStaleLinks -LinkRoot $consumerTools -KitSource $src -Local $local -DryRun:$DryRun
}

Remove-KitStaleFallback -Root $root -Map $script:FallbackMap -Prefix "tools/" -DryRun:$DryRun
if (-not $DryRun) {
    Save-KitFallbackManifest $root $script:FallbackMap
    Update-KitGitignore -Root $root -Paths $script:ManagedPaths -Id "kit-tools"
}

Write-Host "Done."
