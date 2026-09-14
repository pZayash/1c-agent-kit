#Requires -Version 5.1
<#
.SYNOPSIS
  Pi harness roots: .pi/skills -> .cursor/skills,
  .pi/prompts -> .cursor/commands, .pi/extensions -> harness/pi/extensions.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsumerRoot,

    [string]$HarnessRel = "harness",

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot "_win-reparse.ps1")

$root = (Resolve-Path $ConsumerRoot).Path
$cursorSkills = Join-Path $root ".cursor\skills"
$cursorCommands = Join-Path $root ".cursor\commands"
$kitExtensions = Join-Path (Join-Path $root $HarnessRel) "pi\extensions"

function New-PiJunction([string]$link, [string]$target, [string]$name) {
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host "SKIP $name (no target $target)"
        return
    }
    $parent = Split-Path $link -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        if ($DryRun) {
            Write-Host "WOULD mkdir $parent"
        } else {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
    }
    if ($DryRun) {
        Write-Host "WOULD JUNCTION: $link -> $target"
        return
    }
    if (Test-Path -LiteralPath $link) {
        if (Test-KitReparse $link) {
            Remove-KitReparseOrTree $link
        } else {
            Write-Host "REPLACE COPY: $name"
            Remove-KitReparseOrTree $link
        }
    }
    cmd /c "mklink /J `"$link`" `"$target`"" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "mklink /J failed: $name" }
    Write-Host "JUNCTION: $name"
}

if (Test-Path -LiteralPath $cursorSkills) {
    New-PiJunction (Join-Path $root ".pi\skills") $cursorSkills ".pi/skills"
} else {
    Write-Host "SKIP .pi/skills (no .cursor/skills)"
}

if (Test-Path -LiteralPath $cursorCommands) {
    New-PiJunction (Join-Path $root ".pi\prompts") $cursorCommands ".pi/prompts"
} else {
    Write-Host "SKIP .pi/prompts (no .cursor/commands)"
}

if (Test-Path -LiteralPath $kitExtensions) {
    New-PiJunction (Join-Path $root ".pi\extensions") $kitExtensions ".pi/extensions"
} else {
    Write-Host "SKIP .pi/extensions (no harness/pi/extensions)"
}

Write-Host "Done."
