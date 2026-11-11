# Shared Windows reparse helpers for kit link scripts.
# Dot-source: . (Join-Path $PSScriptRoot '_win-reparse.ps1')

function Test-KitReparse([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $item = Get-Item -LiteralPath $path -Force
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

# Raw target of a reparse point (junction/symlink), or $null. Works in
# PS 5.1 where Get-Item exposes .Target (LinkTarget is PS 6+).
function Get-KitReparseTarget([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
    if ($item.PSObject.Properties['Target'] -and $item.Target) { return @($item.Target)[0] }
    if ($item.PSObject.Properties['LinkTarget'] -and $item.LinkTarget) { return @($item.LinkTarget)[0] }
    return $null
}

# True when the reparse target lies outside the consumer root (link created in
# another namespace or the consumer tree was moved).
function Test-KitForeignLink([string]$Root, [string]$Path) {
    $target = Get-KitReparseTarget $Path
    if (-not $target) { return $false }
    $full = $target
    if (-not [System.IO.Path]::IsPathRooted($full)) {
        $full = Join-Path (Split-Path $Path -Parent) $full
    }
    $rootFull = $Root.TrimEnd('\', '/') + '\'
    $full = $full.TrimEnd('\', '/') + '\'
    return -not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-KitReparseOrTree([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $item = Get-Item -LiteralPath $path -Force
    $isReparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if ($isReparse) {
        if ($item.PSIsContainer) {
            cmd /c "rmdir `"$path`""
        } else {
            cmd /c "del `"$path`""
        }
        if ($LASTEXITCODE -ne 0) {
            throw "failed to remove reparse: $path"
        }
        return
    }
    if ($item.PSIsContainer) {
        Remove-Item -LiteralPath $path -Recurse -Force
    } else {
        Remove-Item -LiteralPath $path -Force
    }
}

# Tombstones (idea: teamai .removed) - prune stale kit-owned links.
# Removes reparse points in $LinkRoot that point into $KitSource but whose name
# no longer exists in $KitSource (skill/tool removed or renamed upstream).
# Local copies and foreign links are kept; fallback copies are not reparse
# points, so they are never touched.
function Remove-KitStaleLinks {
    param(
        [Parameter(Mandatory = $true)][string]$LinkRoot,
        [Parameter(Mandatory = $true)][string]$KitSource,
        [hashtable]$Local = @{},
        [switch]$DryRun
    )
    if (-not (Test-Path -LiteralPath $LinkRoot)) { return }
    $prefix = $KitSource.TrimEnd('\', '/') + '\'
    Get-ChildItem -LiteralPath $LinkRoot -Force | ForEach-Object {
        $name = $_.Name
        if ($Local.ContainsKey($name)) { return }
        if (-not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
        $target = $null
        if ($_.PSObject.Properties['Target'] -and $_.Target) { $target = @($_.Target)[0] }
        elseif ($_.PSObject.Properties['LinkTarget'] -and $_.LinkTarget) { $target = @($_.LinkTarget)[0] }
        if (-not $target) { return }
        if (-not ($target.TrimEnd('\', '/') + '\').StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return }
        if (-not (Test-Path -LiteralPath (Join-Path $KitSource $name))) {
            if ($DryRun) {
                Write-Host "WOULD PRUNE: $name"
                return
            }
            Write-Host "PRUNE: $name"
            Remove-KitReparseOrTree $_.FullName
        }
    }
}

# -- file fallback (hardlink/copy) helpers ------------------------------
# File symlinks need Developer Mode / SeCreateSymbolicLinkPrivilege. When that
# is unavailable a hardlink is tried first (no privilege, same volume), then a
# copy. Fallbacks are recorded in a manifest so tombstones can prune them and
# kit-doctor can detect drift (the old "prune blind" copy-fallback).

function Get-KitFileHash([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return "" }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try {
            $bytes = $sha.ComputeHash($fs)
            return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLower()
        } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

function Test-KitFileEqual([string]$a, [string]$b) {
    if (-not (Test-Path -LiteralPath $a) -or -not (Test-Path -LiteralPath $b)) { return $false }
    if ((Get-Item -LiteralPath $a).Length -ne (Get-Item -LiteralPath $b).Length) { return $false }
    return ((Get-KitFileHash $a) -eq (Get-KitFileHash $b))
}

function New-KitFileLink([string]$target, [string]$link) {
    cmd /c "mklink `"$link`" `"$target`"" | Out-Null
    if ($LASTEXITCODE -eq 0) { return 'FILELINK' }
    cmd /c "mklink /H `"$link`" `"$target`"" | Out-Null
    if ($LASTEXITCODE -eq 0) { return 'HARDLINK' }
    Copy-Item -LiteralPath $target -Destination $link -Force
    return 'COPY'
}

function Test-KitSymlinkPossible {
    # Can a file symlink be created (Developer Mode / SeCreateSymbolicLinkPrivilege)?
    # Probes %TEMP% only; used by kit-doctor to hint that in-sync hardlink/copy
    # fallbacks can now be upgraded to symlinks by bootstrap-kit.
    $base = Join-Path $env:TEMP ("kit-symprobe-" + [guid]::NewGuid().ToString('N'))
    $target = "$base.t"
    $link = "$base.l"
    try {
        Set-Content -LiteralPath $target -Value "probe" -Encoding ASCII
        cmd /c "mklink `"$link`" `"$target`"" 2>&1 | Out-Null
        return (Test-Path -LiteralPath $link)
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $target, $link -Force -ErrorAction SilentlyContinue
    }
}

function Write-KitTextFile([string]$path, [string]$text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text, $enc)
}

function Get-KitFallbackManifestPath([string]$Root) {
    return (Join-Path $Root ".kit\fallback.txt")
}

function Read-KitFallbackManifest([string]$Root) {
    $map = @{}
    $p = Get-KitFallbackManifestPath $Root
    if (-not (Test-Path -LiteralPath $p)) {
        # Legacy location (pre-.kit layout); read-only migration fallback.
        $p = Join-Path $Root "tools\cc-1c-skills-sync\kit-fallback.txt"
        if (-not (Test-Path -LiteralPath $p)) { return $map }
    }
    Get-Content -LiteralPath $p -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) { return }
        $parts = $line -split "`t"
        if ($parts.Count -ge 3) {
            $map[$parts[0].Replace('\', '/')] = @{ source = $parts[1]; sha = $parts[2] }
        }
    }
    return $map
}

function Save-KitFallbackManifest([string]$Root, [hashtable]$Map) {
    $p = Get-KitFallbackManifestPath $Root
    $dir = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lines = @(
        '# kit fallback manifest (generated). Format:',
        '# consumer-rel<TAB>kit-source-consumer-rel<TAB>sha256'
    )
    foreach ($rel in ($Map.Keys | Sort-Object)) {
        $e = $Map[$rel]
        $lines += ("{0}`t{1}`t{2}" -f $rel, $e.source, $e.sha)
    }
    Write-KitTextFile $p (($lines -join "`n") + "`n")
}

function Set-KitFallbackEntry {
    param([hashtable]$Map, [string]$Rel, [string]$Source, [string]$Sha)
    $Map[$Rel.Replace('\', '/')] = @{ source = $Source.Replace('\', '/'); sha = $Sha }
}

function Remove-KitStaleFallback {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][hashtable]$Map,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [switch]$DryRun
    )
    foreach ($rel in @($Map.Keys)) {
        if (-not $rel.StartsWith($Prefix)) { continue }
        $path = Join-Path $Root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path)) { $Map.Remove($rel); continue }
        if (Test-KitReparse $path) { $Map.Remove($rel); continue }
        $rec = $Map[$rel]
        $src = Join-Path $Root ($rec.source -replace '/', '\')
        if (Test-Path -LiteralPath $src) { continue }
        if ((Get-KitFileHash $path) -eq $rec.sha) {
            if ($DryRun) { Write-Host "WOULD PRUNE (fallback): $rel" }
            else { Write-Host "PRUNE (fallback): $rel"; Remove-Item -LiteralPath $path -Force }
            $Map.Remove($rel)
        } else {
            Write-Host "WARN stale fallback has local edits, kept: $rel"
        }
    }
}

function Update-KitGitignore {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$Id,
        [switch]$DryRun
    )
    if ($DryRun) { return }
    $begin = "# >>> kit-managed: $Id (bootstrap-kit) >>>"
    $end = "# <<< kit-managed: $Id <<<"
    $p = Join-Path $Root ".gitignore"
    $lines = @()
    if (Test-Path -LiteralPath $p) { $lines = @(Get-Content -LiteralPath $p -Encoding UTF8) }
    $kept = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in $lines) {
        $s = "$line".Trim()
        if ($s -eq $begin) { $skip = $true; continue }
        if ($s -eq $end) { $skip = $false; continue }
        if (-not $skip) { [void]$kept.Add($line) }
    }
    while ($kept.Count -gt 0 -and -not "$($kept[$kept.Count - 1])".Trim()) { $kept.RemoveAt($kept.Count - 1) }
    $entries = @($Paths | ForEach-Object { '/' + $_.Replace('\', '/') } | Sort-Object -Unique)
    $entries += '/.kit/fallback.txt'
    $entries += '/.kit/lock'
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $kept) { [void]$out.Add($l) }
    if ($kept.Count -gt 0) { [void]$out.Add("") }
    [void]$out.Add($begin)
    foreach ($e in $entries) { [void]$out.Add($e) }
    [void]$out.Add($end)
    Write-KitTextFile $p (($out -join "`n") + "`n")
}

# -- .kit.json / stacks --------------------------------------------------
# The single .kit.json parser is kit_layout.py print-config --json.
# Scripts never read .kit.json themselves.

# Returns effective stacks as a string array ("*" = all), or $null when no
# .kit.json exists (legacy mode for link-*). Throws when .kit.json exists
# but cannot be read (no python / print-config failure) - explicit refusal.
function Get-KitEffectiveStacks([string]$Root, [string]$HarnessRel = "harness") {
    if ($env:KIT_LEGACY -eq "1") {
        Write-Host "WARN: KIT_LEGACY=1 - effective stacks = all (env beats .kit.json)"
        return @("*")
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root ".kit.json"))) { return }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $py) {
        throw ".kit.json found but python not on PATH - cannot read stacks (install python or remove .kit.json)"
    }
    $kl = Join-Path $Root "$HarnessRel\tools\kit-layout\kit_layout.py"
    $cfgText = & $py.Source $kl print-config $Root --harness-rel $HarnessRel --json
    if ($LASTEXITCODE -ne 0) { throw "kit_layout.py print-config failed ($Root)" }
    $cfg = ($cfgText | Out-String) | ConvertFrom-Json
    $s = $cfg.stacks
    if ($null -eq $s) { $s = $cfg.effective_stacks }
    # enumerated output: caller's @() collects flat list or empty -
    # ,@($s) would nest and yield phantom "stacks\\stack.json" entries.
    return @($s)
}

# $true when the stack is selected for the consumer (or legacy mode with no
# .kit.json). Throws on unreadable config (explicit refusal).
function Test-KitStackSelected([string]$Root, [string]$Stack, [string]$HarnessRel = "harness") {
    if ($env:KIT_LEGACY -eq "1") { return $true }
    if (-not (Test-Path -LiteralPath (Join-Path $Root ".kit.json"))) { return $true }
    $s = @(Get-KitEffectiveStacks $Root $HarnessRel)
    return (($s -contains "*") -or ($s -contains $Stack))
}

# Absolute path of the local manifest (.kit/local-<name>.txt preferred,
# legacy tools/cc-1c-skills-sync/local-<name>.txt on migration).
function Get-KitLocalManifest([string]$Root, [string]$Name) {
    $p = Join-Path $Root ".kit\local-$Name.txt"
    if (Test-Path -LiteralPath $p) { return $p }
    $legacy = Join-Path $Root "tools\cc-1c-skills-sync\local-$Name.txt"
    if (Test-Path -LiteralPath $legacy) { return $legacy }
    return $p
}
