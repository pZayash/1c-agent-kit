#Requires -Version 5.1
<#
.SYNOPSIS
  Verify kit links declared in layout.json - single source of truth:
  tools/kit-layout/layout.json (resources[].include).

.DESCRIPTION
  Delegates to kit_layout.py verify, i.e. checks exactly the list that `apply`
  creates. The former hardcoded three-link list missed tools/docs-links: losing
  it in the consumer layout went unnoticed (doctor said PASS while the docs-links
  check was dead).

  NOTE: keep this file ASCII-only. Windows PowerShell 5.1 misparses non-ASCII
  bytes in a BOM-less .ps1 (kit-doctor check "non-ASCII in BOM-less *.ps1").
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsumerRoot
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONUTF8 = "1"

$root = (Resolve-Path $ConsumerRoot).Path
$engine = Join-Path $PSScriptRoot "..\tools\kit-layout\kit_layout.py"
if (-not (Test-Path -LiteralPath $engine)) {
    Write-Host "ERROR: kit-layout engine not found: $engine"
    exit 1
}

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) {
    Write-Host "ERROR: python not on PATH - verify runs through kit-layout ($engine)"
    exit 1
}

& $py.Source $engine verify $root
exit $LASTEXITCODE
