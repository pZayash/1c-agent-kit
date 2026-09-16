#Requires -Version 5.1
<#
.SYNOPSIS
  Editor skill roots: .agents/skills and .claude/skills|commands -> .cursor/*
  Cursor UI reads .agents/skills; kit junctions live in .cursor/skills.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsumerRoot,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot "_win-reparse.ps1")

$root = (Resolve-Path $ConsumerRoot).Path
$cursorSkills = Join-Path $root ".cursor\skills"
$cursorCommands = Join-Path $root ".cursor\commands"

function New-EditorJunction([string]$link, [string]$target, [string]$name) {
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

$managed = New-Object System.Collections.Generic.List[string]
if (Test-Path -LiteralPath $cursorSkills) {
    New-EditorJunction (Join-Path $root ".agents\skills") $cursorSkills ".agents/skills"
    New-EditorJunction (Join-Path $root ".claude\skills") $cursorSkills ".claude/skills"
    [void]$managed.Add(".agents/skills")
    [void]$managed.Add(".claude/skills")
} else {
    Write-Host "SKIP editor skill roots (no .cursor/skills)"
}

if (Test-Path -LiteralPath $cursorCommands) {
    New-EditorJunction (Join-Path $root ".claude\commands") $cursorCommands ".claude/commands"
    [void]$managed.Add(".claude/commands")
}

if (-not $DryRun -and $managed.Count -gt 0) {
    Update-KitGitignore -Root $root -Paths $managed -Id "editor-roots"
}

Write-Host "Done."
