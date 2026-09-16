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

    [switch]$SkipVerify,

    [switch]$SkipDeps,

    [switch]$SkipSections,

    [switch]$LegacyLinks
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

if (-not $LegacyLinks) {
    Write-Host "=== kit-layout (engine) ==="
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $py) { throw "kit-layout needs python on PATH (or -LegacyLinks)" }
    $lcmd = "apply"
    if ($DryRun) { $lcmd = "plan" }
    $env:HARNESS_REL = $HarnessRel
    & $py.Source (Join-Path $harness "tools\kit-layout\kit_layout.py") $lcmd $root
    if ($LASTEXITCODE -ne 0) { throw "kit-layout $lcmd failed" }
} else {
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

    Write-Host "=== link-pi-roots ==="
    $pi = @{ ConsumerRoot = $root; HarnessRel = $HarnessRel }
    if ($DryRun) { $pi["DryRun"] = $true }
    & (Join-Path $scripts "link-pi-roots.ps1") @pi
}

$sectionsDir = Join-Path $harness "templates\sections"
$agentsMd = Join-Path $root "AGENTS.md"
if (-not $SkipSections -and (Test-Path $sectionsDir) -and (Test-Path $agentsMd)) {
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if ($py) {
        Write-Host "=== section-patch (AGENTS.md) ==="
        Get-ChildItem -LiteralPath $sectionsDir -Filter *.md -File | ForEach-Object {
            $spArgs = @("apply", $agentsMd, "--slug", $_.BaseName, "--body-file", $_.FullName)
            if ($DryRun) { $spArgs += "--dry-run" }
            & $py.Source (Join-Path $harness "tools\section-patch\section-patch.py") @spArgs
        }
    } else {
        Write-Host "WARN: no python on PATH - skip section-patch"
    }
}

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
            # PS 5.1 'Set-Content -Encoding utf8' writes a UTF-8 BOM; bash then
            # chokes on the shebang ("#!/bin/bash: No such file or directory").
            # Write BOM-less UTF-8 explicitly.
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($wrapper, ($thinLines -join "`n"), $utf8NoBom)
        }
    }
}

if (-not $SkipVerify) {
    Write-Host "=== verify-kit-links ==="
    & (Join-Path $scripts "verify-kit-links.ps1") -ConsumerRoot $root
}

if (-not $SkipDeps) {
    Write-Host "=== init-kit-deps (check) ==="
    $dep = Join-Path $scripts "init-kit-deps.ps1"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dep -ConsumerRoot $root
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WARN host deps incomplete - harness/docs/ai/kit-host-deps.md (-Install). Links still done."
    }
}

Write-Host "bootstrap-kit: Done."
