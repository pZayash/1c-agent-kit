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

# Trimmed PATH (agent/GUI terminals) has no bare powershell.exe - resolve from $PSHOME.
$psExe = Join-Path $PSHOME "powershell.exe"
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = Join-Path $PSHOME "pwsh.exe" }

$root = (Resolve-Path $ConsumerRoot).Path
$scripts = $PSScriptRoot
$harness = Join-Path $root $HarnessRel
if (-not (Test-Path $harness)) {
    throw "missing harness: $harness (git submodule update --init?)"
}

# Consumer .gitattributes: without "*.sh ... eol=lf" core.autocrlf=true checks
# out CRLF into *.sh and they fail ("syntax error"). Warn, not fatal.
# The .sh twin checks the same on the Linux-native path. ASCII only (PS 5.1).
$gitattrFile = Join-Path $root ".gitattributes"
$hasShLf = $false
if (Test-Path -LiteralPath $gitattrFile) {
    $hasShLf = [bool](Get-Content -LiteralPath $gitattrFile |
        Where-Object { $_ -match '^\*\.sh\s.*eol=lf' } |
        Select-Object -First 1)
}
if (-not $hasShLf) {
    Write-Host "WARN: consumer .gitattributes lacks '*.sh text eol=lf' -"
    Write-Host "WARN: with core.autocrlf=true .sh files checkout CRLF and fail."
    Write-Host 'WARN: add: *.sh text eol=lf | *.py text eol=lf | *.ps1 text | *.xml -text | *.bsl -text'
    Write-Host "WARN: then: git add .gitattributes; git add --renormalize -- '*.sh'; git checkout -- '*.sh'"
}

# Namespace guard: links created by another namespace (or after the consumer
# tree was moved) must not be relinked here. The engine also refuses, but this
# stops legacy link-*.ps1 steps before they touch anything. ASCII only (PS 5.1).
. (Join-Path $scripts "_win-reparse.ps1")
$nsCandidates = @(
    ".agents\skills", ".claude\skills", ".claude\commands",
    ".pi\skills", ".pi\prompts", ".pi\extensions"
)
# Dynamic reparse scan - new stack kit-tools are picked up without a list edit.
foreach ($d in @(".cursor\skills", ".cursor\rules", ".cursor\commands", "tools")) {
    $full = Join-Path $root $d
    if (Test-Path -LiteralPath $full) {
        Get-ChildItem -LiteralPath $full -Force | ForEach-Object {
            if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $nsCandidates += (Join-Path $d $_.Name)
            }
        }
    }
}
$foreignLinks = @()
foreach ($rel in $nsCandidates) {
    $p = Join-Path $root $rel
    if ((Test-Path -LiteralPath $p) -and (Test-KitForeignLink $root $p)) {
        $foreignLinks += ("{0} -> {1}" -f $rel, (Get-KitReparseTarget $p))
    }
}
if ($foreignLinks.Count -gt 0) {
    Write-Host "ERROR: kit links point outside $root (foreign namespace):"
    $foreignLinks | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" }
    if ($foreignLinks.Count -gt 5) { Write-Host "  ... and $($foreignLinks.Count - 5) more" }
    Write-Host "Run bootstrap on the host that created the layout (Git Bash / PowerShell)."
    exit 2
}

$common = @{
    ConsumerRoot = $root
    HarnessRel   = $HarnessRel
}
if ($DryRun) { $common["DryRun"] = $true }

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
$kitLayout = Join-Path $harness "tools\kit-layout\kit_layout.py"
$stack1c = $false

if (-not $LegacyLinks) {
    Write-Host "=== kit-layout (engine) ==="
    if (-not $py) { throw "kit-layout needs python on PATH (or -LegacyLinks)" }
    $env:HARNESS_REL = $HarnessRel

    function Test-SparseActive {
        # PS7 + EAP=Stop: non-zero exit throws before 2>$null applies.
        try { & git -C $harness sparse-checkout list 2>$null | Out-Null }
        catch { }
        return ($LASTEXITCODE -eq 0)
    }

    # 1) Config: the only .kit.json parser is print-config --json (validates
    #    before any mutation). A stale sparse pattern may hide the selected
    #    stack's stack.json -> widen the checkout and retry once.
    $cfgText = & $py.Source $kitLayout print-config $root --harness-rel $HarnessRel --json
    if ($LASTEXITCODE -ne 0) {
        if ((Test-Path (Join-Path $root ".kit.json")) -and (Test-SparseActive)) {
            Write-Host "WARN: print-config failed under sparse-checkout - widening to /* and retrying"
            if (-not $DryRun) { & git -C $harness sparse-checkout set --no-cone '/*' }
            $cfgText = & $py.Source $kitLayout print-config $root --harness-rel $HarnessRel --json
        }
        if ($LASTEXITCODE -ne 0) { throw "print-config failed (.kit.json invalid)" }
    }

    if (-not (Test-Path (Join-Path $root ".kit.json"))) {
        Write-Host "HINT: no .kit.json - core-only mode (stacks: [])."
        Write-Host 'HINT: to enable a stack create e.g.:'
        Write-Host 'HINT:   {"version": 1, "stacks": ["1c"], "source_root": "conf/", "sparse": false}'
    }

    $cfg = ($cfgText | Out-String) | ConvertFrom-Json
    $kitStacks = @()
    if ($null -ne $cfg.stacks) { $kitStacks = @($cfg.stacks) }
    elseif ($null -ne $cfg.effective_stacks) { $kitStacks = @($cfg.effective_stacks) }
    $kitSparse = [bool]$cfg.sparse

    # 2) Sparse: positive pattern (works when stacks/* are already hidden;
    #    stack.json ALWAYS stays in checkout for name validation). "*" under
    #    KIT_LEGACY needs all files -> disable sparse.
    if ($kitStacks -contains "*") {
        if (Test-SparseActive) {
            Write-Host "WARN: effective stacks = * (KIT_LEGACY) - sparse-checkout disable"
            if ($DryRun) { Write-Host "WOULD: git -C $HarnessRel sparse-checkout disable" }
            else { & git -C $harness sparse-checkout disable }
        }
    } elseif (Test-Path (Join-Path $root ".kit.json")) {
        if ($kitSparse) {
            $pats = @('/*', '!/stacks/*', '/stacks/*/stack.json')
            foreach ($s in $kitStacks) { $pats += "/stacks/$s/" }
            if ($DryRun) {
                Write-Host "WOULD: git -C $HarnessRel sparse-checkout set --no-cone $($pats -join ' ')"
            } else {
                & git -C $harness sparse-checkout set --no-cone @pats
            }
        } elseif (Test-SparseActive) {
            if ($DryRun) { Write-Host "WOULD: git -C $HarnessRel sparse-checkout disable" }
            else { & git -C $harness sparse-checkout disable }
        }
    }
    if ($env:KIT_LEGACY -eq "1" -and $kitSparse) {
        Write-Host 'WARN: KIT_LEGACY=1 under sparse - mode ["*"] needs all files;'
        Write-Host "      set `"sparse`": false or run git -C $HarnessRel sparse-checkout disable"
    }

    # 3) apply
    $lcmd = "apply"
    if ($DryRun) { $lcmd = "plan" }
    & $py.Source $kitLayout $lcmd $root
    if ($LASTEXITCODE -ne 0) { throw "kit-layout $lcmd failed" }

    $stack1c = (($kitStacks -contains "*") -or ($kitStacks -contains "1c"))
} else {
    Write-Host "=== link-cc-1c-skills ==="
    & (Join-Path $scripts "link-cc-1c-skills.ps1") @common -LocalManifest (Get-KitLocalManifest $root "skills")

    Write-Host "=== link-cursor-overlay ==="
    & (Join-Path $scripts "link-cursor-overlay.ps1") @common -LocalManifest (Get-KitLocalManifest $root "overlay")

    Write-Host "=== link-kit-tools ==="
    & (Join-Path $scripts "link-kit-tools.ps1") @common -LocalManifest (Get-KitLocalManifest $root "tools")

    Write-Host "=== link-editor-roots ==="
    $editor = @{ ConsumerRoot = $root }
    if ($DryRun) { $editor["DryRun"] = $true }
    & (Join-Path $scripts "link-editor-roots.ps1") @editor

    Write-Host "=== link-pi-roots ==="
    $pi = @{ ConsumerRoot = $root; HarnessRel = $HarnessRel }
    if ($DryRun) { $pi["DryRun"] = $true }
    & (Join-Path $scripts "link-pi-roots.ps1") @pi

    $stack1c = $true
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
$engine = Join-Path $harness "stacks\1c\tools\load-changed-files\load-changed-files.sh"
$thinMarker = "harness/stacks/1c/tools/load-changed-files/load-changed-files.sh"
$oldThinMarker = "harness/tools/load-changed-files/load-changed-files.sh"
$thinLines = @(
    '#!/bin/bash',
    '_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
    '# $BASH, not PATH bash: bare bash may resolve to the WSL launcher',
    '# (C:\Windows\system32\bash) - paths and localhost differ in WSL.',
    'exec "$BASH" "${_ROOT}/harness/stacks/1c/tools/load-changed-files/load-changed-files.sh" "$@"'
)

# Generate the wrapper only when stack 1c is selected - otherwise core-only
# consumers would get a 1C script they never asked for.
if ($stack1c -and (Test-Path $engine)) {
    $writeThin = $false
    if (-not (Test-Path $wrapper)) {
        $writeThin = $true
    } else {
        $text = Get-Content -LiteralPath $wrapper -Raw -ErrorAction SilentlyContinue
        if ($text -match [regex]::Escape($thinMarker)) {
            $writeThin = $false
        } elseif ($text -match [regex]::Escape($oldThinMarker)) {
            Write-Host "upgrade thin load-changed-files.sh wrapper (stacks/1c path)"
            $writeThin = $true
        } elseif ($ForceWrapper) {
            $writeThin = $true
        } else {
            Write-Host "WARN: load-changed-files.sh looks fat/legacy; pass -ForceWrapper to replace"
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
    if ($py -and (Test-Path $kitLayout)) {
        Write-Host "=== kit_layout verify ==="
        $env:HARNESS_REL = $HarnessRel
        & $py.Source $kitLayout verify $root
        if ($LASTEXITCODE -ne 0) { throw "kit-layout verify failed" }
    } else {
        Write-Host "WARN: no python on PATH - verify (kit_layout) skipped"
    }
}

if (-not $SkipDeps) {
    Write-Host "=== init-kit-deps (check) ==="
    $dep = Join-Path $scripts "init-kit-deps.ps1"
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $dep -ConsumerRoot $root
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WARN host deps incomplete - harness/core/docs/ai/kit-host-deps.md (-Install). Links still done."
    }
}

Write-Host "bootstrap-kit: Done."
