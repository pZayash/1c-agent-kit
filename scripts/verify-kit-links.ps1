#Requires -Version 5.1
<#
.SYNOPSIS
  Verify key kit paths are junctions/reparse points (not plain copies).
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsumerRoot
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot "_win-reparse.ps1")

$root = (Resolve-Path $ConsumerRoot).Path
$fail = 0

function Read-LocalNames([string]$path) {
    $map = @{}
    if (-not $path -or -not (Test-Path $path)) { return $map }
    Get-Content -LiteralPath $path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) { $map[$line] = $true }
    }
    return $map
}

function Assert-KitLink([string]$rel, [string]$label) {
    $path = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "FAIL missing: $label ($path)"
        $script:fail = 1
        return
    }
    if (-not (Test-KitReparse $path)) {
        Write-Host "FAIL not junction/reparse (copy?): $label ($path)"
        $script:fail = 1
        return
    }
    Write-Host "OK $label"
}

Assert-KitLink ".cursor\skills\handoff" "skills/handoff"
Assert-KitLink ".cursor\skills\mailbox" "skills/mailbox"
Assert-KitLink "tools\mailbox" "tools/mailbox"

$local = Read-LocalNames (Join-Path $root "tools\cc-1c-skills-sync\local-tools.txt")
if (-not $local.ContainsKey("load-changed-files")) {
    Assert-KitLink "tools\load-changed-files" "tools/load-changed-files"
} else {
    Write-Host "SKIP LOCAL tools/load-changed-files"
}

Assert-KitLink ".agents\skills" ".agents/skills"
$exploreCursor = Join-Path $root ".cursor\skills\explore\SKILL.md"
$exploreAgents = Join-Path $root ".agents\skills\explore\SKILL.md"
if (Test-Path -LiteralPath $exploreCursor) {
    if (Test-Path -LiteralPath $exploreAgents) {
        Write-Host "OK .agents/skills/explore/SKILL.md"
    } else {
        Write-Host "FAIL missing: .agents/skills/explore/SKILL.md"
        $fail = 1
    }
}

if ($fail -ne 0) {
    exit 1
}
