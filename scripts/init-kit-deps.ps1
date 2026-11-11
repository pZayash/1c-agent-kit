#Requires -Version 5.1
<#
.SYNOPSIS
  Check (and optionally install) kit host PATH tools. Never openspec init / rtk init.
  Deps: core/core.json + stacks/<s>/stack.json of the stacks selected in the
  consumer .kit.json, read structurally via kit_layout.py print-config --json
  (key `deps`). Stack-specific ids without a core dep_<d> go to the stack
  hook stacks/<s>/deps-check.ps1.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsumerRoot,

    [string]$HarnessRel = "harness",

    [switch]$Install
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot "_win-reparse.ps1")

$OpenSpecPkg = "@fission-ai/openspec@1.2.0"
$fail = 0
$root = $ConsumerRoot
try { $root = (Resolve-Path $ConsumerRoot).Path } catch { $root = $ConsumerRoot }
$harness = Join-Path $root $HarnessRel

function Test-OnPath([string]$name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Sync-EnvPath {
    $machine = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

function Write-Never {
    Write-Host "NEVER: openspec init  (own openspec/ + kit skills)"
    Write-Host "NEVER: rtk init       (writes CLAUDE.md)"
    Write-Host "NEVER: rtk init -g    (Claude hook; Cursor prefixes rtk itself)"
}

function Require-Cmd([string]$name, [string]$hint) {
    if (Test-OnPath $name) {
        Write-Host "OK $name"
        return $true
    }
    Write-Host "FAIL missing: $name  ($hint)"
    $script:fail = 1
    return $false
}

# -- dep-id -> check ----------------------------------------------------

function dep_git { [void](Require-Cmd "git" "install Git for Windows") }

function dep_node {
    $nodeOk = Test-OnPath "node"
    if ($nodeOk) {
        $maj = 0
        $ver = node -v
        if ($ver -match "v(\d+)") { $maj = [int]$Matches[1] }
        if ($maj -ge 18) {
            Write-Host "OK node $ver"
        } else {
            Write-Host "FAIL node $ver (need 18+, prefer 20)"
            $script:fail = 1
            $nodeOk = $false
        }
    } else {
        Write-Host "FAIL missing: node  (winget install OpenJS.NodeJS.LTS)"
        $script:fail = 1
    }
    if ($Install -and -not $nodeOk) {
        Write-Host "install Node.js LTS via winget"
        winget install --id OpenJS.NodeJS.LTS -e --accept-package-agreements --accept-source-agreements
        Sync-EnvPath
    }
}

function dep_npm { [void](Require-Cmd "npm" "comes with node") }

function dep_openspec {
    $osOk = Test-OnPath "openspec"
    if ($osOk) {
        Write-Host "OK openspec"
    } else {
        Write-Host "FAIL missing: openspec  (npm i -g $OpenSpecPkg)"
        $script:fail = 1
    }
    if ($Install -and -not $osOk -and (Test-OnPath "npm")) {
        Write-Host "install $OpenSpecPkg"
        npm install -g $OpenSpecPkg
        Sync-EnvPath
    }
}

function dep_rtk { [void](Require-Cmd "rtk" "https://github.com/rtk-ai/rtk - install manually, any way you like") }

function dep_rg {
    $rgOk = Test-OnPath "rg"
    if ($rgOk) {
        Write-Host "OK rg"
    } else {
        Write-Host "FAIL missing: rg  (winget install BurntSushi.ripgrep.MSVC)"
        $script:fail = 1
    }
    if ($Install -and -not $rgOk) {
        winget install --id BurntSushi.ripgrep.MSVC -e --accept-package-agreements --accept-source-agreements
        Sync-EnvPath
    }
}

function dep_docker { if (Test-OnPath "docker") { Write-Host "OK docker" } else { Write-Host "WARN docker not on PATH" } }

function dep_python {
    if ((Test-OnPath "python") -or (Test-OnPath "python3") -or (Test-OnPath "py")) {
        Write-Host "OK python"
    } else {
        Write-Host "WARN python not on PATH (sandbox/host scripts)"
    }
}

function dep_qmd { if (Test-OnPath "qmd") { Write-Host "OK qmd" } else { Write-Host "WARN qmd not on PATH" } }

function dep_unzip { if (Test-OnPath "unzip") { Write-Host "OK unzip" } else { Write-Host "WARN unzip not on PATH (BSLLS download)" } }

# Dep-id dispatch (spec "Per-stack deps-check hook"): a dep_<d> function in
# this script runs once (seen-dedup across stacks); other ids collect into the
# stack's unhandled list -> one call of stacks/<s>/deps-check.ps1.
function Invoke-CoreDep([string]$id) {
    if ($seen.ContainsKey($id)) { return }
    $fn = "dep_" + ($id -replace '-', '_')
    if (Get-Command $fn -ErrorAction SilentlyContinue) {
        $seen[$id] = $true
        & $fn
    } else {
        Write-Host "WARN unknown dep id: $id (no check function)"
    }
}

# unhandled -> stack hook with env CONSUMER_ROOT/HARNESS_ROOT/INSTALL/
# STACK_DEPS, cwd = consumer root; exit != 0 -> fail. No hook -> WARN.
# "WARN unknown dep id" is NOT printed for unhandled - the hook owns them.
function Invoke-StackDeps([string]$Stack, [string[]]$Ids) {
    $unhandled = @()
    foreach ($d in $Ids) {
        $fn = "dep_" + ($d -replace '-', '_')
        if (Get-Command $fn -ErrorAction SilentlyContinue) {
            Invoke-CoreDep $d
        } else {
            $unhandled += $d
        }
    }
    if ($unhandled.Count -eq 0) { return }
    $hook = Join-Path $harness "stacks\$Stack\deps-check.ps1"
    if (Test-Path -LiteralPath $hook) {
        $env:CONSUMER_ROOT = $root
        $env:HARNESS_ROOT = $harness
        $env:INSTALL = $(if ($Install) { "1" } else { "0" })
        $env:STACK_DEPS = ($unhandled -join ' ')
        Push-Location $root
        try {
            & $hook
            if ($LASTEXITCODE -ne 0) { $script:fail = 1 }
        } finally {
            Pop-Location
        }
    } else {
        Write-Host "WARN stack ${Stack}: deps not covered by core dep_* ($($unhandled -join ' ')) and no stacks/$Stack/deps-check.ps1"
    }
}

Write-Never

# -- effective stacks ---------------------------------------------------
$stacks = @()
try {
    if ($env:KIT_LEGACY -ne "1" -and -not (Test-Path -LiteralPath (Join-Path $root ".kit.json"))) {
        Write-Host "WARN: no .kit.json - core-only (stacks: []). Create the file to select stacks."
    } else {
        $stacks = @(Get-KitEffectiveStacks $root $HarnessRel)
    }
} catch {
    Write-Host "init-kit-deps: cannot read stacks - $_"
    exit 1
}
if ($stacks -contains "*") {
    $stacks = @()
    Get-ChildItem -LiteralPath (Join-Path $harness "stacks") -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-Path -LiteralPath (Join-Path $_.FullName "stack.json")) { $stacks += $_.Name }
    }
}

Write-Host "=== check ==="
$seen = @{}

# deps registry - structural, key `deps` of print-config --json (textual JSON
# parsing is forbidden). No python -> WARN + sections skipped.
$depsRows = $null
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
$klDeps = Join-Path $harness "tools\kit-layout\kit_layout.py"
if ($py -and (Test-Path -LiteralPath $klDeps)) {
    $depsText = & $py.Source $klDeps print-config $root --harness-rel $HarnessRel --json 2>$null
    if ($LASTEXITCODE -eq 0) {
        try { $depsRows = (($depsText | Out-String) | ConvertFrom-Json).deps } catch { }
    }
}
if ($null -eq $depsRows) {
    Write-Host "WARN deps registry unread (no python / print-config) - deps sections skipped"
} else {
    Write-Host "=== deps: core ==="
    foreach ($d in @($depsRows.core)) { Invoke-CoreDep $d }
    foreach ($s in $stacks) {
        $prop = $depsRows.stacks.PSObject.Properties[$s]
        if ($null -eq $prop -or @($prop.Value).Count -eq 0) { continue }
        Write-Host "=== deps: stack $s ==="
        Invoke-StackDeps $s @($prop.Value)
    }
}

Write-Host "=== consumer ==="
$osDir = Join-Path $root "openspec"
if (Test-Path $osDir) {
    Write-Host "OK openspec/ (from git, not init)"
} else {
    Write-Host "FAIL missing: openspec/  - merge consumer branch; NEVER openspec init"
    $fail = 1
}
$envFile = Join-Path $root ".env"
if (Test-Path $envFile) {
    Write-Host "OK .env"
} else {
    Write-Host "WARN missing .env (copy .env.example)"
}

$hGit = Join-Path $root "$HarnessRel\.git"
$cGit = Join-Path $root ".git"
if ((Test-Path -LiteralPath $cGit) -and (Test-Path -LiteralPath $hGit)) {
    $cGitItem = Get-Item -LiteralPath $cGit -Force -ErrorAction SilentlyContinue
    if ($cGitItem -and -not $cGitItem.PSIsContainer) {
        $gitdirLine = Get-Content -LiteralPath $hGit -TotalCount 1 -ErrorAction SilentlyContinue
        $marker = "../.git/modules/harness"
        if (("$gitdirLine").Contains($marker)) {
            Write-Host "FAIL harness gitdir relative - run fix-harness-gitdir"
            $fail = 1
        }
    }
}

$probe = Join-Path $env:TEMP ("kit-mklink-" + [guid]::NewGuid().ToString("n"))
$probeT = "$probe-t"
$probeH = "$probe-h"
try {
    Set-Content -LiteralPath $probeT -Value "x" -Encoding ascii
    cmd /c "mklink `"$probe`" `"$probeT`"" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "OK file symlink capability (Developer Mode / SeCreateSymbolicLinkPrivilege) - kit file links will use symlinks"
    } else {
        cmd /c "mklink /H `"$probeH`" `"$probeT`"" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "OK file hardlink capability (no symlink privilege) - kit file links will use hardlinks"
        } else {
            Write-Host "WARN no file symlink/hardlink capability (cross-volume?) - kit file links will fall back to copies"
        }
    }
} catch {
    Write-Host "WARN no file symlink capability probe - kit file links will fall back to copies"
}
Write-Host "INFO actual file link modes: bash harness/scripts/kit-doctor.sh ."
Remove-Item -LiteralPath $probe, $probeT, $probeH -Force -ErrorAction SilentlyContinue

if ($Install) {
    Sync-EnvPath
    Write-Host "=== re-check after install ==="
    foreach ($c in @("node", "npm", "openspec", "rtk", "rg")) {
        if (Test-OnPath $c) { Write-Host "OK $c" } else { Write-Host "FAIL still missing: $c"; $fail = 1 }
    }
}

Write-Host "see harness/core/docs/ai/kit-host-deps.md"
if ($fail -ne 0) { exit 1 }
Write-Host "init-kit-deps: OK"
exit 0
