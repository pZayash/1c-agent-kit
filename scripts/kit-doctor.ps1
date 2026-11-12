#Requires -Version 5.1
<#
.SYNOPSIS
  kit-doctor - read-only aggregated diagnostics for a kit consumer
  (idea: teamai doctor). [OK]/[WARN]/[FAIL] per check; exit 1 on any FAIL.
  Nothing on disk is modified: stale-link detection reuses link scripts
  with -DryRun. Component scripts run as child processes (they may exit).
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsumerRoot,

    [string]$HarnessRel = "harness",

    [switch]$SkipDeps
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:Failed = $false
function Write-Ok([string]$m)   { Write-Host "[OK]   $m" }
function Write-WarnX([string]$m){ Write-Host "[WARN] $m" }
function Write-Bad([string]$m)  { Write-Host "[FAIL] $m"; $script:Failed = $true }
function Write-Info([string]$m) { Write-Host "[INFO] $m" }

$root = (Resolve-Path $ConsumerRoot).Path
$harness = Join-Path $root $HarnessRel
$scriptsDir = Join-Path $harness "scripts"

# Run a kit ps1 as a child process; returns output lines.
# Bare `powershell.exe` is absent from the PATH in trimmed environments
# (agent/GUI terminals), so resolve the interpreter from $PSHOME.
$script:PsExe = Join-Path $PSHOME "powershell.exe"
if (-not (Test-Path -LiteralPath $script:PsExe)) { $script:PsExe = Join-Path $PSHOME "pwsh.exe" }

function Invoke-KitScript([string]$file, [string[]]$scriptArgs) {
    $out = & $script:PsExe -NoProfile -ExecutionPolicy Bypass -File `
        (Join-Path $scriptsDir $file) @scriptArgs 2>$null
    return @($out), $LASTEXITCODE
}

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
$kitLayout = Join-Path $harness "tools\kit-layout\kit_layout.py"
$kitStacks = @()

Write-Host "=== kit-doctor: $root ==="

# Consumer config - only via the engine (the single .kit.json parser).
if ($py -and (Test-Path -LiteralPath $kitLayout)) {
    $cfgText = & $py.Source $kitLayout print-config $root --harness-rel $HarnessRel --json 2>$null
    if ($LASTEXITCODE -eq 0) {
        ($cfgText | Out-String).Trim() -split "`n" | ForEach-Object { Write-Host "  $_" }
        try {
            $cfg = ($cfgText | Out-String) | ConvertFrom-Json
            if ($null -ne $cfg.stacks) { $kitStacks = @($cfg.stacks) }
            elseif ($null -ne $cfg.effective_stacks) { $kitStacks = @($cfg.effective_stacks) }
        } catch { }
    } else {
        Write-WarnX "print-config failed"
    }
} else {
    Write-Info "no python / kit_layout.py - print-config skipped"
}

# 0. namespace: links created in another namespace (moved tree / another OS)
#    cannot be diagnosed here - verify/fallback checks would be meaningless.
$foreignNs = 0
$reparseLib = Join-Path $scriptsDir "_win-reparse.ps1"
if (Test-Path -LiteralPath $reparseLib) {
    . $reparseLib
    $nsCandidates = @(
        ".agents\skills", ".claude\skills", ".claude\commands",
        ".pi\skills", ".pi\prompts", ".pi\extensions"
    )
    # Dynamic reparse scan - new stack kit-tools without a list edit.
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
        $foreignNs = 1
        Write-Bad "foreign namespace: $($foreignLinks.Count) kit link(s) point outside $root (moved tree / another OS)"
        $foreignLinks | Select-Object -First 3 | ForEach-Object { Write-Host "       $_" }
        Write-Info "run on the host that created the layout (Git Bash / PowerShell)"
    }
}

# 1. harness presence + gitlink (logic: hooks/pre-commit-harness)
if (-not (Test-Path -LiteralPath $harness)) {
    Write-Bad "missing $HarnessRel/ (git submodule update --init?)"
} else {
    $mode = (& git -C $root ls-files -s -- $HarnessRel 2>$null |
             ForEach-Object { ($_ -split '\s+')[0] } | Select-Object -First 1)
    if ($mode -eq "160000") {
        Write-Ok "$HarnessRel is gitlink 160000"
    } elseif (-not $mode) {
        Write-WarnX "$HarnessRel not in index (untracked copy blocks merge - rm -rf before merging gitlink)"
    } else {
        Write-Bad "$HarnessRel staged as blobs (mode $mode) - must be submodule, see hooks/pre-commit-harness"
    }
}

# 2. harness git alive (worktree file-gitdir pitfall)
if (Test-Path -LiteralPath $harness) {
    $sha = (& git -C $harness rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $sha) {
        Write-Ok "harness git alive (HEAD $sha)"
        & git -C $harness rev-parse --verify -q origin/master 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & git -C $harness merge-base --is-ancestor HEAD origin/master 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Info "harness HEAD is ancestor of local origin/master"
            } else {
                Write-WarnX "harness HEAD not on local origin/master (pinned SHA or stale refs, offline-safe check)"
            }
        }
    } else {
        Write-Bad "git -C $HarnessRel broken (worktree file-gitdir?) - run fix-harness-gitdir"
    }

    # 2b. gitlink vs HEAD drift (' M harness')
    $recorded = (& git -C $root ls-files -s -- $HarnessRel 2>$null | ForEach-Object { ($_ -split '\s+')[1] } | Select-Object -First 1)
    $full = (& git -C $harness rev-parse HEAD 2>$null)
    if ($recorded -and $full) {
        if ($recorded -ne $full) {
            Write-WarnX "harness HEAD ($($full.Substring(0,7))) != recorded gitlink ($($recorded.Substring(0,7))) - ' M harness'; submodule update or bump gitlink"
        } else {
            Write-Ok "harness HEAD matches recorded gitlink"
        }
    }

    # 2c. harness working tree dirty: with hardlink fallback a consumer edit to a
    #     kit-owned file lands in harness/ and is otherwise invisible here.
    $hfDirty = @(& git -C $harness status --porcelain -uno 2>$null)
    if ($hfDirty.Count -gt 0) {
        Write-WarnX "harness working tree dirty ($($hfDirty.Count) tracked file(s)) - hardlink fallback edit? git -C $HarnessRel status"
    } else {
        Write-Ok "harness working tree clean"
    }
}

# 3. parent git alive
& git -C $root status --porcelain 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Ok "parent git status"
} else {
    Write-Bad "parent git status fails - check $HarnessRel/.git gitdir (fix-harness-gitdir)"
}

if (Test-Path -LiteralPath $harness) {
    # 4. verify links (engine, plan filtered by effective stacks)
    if ($foreignNs -eq 1) {
        Write-Info "kit_layout verify skipped (foreign namespace; see check 0)"
    } elseif (-not $py -or -not (Test-Path -LiteralPath $kitLayout)) {
        Write-Info "verify skipped (no python / kit_layout.py)"
    } else {
        $vOut = & $py.Source $kitLayout verify $root --harness-rel $HarnessRel 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "kit_layout verify"
        } else {
            Write-Bad "kit_layout verify:"
            $vOut | ForEach-Object { Write-Host "       $_" }
        }
    }

    # 5+8. stale kit links and fallback drift - engine plan (pending actions).
    #      Replaces -DryRun link-* and the old SYNC_DIR manifest reads.
    if ($foreignNs -eq 1) {
        Write-Info "kit_layout plan skipped (foreign namespace; see check 0)"
    } elseif ($py -and (Test-Path -LiteralPath $kitLayout)) {
        $pOut = & $py.Source $kitLayout plan $root --harness-rel $HarnessRel 2>&1
        if ($LASTEXITCODE -eq 0) {
            $pending = @($pOut | Select-String -CaseSensitive 'WOULD|PENDING|PRUNE|REMOVE|REPLACE|stale|drift|orphan|fallback')
            if ($pending.Count -gt 0) {
                Write-WarnX "layout pending actions ($($pending.Count)) - run bootstrap-kit:"
                $pending | Select-Object -First 15 | ForEach-Object { Write-Host "       $($_.Line)" }
            } else {
                Write-Ok "layout in sync (plan: no pending actions)"
            }
        } else {
            Write-Bad "kit_layout plan failed:"
            $pOut | Select-Object -First 20 | ForEach-Object { Write-Host "       $_" }
        }
    }

    # 6. host deps (check mode; WARN only - links already work without them).
    #    Sectioned: core always, selected stacks via init-kit-deps.
    if (-not $SkipDeps) {
        $r = Invoke-KitScript "init-kit-deps.ps1" @("-ConsumerRoot", $root)
        if ($r[1] -eq 0) {
            Write-Ok "host deps"
        } else {
            Write-WarnX "host deps incomplete - core/docs/ai/kit-host-deps.md (-Install to install)"
        }
        $allStacks = @()
        Get-ChildItem -LiteralPath (Join-Path $harness "stacks") -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-Path -LiteralPath (Join-Path $_.FullName "stack.json")) { $allStacks += $_.Name }
        }
        $skipped = @($allStacks | Where-Object { ($kitStacks -notcontains "*") -and ($kitStacks -notcontains $_) })
        if ($skipped.Count -gt 0) {
            Write-Info "host deps SKIP stack(s): $($skipped -join ', ') (not selected in .kit.json)"
        }
    }

    # 7. ps1 encoding hygiene (BOM-less ps1 must be ASCII: PS 5.1 ParserError guard)
    $nonAscii = @(Get-ChildItem -LiteralPath $harness -Filter *.ps1 -File -Recurse | Where-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        -not $hasBom -and ((Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match '[^\x00-\x7F]')
    })
    if ($nonAscii.Count -eq 0) {
        Write-Ok "ps1 encoding hygiene"
    } else {
        $rel = $nonAscii.FullName | ForEach-Object { $_.Substring($harness.Length + 1) }
        Write-Bad "non-ASCII in BOM-less *.ps1 - PS 5.1 ParserError risk: $($rel -join ', ')"
    }

    # 8. (removed) - fallback drift is covered by engine plan (check 5+8)
    #    and verify (check 4); orphans are swept by apply.

    # 9. SKILL.md frontmatter (idea: teamai ensureSkillFrontmatter; WARN only).
    #    Paths: core/cursor/skills + stacks/*/cursor/skills + stacks/*/skills.
    $sfTool = Join-Path $harness "tools\skill-frontmatter\skill-frontmatter.py"
    if ($py -and (Test-Path -LiteralPath $sfTool)) {
        $sfDirs = @()
        $coreSkills = Join-Path $harness "core\cursor\skills"
        if (Test-Path -LiteralPath $coreSkills) { $sfDirs += $coreSkills }
        Get-ChildItem -LiteralPath (Join-Path $harness "stacks") -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $d1 = Join-Path $_.FullName "cursor\skills"
            $d2 = Join-Path $_.FullName "skills"
            if (Test-Path -LiteralPath $d1) { $sfDirs += $d1 }
            if (Test-Path -LiteralPath $d2) { $sfDirs += $d2 }
        }
        if ($sfDirs.Count -eq 0) {
            Write-Info "skill frontmatter: no skill dirs found"
        } else {
            $sfOut = & $py.Source $sfTool lint @sfDirs 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "skill frontmatter"
            } else {
                Write-WarnX "skill frontmatter issues (fix: python harness/tools/skill-frontmatter/skill-frontmatter.py fix ...):"
                $sfOut | ForEach-Object { Write-Host "       $_" }
            }
        }
    }

    # 9b. kit-lint suite (WARN only in doctor; in kit CI these are gates):
    #     core purity, cross-layer links, stack structural rules.
    if ($py) {
        foreach ($chk in @("check_core_purity.py", "check_cross_layer_links.py", "kit_lint.py")) {
            $script = Join-Path $harness "tools\kit-lint\$chk"
            if (-not (Test-Path -LiteralPath $script)) { continue }
            $cOut = & $py.Source $script $harness 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "kit-lint $($chk -replace '\.py$','')"
            } else {
                Write-WarnX "kit-lint $($chk -replace '\.py$',''):"
                $cOut | Select-Object -First 15 | ForEach-Object { Write-Host "       $_" }
            }
        }
    }

    # 10. kit links tracked in the consumer index (Windows junction traversal:
    #     git follows reparse points with core.symlinks=false and records kit
    #     content as ordinary blobs -> fresh clone gets stale copies, not links).
    if ($py -and (Test-Path -LiteralPath $kitLayout)) {
        $tkOut = & $py.Source $kitLayout tracked $root --harness-rel $HarnessRel 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "no kit links tracked in consumer index"
        } else {
            Write-WarnX "kit links tracked as blobs (git follows junction; run bootstrap-kit to untrack):"
            $tkOut | Select-Object -First 20 | ForEach-Object { Write-Host "       $_" }
        }
    }

    # 11. .gitignore hygiene: hand-written paths now covered by the managed block
    #     (the block is regenerated, the hand lines are dead weight).
    $gi = Join-Path $root ".gitignore"
    if (Test-Path -LiteralPath $gi) {
        $managedKeys = @{}
        $handKeys = @{}
        $inManaged = $false
        foreach ($line in (Get-Content -LiteralPath $gi -Encoding UTF8)) {
            $s = "$line".Trim()
            if ($s -eq "# >>> kit-managed: begin (bootstrap-kit) >>>") { $inManaged = $true; continue }
            if ($s -eq "# <<< kit-managed: end <<<") { $inManaged = $false; continue }
            $entry = ($line -split '#', 2)[0].Trim()
            if (-not $entry) { continue }
            $key = $entry.TrimStart('/').TrimEnd('/')
            if ($inManaged) { $managedKeys[$key] = $true } else { $handKeys[$key] = $true }
        }
        $overlap = @($handKeys.Keys | Where-Object { $managedKeys.ContainsKey($_) } | Sort-Object)
        if ($overlap.Count -gt 0) {
            Write-WarnX "$($overlap.Count) hand-written .gitignore line(s) duplicate the kit-managed block (remove them):"
            $overlap | Select-Object -First 5 | ForEach-Object { Write-Host "       $_" }
        }
    }

    # 12. answer42 freshness (optional tool; WARN only). Freshness matters:
    #     before 0.5.13 the HTTP service never ran the orphan reaper, so busy
    #     session_id values were not released. PyPI request is bounded by the
    #     timeout inside version_check.py.
    $a42Script = Join-Path $root "tools\answer42\answer42.ps1"
    if (Test-Path -LiteralPath $a42Script) {
        $a42Out = & $script:PsExe -NoProfile -ExecutionPolicy Bypass -File $a42Script -Action check -Root $root 2>$null
        $a42Code = $LASTEXITCODE
        $a42Fields = @{}
        foreach ($a42Line in @($a42Out)) {
            if ("$a42Line" -match '^([a-z_]+):\s*(.*)$') { $a42Fields[$Matches[1]] = $Matches[2] }
        }
        if ($a42Code -eq 0) {
            Write-Ok "answer42 $($a42Fields['installed']) (latest $($a42Fields['latest']))"
        } elseif ($a42Code -eq 1) {
            Write-WarnX "answer42 outdated: installed $($a42Fields['installed']) -> latest $($a42Fields['latest']) ($($a42Fields['channel'])) - answer42.ps1 install|update"
        } else {
            Write-Info "answer42: version unknown (not installed / offline)"
        }
    }
}

if ($script:Failed) {
    Write-Host "=== kit-doctor: FAIL ==="
    exit 1
}
Write-Host "=== kit-doctor: PASS ==="
exit 0
