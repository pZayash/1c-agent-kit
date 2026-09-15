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

    # 7. ps1 ASCII hygiene (PS 5.1 + ANSI host ParserError guard)
    $nonAscii = @(Get-ChildItem -LiteralPath $scriptsDir -Filter *.ps1 -File | Where-Object {
        ((Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match '[^\x00-\x7F]')
    })
    if ($nonAscii.Count -eq 0) {
        Write-Ok "ps1 ASCII hygiene"
    } else {
        Write-Bad "non-ASCII in $HarnessRel/scripts/*.ps1 - PS 5.1 ParserError risk: $($nonAscii.Name -join ', ')"
    }

    # 8. copy-fallback paths (tombstones blind spot: prune touches reparse only)
    . (Join-Path $scriptsDir "_win-reparse.ps1")
    $copies = @()
    $overlayLocal = @{}
    $mp = Join-Path $syncDir "local-overlay.txt"
    if (Test-Path -LiteralPath $mp) {
        Get-Content -LiteralPath $mp -Encoding UTF8 | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith("#")) { $overlayLocal[$line] = $true }
        }
    }
    foreach ($sub in @("rules", "commands")) {
        $src = Join-Path $harness "cursor\$sub"
        if (-not (Test-Path -LiteralPath $src)) { continue }
        Get-ChildItem -LiteralPath $src -File | ForEach-Object {
            if ($overlayLocal.ContainsKey($_.Name)) { return }
            $dst = Join-Path $root ".cursor\$sub\$($_.Name)"
            if ((Test-Path -LiteralPath $dst) -and -not (Test-KitReparse $dst)) {
                $copies += ".cursor\$sub\$($_.Name)"
            }
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
    $pyDst = Join-Path $root "tools\git-partial-stage.py"
    if (-not $toolsLocal.ContainsKey("git-partial-stage.py") -and
        (Test-Path -LiteralPath (Join-Path $harness "tools\git-partial-stage.py")) -and
        (Test-Path -LiteralPath $pyDst) -and -not (Test-KitReparse $pyDst)) {
        $copies += "tools\git-partial-stage.py"
    }
    if ($copies.Count -gt 0) {
        Write-WarnX "$($copies.Count) kit path(s) are copy-fallback (no symlink privilege) - prune blind; content still refreshed on bootstrap:"
        $copies | ForEach-Object { Write-Host "       $_" }
    } else {
        Write-Ok "no copy-fallback kit paths"
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
}

if ($script:Failed) {
    Write-Host "=== kit-doctor: FAIL ==="
    exit 1
}
Write-Host "=== kit-doctor: PASS ==="
exit 0
