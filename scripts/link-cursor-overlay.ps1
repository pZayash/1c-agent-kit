#Requires -Version 5.1
<#
.SYNOPSIS
  Link harness/cursor overlay into consumer .cursor/ (skills = /J, rules/commands = file mklink).
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsumerRoot,

    [string]$HarnessRel = "harness",

    [string]$LocalManifest = "",

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
            Write-Host "SKIP exists: $link"
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
            Write-Host "SKIP exists: $link"
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
    Write-Host "WARN: file symlink failed for $name - copy fallback (enable Developer Mode)"
    Copy-Item -LiteralPath $target -Destination $link -Force
    Write-Host "COPY: $name"
}

$root = (Resolve-Path $ConsumerRoot).Path
$overlay = Join-Path (Join-Path $root $HarnessRel) "cursor"
if (-not (Test-Path $overlay)) { throw "overlay not found: $overlay" }

$local = Read-LocalNames $LocalManifest
$cursor = Join-Path $root ".cursor"

$skillsSrc = Join-Path $overlay "skills"
if (Test-Path $skillsSrc) {
    $skillsDst = Join-Path $cursor "skills"
    if (-not (Test-Path $skillsDst)) { New-Item -ItemType Directory -Path $skillsDst -Force | Out-Null }
    Get-ChildItem -LiteralPath $skillsSrc -Directory | ForEach-Object {
        if ($local.ContainsKey($_.Name)) {
            Write-Host "SKIP LOCAL: $($_.Name)"
            return
        }
        New-DirJunction (Join-Path $skillsDst $_.Name) $_.FullName $_.Name
    }
}

$rulesSrc = Join-Path $overlay "rules"
if (Test-Path $rulesSrc) {
    $rulesDst = Join-Path $cursor "rules"
    Get-ChildItem -LiteralPath $rulesSrc -File | ForEach-Object {
        if ($local.ContainsKey($_.Name)) {
            Write-Host "SKIP LOCAL: $($_.Name)"
            return
        }
        New-FileLink (Join-Path $rulesDst $_.Name) $_.FullName $_.Name
    }
}

$cmdSrc = Join-Path $overlay "commands"
if (Test-Path $cmdSrc) {
    $cmdDst = Join-Path $cursor "commands"
    Get-ChildItem -LiteralPath $cmdSrc -File | ForEach-Object {
        if ($local.ContainsKey($_.Name)) {
            Write-Host "SKIP LOCAL: $($_.Name)"
            return
        }
        New-FileLink (Join-Path $cmdDst $_.Name) $_.FullName $_.Name
    }
}

Write-Host "Done."
