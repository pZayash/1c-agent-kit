#Requires -Version 5.1
<#
.SYNOPSIS
  deps-check hook of stack 1c - stack-specific host deps from stack.json
  not covered by core dep_* (bsl-language-server, designer-ibcmd, answer42).
  Contract (spec "Per-stack deps-check hook"):
    env:    CONSUMER_ROOT, HARNESS_ROOT, INSTALL, STACK_DEPS (space-separated)
    cwd:    consumer root
    stdout: status lines in dep_* format (OK/WARN/FAIL)
    exit:   0 on OK and on WARN-only; != 0 -> fail in init-kit-deps
#>
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = $env:CONSUMER_ROOT
if (-not $root) { $root = (Get-Location).Path }
$harness = $env:HARNESS_ROOT
if (-not $harness) { $harness = Join-Path $root "harness" }

function Test-OnPath([string]$name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function dep_answer42 {
    if (Test-Path -LiteralPath (Join-Path $root "tools\answer42")) {
        Write-Host "OK answer42 (consumer tools/)"
    } else {
        Write-Host "WARN answer42 not linked (tools/answer42) - bootstrap-kit"
    }
}

function dep_bsl_language_server {
    $bsllsPy = $null
    foreach ($c in @("python", "python3", "py")) {
        if (Test-OnPath $c) { $bsllsPy = $c; break }
    }
    $bsllsScript = Join-Path $PSScriptRoot "tools\bsl-check\check-bsl.py"
    if (-not (Test-Path -LiteralPath $bsllsScript)) {
        $bsllsScript = Join-Path $harness "stacks\1c\tools\bsl-check\check-bsl.py"
    }
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
}

function dep_designer_ibcmd {
    if ((Test-OnPath "ibcmd") -or (Test-OnPath "designer")) {
        Write-Host "OK designer/ibcmd"
    } else {
        Write-Host "WARN designer/ibcmd not on PATH (check DESIGNER_PATH in .env)"
    }
}

$deps = @()
if ($env:STACK_DEPS) {
    $deps = @($env:STACK_DEPS -split '\s+' | Where-Object { $_ })
}
foreach ($d in $deps) {
    $fn = "dep_" + ($d -replace '-', '_')
    if (Get-Command $fn -ErrorAction SilentlyContinue) {
        & $fn
    } else {
        Write-Host "WARN unknown dep id: $d (no check function in deps-check)"
    }
}

exit 0
