#Requires -Version 5.1
<#
.SYNOPSIS
  Junction .cursor/skills/<name> -> harness/skills/cc-1c/<name> (Windows mklink /J).

.PARAMETER ConsumerRoot
  Root of consumer repo (contains .cursor/ and harness/).

.PARAMETER HarnessRel
  Relative path to harness submodule from ConsumerRoot.

.PARAMETER LocalManifest
  Text file: one skill name per line (# comments). Skipped from linking.

.PARAMETER DryRun
  Print planned links only.

.PARAMETER ReplaceCopies
  If .cursor/skills/<name> is a real directory (not junction), delete it and
  create a junction. Default: on. LOCAL names are never touched.
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
            $item = Get-Item -LiteralPath $link -Force
            $isReparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
            if (-not $isReparse) {
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
        $item = Get-Item -LiteralPath $link -Force
        $isReparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
        if ($isReparse) {
            Remove-Item -LiteralPath $link -Force
        } elseif ($NoReplaceCopies) {
            Write-Error "Exists and not junction: $link (omit -NoReplaceCopies or add to LOCAL)"
            return
        } else {
            Write-Host "REPLACE COPY: $name"
            Remove-Item -LiteralPath $link -Recurse -Force
        }
    }
    cmd /c "mklink /J `"$link`" `"$target`""
    if ($LASTEXITCODE -ne 0) {
        Write-Error "mklink failed for $name"
        return
    }
    Write-Host "LINK: $name"
}

Write-Host "Done."
