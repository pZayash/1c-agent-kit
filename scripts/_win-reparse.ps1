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
