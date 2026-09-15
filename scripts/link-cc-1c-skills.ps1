#Requires -Version 5.1
<#
.SYNOPSIS
  Junction .cursor/skills/<name> -> harness/skills/cc-1c/<name> (Windows mklink /J).
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

$root = (Resolve-Path $ConsumerRoot).Path
$kitSkills = Join-Path (Join-Path (Join-Path $root $HarnessRel) "skills") "cc-1c"
$cursorSkills = Join-Path $root ".cursor\skills"

if (-not (Test-Path $kitSkills)) {
    throw "Kit skills not found: $kitSkills (init submodule?)"
}
if (-not (Test-Path $cursorSkills)) {
    New-Item -ItemType Directory -Path $cursorSkills -Force | Out-Null
}

$local = @{}
Get-Content -LiteralPath $LocalManifest -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) { $local[$line] = $true }
}

Get-ChildItem -LiteralPath $kitSkills -Directory | ForEach-Object {
    $name = $_.Name
    if ($local.ContainsKey($name)) {
        Write-Host "SKIP LOCAL: $name"
        return
    }
    $link = Join-Path $cursorSkills $name
    $target = $_.FullName
    if ($DryRun) {
        if (Test-Path $link) {
            if (-not (Test-KitReparse $link)) {
                Write-Host "WOULD REPLACE COPY: $link -> $target"
            } else {
                Write-Host "WOULD RELINK: $link -> $target"
            }
        } else {
            Write-Host "WOULD LINK: $link -> $target"
        }
        return
    }
    if (Test-Path $link) {
        if (Test-KitReparse $link) {
            Remove-KitReparseOrTree $link
        } elseif ($NoReplaceCopies) {
            Write-Error "Exists and not junction: $link (omit -NoReplaceCopies or add to LOCAL)"
            return
        } else {
            Write-Host "REPLACE COPY: $name"
            Remove-KitReparseOrTree $link
        }
    }
    cmd /c "mklink /J `"$link`" `"$target`""
    if ($LASTEXITCODE -ne 0) {
        Write-Error "mklink failed for $name"
        return
    }
    Write-Host "LINK: $name"
}

# Prune kit-owned junctions whose skill vanished upstream (tombstones).
Remove-KitStaleLinks -LinkRoot $cursorSkills -KitSource $kitSkills -Local $local -DryRun:$DryRun

Write-Host "Done."
