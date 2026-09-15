# Shared Windows reparse helpers for kit link scripts.
# Dot-source: . (Join-Path $PSScriptRoot '_win-reparse.ps1')

function Test-KitReparse([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $item = Get-Item -LiteralPath $path -Force
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
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
