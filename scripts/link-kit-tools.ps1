#Requires -Version 5.1
<#
.SYNOPSIS
  Junction consumer tools/<name> -> harness/tools/<name> (Windows mklink /J).
  File link for git-partial-stage.py.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsumerRoot,

    [string]$HarnessRel = "harness",

    [Parameter(Mandatory = $true)]
    [string]$LocalManifest,

    [switch]$DryRun,

    [switch]$NoReplaceCopies
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
        } elseif ($NoReplaceCopies) {
            Write-Error "Exists and not junction: $link"
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

function New-FileLink([string]$link, [string]$target, [string]$name) {
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
        } elseif ($NoReplaceCopies) {
            Write-Error "Exists and not link: $link"
            return
        } else {
            Remove-KitReparseOrTree $link
        }
    }
    cmd /c "mklink `"$link`" `"$target`"" | Out-Host
    if ($LASTEXITCODE -eq 0) {
        Write-Host "FILELINK: $name"
        return
    }
    Write-Host "WARN: file symlink failed for $name - copy fallback"
    Copy-Item -LiteralPath $target -Destination $link -Force
    Write-Host "COPY: $name"
}

$root = (Resolve-Path $ConsumerRoot).Path
$kitTools = Join-Path (Join-Path $root $HarnessRel) "tools"
$consumerTools = Join-Path $root "tools"

if (-not (Test-Path $kitTools)) {
    throw "Kit tools not found: $kitTools (init submodule?)"
}
if (-not (Test-Path $consumerTools)) {
    New-Item -ItemType Directory -Path $consumerTools -Force | Out-Null
}

$local = Read-LocalNames $LocalManifest
$dirNames = @("mailbox", "bsl-check", "sandbox", "load-changed-files", "mcp-call")

foreach ($name in $dirNames) {
    if ($local.ContainsKey($name)) {
        Write-Host "SKIP LOCAL: $name"
        continue
    }
    $target = Join-Path $kitTools $name
    if (-not (Test-Path $target)) {
        Write-Host "SKIP missing in kit: $name"
        continue
    }
    New-DirJunction (Join-Path $consumerTools $name) $target $name
}

if (-not $local.ContainsKey("git-partial-stage.py")) {
    $pyTarget = Join-Path $kitTools "git-partial-stage.py"
    if (Test-Path $pyTarget) {
        New-FileLink (Join-Path $consumerTools "git-partial-stage.py") $pyTarget "git-partial-stage.py"
    }
}

Write-Host "Done."
