param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CommandArgs
)

$LegacyContainerName = "agent-sandbox"
$ImageName = "agent-sandbox-image"

function Normalize-WorkspacePath {
    param([string]$Path)
    $p = $Path.TrimEnd('\', '/')
    $p = $p -replace '\\', '/'
    while ($p.StartsWith('//')) { $p = $p.Substring(1) }
    if ($p -match '^/([A-Za-z])(/.*)?$') {
        $p = '/' + $Matches[1].ToLower() + $Matches[2]
    }
    elseif ($p -match '^([A-Za-z]):(/.*)?$') {
        $suffix = if ($Matches[2]) { $Matches[2] } else { '' }
        $p = '/' + $Matches[1].ToLower() + $suffix
    }
    return $p.ToLower()
}

function Get-WorkspaceContainerId {
    param([string]$WorkspaceDir)
    $norm = Normalize-WorkspacePath $WorkspaceDir
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($norm)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $hex = [BitConverter]::ToString($hash).Replace('-', '').ToLower()
    return $hex.Substring(0, 12)
}

function Test-ContainerHasMcpHost {
    param([string]$Name)
    $hosts = docker inspect $Name --format '{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}' 2>$null
    return ($hosts -match 'host\.docker\.internal')
}

function Get-MountedWorkspace {
    param([string]$Name)
    return docker inspect $Name --format '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' 2>$null
}

function Test-MountMatchesWorkspace {
    param([string]$Name, [string]$WorkspaceDir)
    $mounted = Get-MountedWorkspace $Name
    if (-not $mounted) { return $false }
    return ((Normalize-WorkspacePath $mounted) -eq (Normalize-WorkspacePath $WorkspaceDir))
}

function Remove-LegacyGlobalContainer {
    $legacy = docker ps -a --format '{{.Names}}' | Select-String -Pattern "^$LegacyContainerName`$"
    if ($legacy) {
        Write-Host "Удаляем устаревший глобальный контейнер $LegacyContainerName (изоляция per-workspace)..."
        docker rm -f $LegacyContainerName | Out-Null
    }
}

function New-SandboxContainer {
    param([string]$Name, [string]$SandboxDir, [string]$WorkspaceDir)
    docker rm -f $Name 2>$null | Out-Null
    Write-Host "Сборка и запуск контейнера $Name → $WorkspaceDir..."
    docker build -t $ImageName $SandboxDir
    docker run -d --name $Name `
        --add-host=host.docker.internal:host-gateway `
        -v "${WorkspaceDir}:/workspace" `
        $ImageName | Out-Null
}

$SandboxDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceDir = (Resolve-Path (Join-Path $SandboxDir '../..')).Path
$ContainerName = "$LegacyContainerName-$(Get-WorkspaceContainerId $WorkspaceDir)"

Remove-LegacyGlobalContainer

$isRunning = docker ps --format '{{.Names}}' | Select-String -Pattern "^$([regex]::Escape($ContainerName))`$"
if (-not $isRunning) {
    $exists = docker ps -a --format '{{.Names}}' | Select-String -Pattern "^$([regex]::Escape($ContainerName))`$"
    if ($exists) {
        if (-not (Test-ContainerHasMcpHost $ContainerName) -or -not (Test-MountMatchesWorkspace $ContainerName $WorkspaceDir)) {
            New-SandboxContainer $ContainerName $SandboxDir $WorkspaceDir
        }
        else {
            Write-Host "Запуск контейнера $ContainerName..."
            docker start $ContainerName | Out-Null
        }
    }
    else {
        New-SandboxContainer $ContainerName $SandboxDir $WorkspaceDir
    }
}
elseif (-not (Test-ContainerHasMcpHost $ContainerName) -or -not (Test-MountMatchesWorkspace $ContainerName $WorkspaceDir)) {
    New-SandboxContainer $ContainerName $SandboxDir $WorkspaceDir
}

if ($CommandArgs.Count -gt 0) {
    docker exec -w /workspace $ContainerName @CommandArgs
}
