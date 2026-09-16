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
$syncDir = Join-Path $root "tools\cc-1c-skills-sync"

$emptyManifest = $null
function Get-Manifest([string]$name) {
    $p = Join-Path $syncDir $name
    if (Test-Path -LiteralPath $p) { return $p }
    if (-not $script:emptyManifest) {
        $script:emptyManifest = Join-Path $env:TEMP "kit-doctor-empty-manifest.txt"
        Set-Content -LiteralPath $script:emptyManifest -Value "" -Encoding ASCII
    }
    return $script:emptyManifest
}

# Run a kit ps1 as a child process; returns output lines.
function Invoke-KitScript([string]$file, [string[]]$scriptArgs) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
        (Join-Path $scriptsDir $file) @scriptArgs 2>$null
    return @($out), $LASTEXITCODE
}

Write-Host "=== kit-doctor: $root ==="

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
    # 4. verify links
    $r = Invoke-KitScript "verify-kit-links.ps1" @("-ConsumerRoot", $root)
    if ($r[1] -eq 0) {
        Write-Ok "verify-kit-links"
    } else {
        Write-Bad "verify-kit-links:"
        $r[0] | ForEach-Object { Write-Host "       $_" }
    }

    # 5. stale kit links (-DryRun prune detection; read-only)
    $stale = @()
    if (Test-Path -LiteralPath (Join-Path $harness "skills\cc-1c")) {
        $r = Invoke-KitScript "link-cc-1c-skills.ps1" @("-ConsumerRoot", $root, "-HarnessRel", $HarnessRel, "-LocalManifest", (Get-Manifest "local-skills.txt"), "-DryRun")
        $stale += $r[0] | Select-String "WOULD PRUNE:"
    }
    if (Test-Path -LiteralPath (Join-Path $harness "cursor")) {
        $r = Invoke-KitScript "link-cursor-overlay.ps1" @("-ConsumerRoot", $root, "-HarnessRel", $HarnessRel, "-LocalManifest", (Get-Manifest "local-overlay.txt"), "-DryRun")
        $stale += $r[0] | Select-String "WOULD PRUNE:"
    }
    if (Test-Path -LiteralPath (Join-Path $harness "tools")) {
        $r = Invoke-KitScript "link-kit-tools.ps1" @("-ConsumerRoot", $root, "-HarnessRel", $HarnessRel, "-LocalManifest", (Get-Manifest "local-tools.txt"), "-DryRun")
        $stale += $r[0] | Select-String "WOULD PRUNE:"
    }
    if ($stale.Count -gt 0) {
        Write-WarnX "stale kit links - run bootstrap-kit to prune:"
        $stale | ForEach-Object { Write-Host "       $($_.Line)" }
    } else {
        Write-Ok "no stale kit links"
    }

    # 6. host deps (check mode; WARN only - links already work without them)
    if (-not $SkipDeps) {
        $r = Invoke-KitScript "init-kit-deps.ps1" @("-ConsumerRoot", $root)
        if ($r[1] -eq 0) {
            Write-Ok "host deps (node / openspec / rtk)"
        } else {
            Write-WarnX "host deps incomplete - docs/ai/kit-host-deps.md (-Install to install)"
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

    # 8. file fallbacks (hardlink then copy when no symlink privilege). A fallback
    #    in sync is fine; a stale/drifted one is visible now (manifest + hash) and
    #    prune can clean orphans, unlike the old "prune blind" copy-fallback.
    . (Join-Path $scriptsDir "_win-reparse.ps1")
    $manifestPath = Join-Path $syncDir "kit-fallback.txt"
    $recorded = @{}
    if (Test-Path -LiteralPath $manifestPath) {
        Get-Content -LiteralPath $manifestPath -Encoding UTF8 | ForEach-Object {
            $line = $_.Trim()
            if (-not $line -or $line.StartsWith("#")) { return }
            $parts = $line -split "`t"
            if ($parts.Count -ge 3) {
                $recorded[$parts[0].Replace('\', '/')] = @{ source = $parts[1]; sha = $parts[2] }
            }
        }
    }
    $overlayLocal = @{}
    $mp = Join-Path $syncDir "local-overlay.txt"
    if (Test-Path -LiteralPath $mp) {
        Get-Content -LiteralPath $mp -Encoding UTF8 | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith("#")) { $overlayLocal[$line] = $true }
        }
    }
    $toolsLocal = @{}
    $mp = Join-Path $syncDir "local-tools.txt"
    if (Test-Path -LiteralPath $mp) {
        Get-Content -LiteralPath $mp -Encoding UTF8 | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith("#")) { $toolsLocal[$line] = $true }
        }
    }
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($sub in @("rules", "commands")) {
        $srcDir = Join-Path $harness "cursor\$sub"
        if (-not (Test-Path -LiteralPath $srcDir)) { continue }
        Get-ChildItem -LiteralPath $srcDir -File | ForEach-Object {
            if ($overlayLocal.ContainsKey($_.Name)) { return }
            $pairs.Add([pscustomobject]@{ rel = ".cursor/$sub/$($_.Name)"; src = $_.FullName })
        }
    }
    $pySrc = Join-Path $harness "tools\git-partial-stage.py"
    if (-not $toolsLocal.ContainsKey("git-partial-stage.py") -and (Test-Path -LiteralPath $pySrc)) {
        $pairs.Add([pscustomobject]@{ rel = "tools/git-partial-stage.py"; src = $pySrc })
    }
    $staleFallback = @()
    $inSync = 0
    $pairRels = @{}
    foreach ($p in $pairs) {
        $pairRels[$p.rel] = $true
        $dst = Join-Path $root ($p.rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $dst)) {
            $staleFallback += "$($p.rel) (fallback missing - run bootstrap-kit)"
            continue
        }
        if (Test-KitReparse $dst) { continue }
        $srcHash = Get-KitFileHash $p.src
        $dstHash = Get-KitFileHash $dst
        if ($srcHash -eq $dstHash) { $inSync++ } else {
            $staleFallback += "$($p.rel) (content differs from kit - run bootstrap-kit)"
        }
    }
    foreach ($rel in $recorded.Keys) {
        if ($pairRels.ContainsKey($rel)) { continue }
        $dst = Join-Path $root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $dst)) { continue }
        if (Test-KitReparse $dst) { continue }
        $info = $recorded[$rel]
        $srcPath = Join-Path $root ($info.source -replace '/', '\')
        if (Test-Path -LiteralPath $srcPath) { continue }
        $dstHash = Get-KitFileHash $dst
        if ($dstHash -eq $info.sha) {
            $staleFallback += "$rel (orphan: source removed upstream - bootstrap-kit will prune)"
        } else {
            $staleFallback += "$rel (orphan with local edits - kept)"
        }
    }
    if ($staleFallback.Count -gt 0) {
        Write-WarnX "$($staleFallback.Count) file fallback(s) out of sync:"
        $staleFallback | ForEach-Object { Write-Host "       $_" }
    } elseif ($inSync -gt 0) {
        Write-Ok "$inSync file fallback(s) in sync (hardlink/copy; no symlink privilege)"
    } else {
        Write-Ok "no file fallback kit paths"
    }

    # 9. SKILL.md frontmatter (idea: teamai ensureSkillFrontmatter; WARN only)
    $sfTool = Join-Path $harness "tools\skill-frontmatter\skill-frontmatter.py"
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if ($py -and (Test-Path -LiteralPath $sfTool)) {
        $sfOut = & $py.Source $sfTool lint (Join-Path $harness "skills") (Join-Path $harness "cursor\skills") 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "skill frontmatter"
        } else {
            Write-WarnX "skill frontmatter issues (fix: python harness/tools/skill-frontmatter/skill-frontmatter.py fix ...):"
            $sfOut | ForEach-Object { Write-Host "       $_" }
        }
    }

    # 10. kit links tracked in the consumer index (Windows junction traversal:
    #     git follows reparse points with core.symlinks=false and records kit
    #     content as ordinary blobs -> fresh clone gets stale copies, not links).
    $layoutTool = Join-Path $harness "tools\kit-layout\kit_layout.py"
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if ($py -and (Test-Path -LiteralPath $layoutTool)) {
        $tkOut = & $py.Source $layoutTool tracked $root --harness-rel $HarnessRel 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "no kit links tracked in consumer index"
        } else {
            Write-WarnX "kit links tracked as blobs (git follows junction; run bootstrap-kit to untrack):"
            $tkOut | Select-Object -First 20 | ForEach-Object { Write-Host "       $_" }
        }
    }
}

if ($script:Failed) {
    Write-Host "=== kit-doctor: FAIL ==="
    exit 1
}
Write-Host "=== kit-doctor: PASS ==="
exit 0
