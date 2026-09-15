# Answer42 (UI-driver MCP для 1С) — установка и HTTP-режим.
#
# Запускать из интерактивной desktop-сессии пользователя (Answer42 поднимает
# окна 1cv8c), не из службы и не из заблокированного RDP.
#
# Примеры:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 install
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 start
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 status
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 stop
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 smoke
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("install", "start", "stop", "restart", "status", "smoke", "update")]
    [string]$Action = "status",

    # update: ref upstream для ребейза (тег или ветка); пусто = новейший тег
    [string]$Ref = "",
    # update: запушить ветку в origin (--force-with-lease) и перезапустить сервис
    [switch]$Push,
    [switch]$RestartService,

    # Корень проекта-потребителя. По умолчанию ищется вверх от скрипта.
    [string]$Root
)

$ErrorActionPreference = "Stop"

function Find-ProjectRoot {
    param([string]$Start)
    $dir = Get-Item -LiteralPath $Start
    for ($i = 0; $i -lt 6 -and $dir; $i++) {
        if (Test-Path -LiteralPath (Join-Path $dir.FullName ".env.example")) {
            return $dir.FullName
        }
        $dir = $dir.Parent
    }
    throw "Не найден корень проекта (.env.example) выше $Start. Передайте -Root."
}

function Read-DotEnv {
    param([string]$Path)
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $values }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#") -or -not $trimmed.Contains("=")) { continue }
        # PS 5.1: без String.Partition (появился только в .NET Core)
        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -lt 2) { continue }
        $key = $parts[0].Trim()
        $value = $parts[1].Trim().Trim('"').Trim("'")
        $values[$key] = $value
    }
    return $values
}

if (-not $Root) { $Root = Find-ProjectRoot -Start $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path

$stateDir = Join-Path $Root ".tmp\answer42"
$pidFile = Join-Path $stateDir "http.pid"
$outLog = Join-Path $stateDir "http.out.log"
$errLog = Join-Path $stateDir "http.err.log"
$venvDir = Join-Path $Root ".venv-answer42"
$answer42Exe = Join-Path $venvDir "Scripts\answer42.exe"
$smokeScript = Join-Path $PSScriptRoot "smoke.py"

function Get-Config {
    $envValues = Read-DotEnv -Path (Join-Path $Root ".env")
    $exampleValues = Read-DotEnv -Path (Join-Path $Root ".env.example")
    $get = {
        param($key, $default)
        if ($envValues.ContainsKey($key) -and $envValues[$key]) { return $envValues[$key] }
        if ($exampleValues.ContainsKey($key) -and $exampleValues[$key]) { return $exampleValues[$key] }
        return $default
    }
    $mcpUrl = & $get "ANSWER42_MCP_URL" "http://127.0.0.1:9010/mcp"
    $port = "9010"
    if ($mcpUrl -match ":(\d+)/") { $port = $Matches[1] }
    return [pscustomobject]@{
        Url       = $mcpUrl
        Port      = $port
        AccountId = & $get "ANSWER42_ACCOUNT_ID" "answer42"
        Token     = & $get "ANSWER42_TOKEN" ""
        ExtraArgs = & $get "ANSWER42_EXTRA_ARGS" ""
        Bin       = & $get "ANSWER42_BIN" $answer42Exe
        # Форк-сборка: чекаут, ветка с патчами и удалённые репозитории
        ForkDir    = & $get "ANSWER42_FORK_DIR" ""
        ForkBranch = & $get "ANSWER42_FORK_BRANCH" "fork-patches"
        ForkRemote = & $get "ANSWER42_FORK_REMOTE" "upstream"
        PushRemote = & $get "ANSWER42_FORK_PUSH_REMOTE" "origin"
    }
}

function Invoke-Answer42Python {
    param([string[]]$Arguments)
    $python = Join-Path $venvDir "Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $python)) {
        throw "Нет venv Answer42: $venvDir. Сначала: answer42.ps1 install"
    }
    & $python @Arguments
    if ($LASTEXITCODE -ne 0) { throw "python завершился с кодом $LASTEXITCODE" }
}

function Invoke-GitStep {
    param([string]$Dir, [string[]]$GitArgs, [switch]$AllowFail)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & git -C $Dir @GitArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($code -ne 0) {
        if ($AllowFail) { return [pscustomobject]@{ Ok = $false; Code = $code; Output = ($output -join "`n") } }
        throw "git $($GitArgs -join ' ') → код $code`n$($output -join "`n")"
    }
    return [pscustomobject]@{ Ok = $true; Code = 0; Output = ($output -join "`n") }
}

# Обновление форк-сборки: подтянуть релизы upstream, ребейзнуть ветку с патчами,
# пересобрать CF, переустановить пакет. Пуш и перезапуск сервиса — по флагам.
function Update-Answer42Fork {
    param([pscustomobject]$Config, [string]$Ref, [switch]$Push, [switch]$RestartService)

    if (-not $Config.ForkDir) { throw "В .env нет ANSWER42_FORK_DIR (путь к чекауту форка)." }
    if (-not (Test-Path -LiteralPath (Join-Path $Config.ForkDir ".git"))) {
        throw "Не похоже на git-чекаут: $($Config.ForkDir)"
    }
    $dir = (Resolve-Path -LiteralPath $Config.ForkDir).Path
    $branch = $Config.ForkBranch

    Write-Host "fetch $($Config.ForkRemote)…"
    [void](Invoke-GitStep -Dir $dir -GitArgs @("fetch", $Config.ForkRemote, "--tags", "--prune"))

    $target = $Ref
    if (-not $target) {
        $tagList = (Invoke-GitStep -Dir $dir -GitArgs @("tag", "--sort=-v:refname")).Output -split "`r?`n" |
            Where-Object { $_ -and $_.Trim() }
        $target = $tagList | Select-Object -First 1
    }
    if (-not $target) { throw "Не удалось определить ref upstream (нет тегов?)" }

    $current = (Invoke-GitStep -Dir $dir -GitArgs @("rev-parse", "--abbrev-ref", "HEAD")).Output.Trim()
    if ($current -ne $branch) { [void](Invoke-GitStep -Dir $dir -GitArgs @("checkout", $branch)) }

    $dirty = (Invoke-GitStep -Dir $dir -GitArgs @("status", "--porcelain")).Output.Trim()
    if ($dirty) { throw "В чекауте форка есть незакоммиченные изменения — разберитесь вручную:`n$dirty" }

    # ^{commit} — теги у upstream аннотированные: rev-parse вернул бы SHA тега, а не коммита
    $targetSha = (Invoke-GitStep -Dir $dir -GitArgs @("rev-parse", "$target^{commit}")).Output.Trim()
    $baseSha = (Invoke-GitStep -Dir $dir -GitArgs @("merge-base", "HEAD", "$target^{commit}")).Output.Trim()
    if ($targetSha -eq $baseSha) {
        Write-Host "$branch уже основана на $target ($($targetSha.Substring(0, 8))) — обновлять нечего."
    }
    else {
        Write-Host "rebase $branch → $target…"
        $rebase = Invoke-GitStep -Dir $dir -GitArgs @("rebase", $target) -AllowFail
        if (-not $rebase.Ok) {
            Write-Host $rebase.Output
            throw "rebase не прошёл (конфликт?). Разрешить вручную в ${dir}: git rebase --continue | --abort"
        }
    }

    $serverFile = Join-Path $dir "src\mcp_1c\server.py"
    if (-not (Select-String -Path $serverFile -Pattern "_tool_error_text" -Quiet)) {
        throw "Патч (_tool_error_text) не найден в $target — проверить ветку $branch (коммит с фиксом текста ошибок)."
    }

    $python = Join-Path $dir ".venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $python)) { throw "Нет venv форка: $python" }
    $buildScript = Join-Path $dir "scripts\build_cf.py"

    # На Windows файлы venv залочены работающим сервисом (answer42.exe → WinError 32)
    $serviceWasRunning = (Test-Path -LiteralPath $pidFile) -or (Get-PortState -Config $Config)
    if ($serviceWasRunning) {
        Write-Host "останавливаю HTTP-сервис на время переустановки…"
        Stop-Answer42Http
    }
    Write-Host "пересобираю CF…"
    foreach ($pair in @(@("src\cf", "MCPTestManager.cf"), @("src\client_cf", "MCPTestClient.cf"))) {
        $cfSource = Join-Path $dir $pair[0]
        $cfTarget = Join-Path (Join-Path $dir "src\mcp_1c\assets") $pair[1]
        $buildProcess = Start-Process -FilePath $python -Wait -PassThru -NoNewWindow `
            -WorkingDirectory $stateDir `
            -ArgumentList @($buildScript, $cfSource, $cfTarget)
        if ($buildProcess.ExitCode -ne 0) { throw "Сборка $($pair[1]) не прошла (код $($buildProcess.ExitCode))" }
    }
    $editable = $dir + "[screenshot,windows-window-control]"
    $pipProcess = Start-Process -FilePath $python -Wait -PassThru -NoNewWindow `
        -WorkingDirectory $stateDir `
        -ArgumentList @("-m", "pip", "install", "-q", "-e", $editable)
    if ($pipProcess.ExitCode -ne 0) { throw "pip install -e не прошёл (код $($pipProcess.ExitCode))" }

    if ($Push) {
        Write-Host "push → $($Config.PushRemote)/$branch…"
        [void](Invoke-GitStep -Dir $dir -GitArgs @("push", "--force-with-lease", $Config.PushRemote, $branch))
    }
    if ($serviceWasRunning -or $RestartService) { & $PSCommandPath start -Root $Root }
    Write-Host "Готово. Проверка: answer42.ps1 smoke и битая навигационная ссылка (в ответе должен быть текст 1С)."
}

function Get-PortState {
    param([pscustomobject]$Config)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync("127.0.0.1", [int]$Config.Port)
        if ($task.Wait(1000) -and $client.Connected) { return $true }
        return $false
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Stop-Answer42Http {
    $config = Get-Config
    $stopped = @()
    # pid-файл может содержать pid лаунчера (уже вышел) — ошибки taskkill не фатальны
    if (Test-Path -LiteralPath $pidFile) {
        $pidValue = (Get-Content -LiteralPath $pidFile -Raw).Trim()
        if ($pidValue) {
            $previous = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            & taskkill /PID $pidValue /T /F *> $null
            $ErrorActionPreference = $previous
            $stopped += "pid $pidValue"
        }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
    # добиваем того, кто реально слушает порт (pid лаунчера и рабочего процесса различаются)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $owners = Get-NetTCPConnection -LocalPort ([int]$config.Port) -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
    $ErrorActionPreference = $previous
    foreach ($owner in $owners) {
        if ($owner -and $owner -ne $PID) {
            $ErrorActionPreference = "Continue"
            & taskkill /PID $owner /T /F *> $null
            $ErrorActionPreference = $previous
            $stopped += "port $($config.Port) → pid $owner"
        }
    }
    if ($stopped.Count -gt 0) {
        Write-Host "Answer42 HTTP остановлен ($($stopped -join ', '))"
    }
    else {
        Write-Host "Answer42 HTTP не запущен"
    }
}

switch ($Action) {
    "install" {
        $pythonCommand = $null
        foreach ($candidate in @("py -3.13", "py -3.12", "py -3.11", "python")) {
            $parts = $candidate.Split(" ")
            if (Get-Command $parts[0] -ErrorAction SilentlyContinue) { $pythonCommand = $parts; break }
        }
        if (-not $pythonCommand) { throw "Не найден Python 3.11+ (py launcher или python в PATH)" }

        Write-Host "Создаю venv $venvDir"
        $launcher = (Get-Command $pythonCommand[0]).Source
        if ($pythonCommand.Count -gt 1) {
            & $launcher $pythonCommand[1] -m venv $venvDir
        }
        else {
            & $launcher -m venv $venvDir
        }
        $python = Join-Path $venvDir "Scripts\python.exe"
        & $python -m pip install --upgrade pip
        & $python -m pip install "answer42[screenshot,windows-window-control]"
        Write-Host "Готово. Проверка: .venv-answer42\Scripts\answer42.exe --version"
    }
    "start" {
        $config = Get-Config
        if (-not $config.Token) {
            throw "В .env нет ANSWER42_TOKEN. Сгенерируйте ([guid]::NewGuid().ToString('N')) и добавьте ANSWER42_TOKEN=<значение>."
        }
        if (-not (Test-Path -LiteralPath $config.Bin)) {
            throw "Нет $($config.Bin). Сначала: answer42.ps1 install"
        }
        if (Test-Path -LiteralPath $pidFile) {
            Write-Host "PID-файл уже есть - перезапускаю"
            Stop-Answer42Http
        }
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

        $arguments = @(
            "--http",
            "--http-host", "127.0.0.1",
            "--http-port", $config.Port,
            "--http-account-id", $config.AccountId,
            "--http-token", $config.Token,
            "--log-level", "INFO"
        )
        if ($config.ExtraArgs) { $arguments += ($config.ExtraArgs -split "\s+") }
        $process = Start-Process -FilePath $config.Bin -ArgumentList $arguments -PassThru `
            -WorkingDirectory $stateDir -WindowStyle Hidden `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog
        $process.Id | Set-Content -LiteralPath $pidFile -Encoding ASCII

        # Готовность процесса видна сразу (открытый порт); готовность HTTP-эндпоинта
        # у Answer42 наступает позже — её проверяет status и mcp-call.
        $open = $false
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 500
            if (Get-PortState -Config $config) { $open = $true; break }
        }
        if ($open) {
            Write-Host "Answer42 HTTP запущен: $($config.Url) (pid $($process.Id), порт открыт)"
        }
        else {
            Write-Host "Процесс запущен (pid $($process.Id)), но порт $($config.Port) пока закрыт."
            Write-Host "Лог: $errLog"
        }
    }
    "stop" { Stop-Answer42Http }
    "restart" {
        Stop-Answer42Http
        & $PSCommandPath start -Root $Root
    }
    "status" {
        $config = Get-Config
        $pidValue = if (Test-Path -LiteralPath $pidFile) { (Get-Content -LiteralPath $pidFile -Raw).Trim() } else { "" }
        $open = Get-PortState -Config $config
        Write-Host "url          : $($config.Url)"
        Write-Host "account_id   : $($config.AccountId)"
        Write-Host "bin          : $($config.Bin)"
        Write-Host "pid          : $pidValue"
        Write-Host "port_open    : $open"
        if (-not $open) {
            Write-Host "err_log      : $errLog"
            exit 2
        }
        Write-Host "Проверка эндпоинта: bash tools/mcp-call/mcp-call.sh --server answer42 session_status"
    }
    "smoke" {
        # Smoke на встроенной демо-базе Answer42: dev-ИБ не затрагивается.
        Invoke-Answer42Python -Arguments @($smokeScript, "--bin", (Get-Config).Bin)
    }
    "update" {
        # Обновление форк-сборки с upstream (см. .env: ANSWER42_FORK_*)
        Update-Answer42Fork -Config (Get-Config) -Ref $Ref -Push:$Push -RestartService:$RestartService
    }
}
