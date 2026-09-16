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
        } elseif ($NoReplaceCopies) {
            Write-Host "SKIP exists: $link"
            return
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
$overlay = Join-Path (Join-Path $root $HarnessRel) "cursor"
if (-not (Test-Path $overlay)) { throw "overlay not found: $overlay" }

$local = Read-LocalNames $LocalManifest
$cursor = Join-Path $root ".cursor"
$script:FallbackMap = Read-KitFallbackManifest $root
$script:ManagedPaths = New-Object System.Collections.Generic.List[string]

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
        [void]$script:ManagedPaths.Add(".cursor/skills/$($_.Name)")
    }
    Remove-KitStaleLinks -LinkRoot $skillsDst -KitSource $skillsSrc -Local $local -DryRun:$DryRun
}

$rulesSrc = Join-Path $overlay "rules"
if (Test-Path $rulesSrc) {
    $rulesDst = Join-Path $cursor "rules"
    Get-ChildItem -LiteralPath $rulesSrc -File | ForEach-Object {
        if ($local.ContainsKey($_.Name)) {
            Write-Host "SKIP LOCAL: $($_.Name)"
            return
        }
        New-FileLink (Join-Path $rulesDst $_.Name) $_.FullName $_.Name ".cursor/rules/$($_.Name)" "$HarnessRel/cursor/rules/$($_.Name)"
        [void]$script:ManagedPaths.Add(".cursor/rules/$($_.Name)")
    }
    Remove-KitStaleLinks -LinkRoot $rulesDst -KitSource $rulesSrc -Local $local -DryRun:$DryRun
}

$cmdSrc = Join-Path $overlay "commands"
if (Test-Path $cmdSrc) {
    $cmdDst = Join-Path $cursor "commands"
    Get-ChildItem -LiteralPath $cmdSrc -File | ForEach-Object {
        if ($local.ContainsKey($_.Name)) {
            Write-Host "SKIP LOCAL: $($_.Name)"
            return
        }
        New-FileLink (Join-Path $cmdDst $_.Name) $_.FullName $_.Name ".cursor/commands/$($_.Name)" "$HarnessRel/cursor/commands/$($_.Name)"
        [void]$script:ManagedPaths.Add(".cursor/commands/$($_.Name)")
    }
    Remove-KitStaleLinks -LinkRoot $cmdDst -KitSource $cmdSrc -Local $local -DryRun:$DryRun
}

Remove-KitStaleFallback -Root $root -Map $script:FallbackMap -Prefix ".cursor/" -DryRun:$DryRun
if (-not $DryRun) {
    Save-KitFallbackManifest $root $script:FallbackMap
    Update-KitGitignore -Root $root -Paths $script:ManagedPaths -Id "cursor-overlay"
}

Write-Host "Done."
