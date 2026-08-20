#Requires -Version 5.1
<#
.SYNOPSIS
  One-shot kit bootstrap for consumer root (Windows).
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsumerRoot,

    [string]$HarnessRel = "harness",

    [switch]$DryRun,

    [switch]$ForceWrapper,

    [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = (Resolve-Path $ConsumerRoot).Path
$scripts = $PSScriptRoot
$harness = Join-Path $root $HarnessRel
if (-not (Test-Path $harness)) {
    throw "missing harness: $harness (git submodule update --init?)"
}

$common = @{
    ConsumerRoot = $root
    HarnessRel   = $HarnessRel
}
if ($DryRun) { $common["DryRun"] = $true }

Write-Host "=== link-cc-1c-skills ==="
& (Join-Path $scripts "link-cc-1c-skills.ps1") @common -LocalManifest (Join-Path $root "tools\cc-1c-skills-sync\local-skills.txt")

Write-Host "=== link-cursor-overlay ==="
& (Join-Path $scripts "link-cursor-overlay.ps1") @common -LocalManifest (Join-Path $root "tools\cc-1c-skills-sync\local-overlay.txt")

Write-Host "=== link-kit-tools ==="
& (Join-Path $scripts "link-kit-tools.ps1") @common -LocalManifest (Join-Path $root "tools\cc-1c-skills-sync\local-tools.txt")

Write-Host "=== link-editor-roots ==="
$editor = @{ ConsumerRoot = $root }
if ($DryRun) { $editor["DryRun"] = $true }
& (Join-Path $scripts "link-editor-roots.ps1") @editor

$wrapper = Join-Path $root "load-changed-files.sh"
$engine = Join-Path $harness "tools\load-changed-files\load-changed-files.sh"
$thinMarker = "harness/tools/load-changed-files/load-changed-files.sh"
$thinLines = @(
    '#!/bin/bash',
    '_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
    'exec bash "${_ROOT}/harness/tools/load-changed-files/load-changed-files.sh" "$@"'
)

if (Test-Path $engine) {
    $writeThin = $false
    if (-not (Test-Path $wrapper)) {
        $writeThin = $true
    } else {
        $text = Get-Content -LiteralPath $wrapper -Raw -ErrorAction SilentlyContinue
        if ($text -notmatch [regex]::Escape($thinMarker)) {
            if ($ForceWrapper) {
                $writeThin = $true
            } else {
                Write-Host "WARN: load-changed-files.sh looks fat/legacy; pass -ForceWrapper to replace"
            }
        }
    }
    if ($writeThin) {
        if ($DryRun) {
            Write-Host "WOULD write thin load-changed-files.sh"
        } else {
            Write-Host "write thin load-changed-files.sh"
            Set-Content -LiteralPath $wrapper -Value ($thinLines -join "`n") -Encoding utf8
        }
    }
}

if (-not $SkipVerify) {
    Write-Host "=== verify-kit-links ==="
    & (Join-Path $scripts "verify-kit-links.ps1") -ConsumerRoot $root
}

Write-Host "bootstrap-kit: Done."
