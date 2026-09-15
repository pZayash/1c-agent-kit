#Requires -Version 5.1
<#
.SYNOPSIS
  Check (and optionally install) kit host PATH tools. Never openspec init / rtk init.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsumerRoot,

    [switch]$Install
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$OpenSpecPkg = "@fission-ai/openspec@1.2.0"
$fail = 0
$root = $ConsumerRoot
try { $root = (Resolve-Path $ConsumerRoot).Path } catch { $root = $ConsumerRoot }

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

Write-Never
Write-Host "=== check ==="

[void](Require-Cmd "git" "install Git for Windows")

$nodeOk = Test-OnPath "node"
if ($nodeOk) {
    $maj = 0
    $ver = node -v
    if ($ver -match "v(\d+)") { $maj = [int]$Matches[1] }
    if ($maj -ge 18) {
        Write-Host "OK node $ver"
    } else {
        Write-Host "FAIL node $ver (need 18+, prefer 20)"
        $fail = 1
        $nodeOk = $false
    }
} else {
    Write-Host "FAIL missing: node  (winget install OpenJS.NodeJS.LTS)"
    $fail = 1
}

if ($Install -and -not $nodeOk) {
    Write-Host "install Node.js LTS via winget"
    winget install --id OpenJS.NodeJS.LTS -e --accept-package-agreements --accept-source-agreements
    Sync-EnvPath
}

if (-not (Test-OnPath "npm")) {
    Write-Host "FAIL missing: npm"
    $fail = 1
} else {
    Write-Host "OK npm"
}

$osOk = Test-OnPath "openspec"
if ($osOk) {
    Write-Host "OK openspec"
} else {
    Write-Host "FAIL missing: openspec  (npm i -g $OpenSpecPkg)"
    $fail = 1
}
if ($Install -and -not $osOk -and (Test-OnPath "npm")) {
    Write-Host "install $OpenSpecPkg"
    npm install -g $OpenSpecPkg
    Sync-EnvPath
}

$rtkOk = Test-OnPath "rtk"
if ($rtkOk) {
    Write-Host "OK rtk"
} else {
    Write-Host "FAIL missing: rtk  (https://github.com/rtk-ai/rtk - install manually, any way you like)"
    $fail = 1
}

$rgOk = Test-OnPath "rg"
if ($rgOk) {
    Write-Host "OK rg"
} else {
    Write-Host "FAIL missing: rg  (winget install BurntSushi.ripgrep.MSVC)"
    $fail = 1
}
if ($Install -and -not $rgOk) {
    winget install --id BurntSushi.ripgrep.MSVC -e --accept-package-agreements --accept-source-agreements
    Sync-EnvPath
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

$hGit = Join-Path $root "harness\.git"
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

$hasPy = (Test-OnPath "python") -or (Test-OnPath "python3") -or (Test-OnPath "py")
if ($hasPy) { Write-Host "OK python" } else { Write-Host "WARN python not on PATH (sandbox/host scripts)" }
if (Test-OnPath "qmd") { Write-Host "OK qmd" } else { Write-Host "WARN qmd not on PATH" }
if (Test-OnPath "docker") { Write-Host "OK docker" } else { Write-Host "WARN docker not on PATH" }

$bsllsPy = $null
foreach ($c in @("python", "python3", "py")) {
    if (Test-OnPath $c) { $bsllsPy = $c; break }
}
$bsllsScript = Join-Path $root "harness\tools\bsl-check\check-bsl.py"
if (-not (Test-Path -LiteralPath $bsllsScript)) {
    $bsllsScript = Join-Path $root "tools\bsl-check\check-bsl.py"
}
if (-not $bsllsPy) {
    Write-Host "WARN BSLLS: no python to run check-bsl.py --which"
} elseif (-not (Test-Path -LiteralPath $bsllsScript)) {
    Write-Host "WARN BSLLS: check-bsl.py missing"
} else {
    $bsllsOut = & $bsllsPy $bsllsScript --which 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Write-Host "OK BSLLS $($bsllsOut.Trim())"
    } else {
        Write-Host "WARN BSLLS runtime missing"
        Write-Host $bsllsOut.TrimEnd()
    }
}

$probe = Join-Path $env:TEMP ("kit-mklink-" + [guid]::NewGuid().ToString("n"))
$probeT = "$probe-t"
try {
    Set-Content -LiteralPath $probeT -Value "x" -Encoding ascii
    cmd /c "mklink `"$probe`" `"$probeT`"" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "OK file mklink (Developer Mode)"
    } else {
        Write-Host "WARN no file mklink - rules .mdc will copy-fallback"
    }
} catch {
    Write-Host "WARN no file mklink - rules .mdc will copy-fallback"
}
Remove-Item -LiteralPath $probe, $probeT -Force -ErrorAction SilentlyContinue

if ($Install) {
    Sync-EnvPath
    Write-Host "=== re-check after install ==="
    foreach ($c in @("node", "npm", "openspec", "rtk", "rg")) {
        if (Test-OnPath $c) { Write-Host "OK $c" } else { Write-Host "FAIL still missing: $c"; $fail = 1 }
    }
}

Write-Host "see harness/docs/ai/kit-host-deps.md"
if ($fail -ne 0) { exit 1 }
Write-Host "init-kit-deps: OK"
exit 0
