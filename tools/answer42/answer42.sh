#!/usr/bin/env bash
# Answer42 (UI-driver MCP для 1С) — установка, HTTP-режим и обновление сборки.
#
# Паритет с answer42.ps1: те же действия и ключи .env. Требуется X11 или
# Xvfb (Answer42 поднимает окна 1cv8c). Скрипт работает и в Git Bash на
# Windows (пути вида C:\... нормализуются) — удобно для отладки логики.
#
# Примеры:
#   bash tools/answer42/answer42.sh install              # PyPI-сборка
#   bash tools/answer42/answer42.sh install --fork       # editable-сборка из форка
#   bash tools/answer42/answer42.sh start|stop|restart|status|smoke
#   bash tools/answer42/answer42.sh update [--ref v0.5.4] [--push] [--no-restart]
set -euo pipefail

ACTION="status"
REF=""
PUSH=0
RESTART=1
FORK_INSTALL=0

while (($#)); do
    case "$1" in
        install|start|stop|restart|status|smoke|update) ACTION="$1" ;;
        --fork) FORK_INSTALL=1 ;;
        --ref) REF="${2:-}"; shift ;;
        --push) PUSH=1 ;;
        --no-restart) RESTART=0 ;;
        -h|--help) ACTION="help" ;;
        *) echo "Неизвестный аргумент: $1 (см. --help)" >&2; exit 2 ;;
    esac
    shift
done

ROOT="${ANSWER42_ROOT:-}"
if [[ -z "$ROOT" ]]; then
    # Корень ищем вверх по .env.example: скрипт зовут и как tools/answer42/…
    # (симлинк kit), и как harness/tools/answer42/… — фиксированное "../.."
    # в одном из этих случаев даёт harness/ вместо корня потребителя.
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for _ in 1 2 3 4 5 6; do
        [[ -f "$ROOT/.env.example" ]] && break
        ROOT="$(dirname "$ROOT")"
    done
fi
[[ -f "$ROOT/.env.example" ]] || { echo "Не найден корень проекта (.env.example) вверх от $ROOT. Передайте ANSWER42_ROOT." >&2; exit 2; }

STATE_DIR="$ROOT/.tmp/answer42"
PID_FILE="$STATE_DIR/http.pid"
ERR_LOG="$STATE_DIR/http.err.log"
OUT_LOG="$STATE_DIR/http.out.log"
VENV_DIR="$ROOT/.venv-answer42"
PYTHON="$VENV_DIR/bin/python"
DEFAULT_BIN="$VENV_DIR/bin/answer42"

# Git Bash: в .env пути пишут как C:\a\b — bash такие не понимает.
norm_path() { local p="${1//\\//}"; printf '%s' "$p"; }

env_value() {
    local key="$1" default="${2:-}" value=""
    # окружение важнее .env — удобно для слотов и ad-hoc проверок
    if [[ -n "${!key:-}" ]]; then
        printf '%s' "${!key}"
        return 0
    fi
    if [[ -f "$ROOT/.env" ]]; then
        value="$(sed -n "s/^${key}=//p" "$ROOT/.env" | tail -1 | sed 's/^"//; s/"$//')"
    fi
    if [[ -z "$value" && -f "$ROOT/.env.example" ]]; then
        value="$(sed -n "s/^${key}=//p" "$ROOT/.env.example" | tail -1 | sed 's/^"//; s/"$//')"
    fi
    printf '%s' "${value:-$default}"
}

MCP_URL="$(env_value ANSWER42_MCP_URL "http://127.0.0.1:9010/mcp")"
ACCOUNT_ID="$(env_value ANSWER42_ACCOUNT_ID "answer42")"
TOKEN="$(env_value ANSWER42_TOKEN "")"
BIN="$(norm_path "$(env_value ANSWER42_BIN "$DEFAULT_BIN")")"
EXTRA_ARGS="$(env_value ANSWER42_EXTRA_ARGS "")"
FORK_DIR="$(norm_path "$(env_value ANSWER42_FORK_DIR "")")"
FORK_BRANCH="$(env_value ANSWER42_FORK_BRANCH "fork-patches")"
FORK_REMOTE="$(env_value ANSWER42_FORK_REMOTE "upstream")"
FORK_PUSH_REMOTE="$(env_value ANSWER42_FORK_PUSH_REMOTE "origin")"

port_of_url() {
    local p="${MCP_URL##*:}"
    printf '%s' "${p%%/*}"
}

# Git Bash/MSYS: pid'ы Windows-процессов не совпадают с pid'ами MSYS, поэтому
# kill/taskkill и поиск владельца порта делаем платформенно.
case "${OSTYPE:-}" in
    msys*|cygwin*|win32*) IS_MSYS=1 ;;
    *) IS_MSYS=0 ;;
esac

win_port_pids() {
    netstat -ano 2>/dev/null \
        | awk -v p=":$(port_of_url)" '$1 == "TCP" && $4 == "LISTENING" && $2 ~ p "$" { print $5 }' \
        | sort -u
}

port_open() {
    if ((IS_MSYS)); then
        [[ -n "$(win_port_pids)" ]]
    else
        (exec 3<>"/dev/tcp/127.0.0.1/$(port_of_url)") 2>/dev/null
    fi
}

kill_tree() {
    local pid="$1"
    [[ -n "$pid" ]] || return 1
    if ((IS_MSYS)); then
        taskkill //PID "$pid" //T //F >/dev/null 2>&1
    else
        kill "$pid" 2>/dev/null
    fi
}

http_status() {
    local body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"answer42-sh","version":"1"}}}'
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST "$MCP_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Authorization: Bearer $TOKEN" \
        --data-binary "$body" 2>/dev/null || true)"
    printf '%s' "${code:-000}"
}

# Python venv: Linux (.venv/bin/python) или Windows/Git Bash (.venv/Scripts/python.exe).
venv_python() {
    local dir; dir="$(norm_path "$1")"
    local candidates=("$dir/bin/python" "$dir/bin/python3" "$dir/Scripts/python.exe")
    local c
    for c in "${candidates[@]}"; do
        [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# Прерванная установка оставляет в site-packages каталоги ~<pkg> — pip потом
# ругается "Ignoring invalid distribution" в каждом прогоне.
clean_pip_debris() {
    local py="$1" sp
    # именно purelib: site.getsitepackages()[0] в venv отдаёт корень venv
    sp="$("$py" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' 2>/dev/null || true)"
    [[ -n "$sp" && -d "$sp" ]] || return 0
    [[ "$(basename "$sp")" == "site-packages" ]] || return 0
    rm -rf "$sp"/~* 2>/dev/null || true
}

smoke_python() {
    local bin_dir venv_root c
    bin_dir="$(dirname "$BIN")"
    venv_root="$(dirname "$bin_dir")"
    if venv_python "$venv_root" 2>/dev/null; then
        return 0
    fi
    # нестандартная раскладка: интерпретатор лежит рядом с бинарём
    for c in "$bin_dir/python" "$bin_dir/python3" "$bin_dir/python.exe"; do
        [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    printf '%s' "$PYTHON"
}

service_running() {
    if port_open; then
        return 0
    fi
    [[ "$(http_status)" == "200" ]]
}

stop_service() {
    local stopped="" pid=""
    if [[ -f "$PID_FILE" ]]; then
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill_tree "$pid"; then
            stopped="pid $pid"
        fi
        rm -f "$PID_FILE"
    fi
    # pid-файл мог устареть (или pid не совпадает с владельцем порта) — добиваем слушателя
    local port; port="$(port_of_url)"
    if ((IS_MSYS)); then
        local owner
        for owner in $(win_port_pids); do
            [[ "$owner" == "$pid" ]] && continue
            kill_tree "$owner" && stopped="${stopped:+$stopped, }port $port → pid $owner"
        done
    elif command -v fuser >/dev/null 2>&1; then
        fuser -k "${port}/tcp" >/dev/null 2>&1 || true
    elif command -v pkill >/dev/null 2>&1; then
        pkill -f "answer42.*--http-port ${port}" >/dev/null 2>&1 || true
    fi
    if [[ -n "$stopped" ]]; then
        echo "Answer42 HTTP остановлен ($stopped)"
    else
        echo "Answer42 HTTP не запущен"
    fi
}

start_service() {
    [[ -n "$TOKEN" ]] || { echo "В .env нет ANSWER42_TOKEN" >&2; exit 2; }
    [[ -x "$BIN" ]] || { echo "Нет $BIN — сначала install" >&2; exit 2; }
    mkdir -p "$STATE_DIR"
    [[ -f "$PID_FILE" ]] && stop_service

    local args=(--http --http-host 127.0.0.1 --http-port "$(port_of_url)"
        --http-account-id "$ACCOUNT_ID" --http-token "$TOKEN" --log-level INFO)
    # shellcheck disable=SC2206  # пробелы в ANSWER42_EXTRA_ARGS = разделители (как в .ps1)
    [[ -n "$EXTRA_ARGS" ]] && args+=($EXTRA_ARGS)

    # cwd = state dir: Answer42 складывает рядом build/ (CF, RAG sqlite)
    if ((IS_MSYS)); then
        # Git Bash: фоновый процесс MSYS не переживает выход шелла (setsid нет) —
        # запускаем через Start-Process, как answer42.ps1. Аргументы передаём
        # переменными окружения, чтобы не собирать командную строку с кавычками.
        A42_BIN="$(cygpath -w "$BIN")" \
        A42_DIR="$(cygpath -w "$STATE_DIR")" \
        A42_OUT="$(cygpath -w "$OUT_LOG")" \
        A42_ERR="$(cygpath -w "$ERR_LOG")" \
        A42_ARGS="$(printf '%s\n' "${args[@]}")" \
        powershell -NoProfile -Command '
            $argv = @($env:A42_ARGS.Split("`n") | Where-Object { $_ -ne "" })
            $p = Start-Process -FilePath $env:A42_BIN -ArgumentList $argv -PassThru -WindowStyle Hidden `
                -WorkingDirectory $env:A42_DIR `
                -RedirectStandardOutput $env:A42_OUT -RedirectStandardError $env:A42_ERR
            Set-Content -LiteralPath (Join-Path $env:A42_DIR "http.pid") -Value $p.Id -Encoding ASCII
        '
    else
        (cd "$STATE_DIR" && nohup "$BIN" "${args[@]}" \
            >"$OUT_LOG" 2>"$ERR_LOG" & echo $! >"$PID_FILE")
    fi

    local i
    for i in $(seq 1 40); do
        sleep 0.5
        if port_open; then
            echo "Answer42 HTTP запущен: $MCP_URL (pid $(cat "$PID_FILE"), порт открыт)"
            echo "Готовность эндпоинта: bash tools/mcp-call/mcp-call.sh --server answer42 session_status"
            return 0
        fi
    done
    echo "Процесс запущен (pid $(cat "$PID_FILE")), но порт $(port_of_url) пока закрыт. Лог: $ERR_LOG" >&2
    exit 1
}

build_cf() {
    local dir="$1" py="$2" pair src dst
    for pair in "src/cf:MCPTestManager.cf" "src/client_cf:MCPTestClient.cf"; do
        src="$dir/${pair%%:*}"
        dst="$dir/src/mcp_1c/assets/${pair##*:}"
        (cd "$STATE_DIR" && "$py" "$dir/scripts/build_cf.py" "$src" "$dst")
    done
}

install_fork() {
    [[ -n "$FORK_DIR" ]] || { echo "В .env нет ANSWER42_FORK_DIR (путь к чекауту форка)" >&2; exit 2; }
    [[ -d "$FORK_DIR/.git" ]] || { echo "Не похоже на git-чекаут: $FORK_DIR" >&2; exit 2; }
    if ! venv_python "$FORK_DIR/.venv" >/dev/null; then
        echo "Создаю venv $FORK_DIR/.venv"
        python3 -m venv "$FORK_DIR/.venv"
    fi
    local py; py="$(venv_python "$FORK_DIR/.venv")"
    clean_pip_debris "$py"
    "$py" -m pip install --upgrade pip
    "$py" -m pip install -e "$FORK_DIR[screenshot,linux-window-control]"
    mkdir -p "$STATE_DIR"
    # В editable-сборке нет готовых CF (их инжектит CI) — собираем локально
    build_cf "$FORK_DIR" "$py"
    echo "Готово (форк): $FORK_DIR. Укажите в .env ANSWER42_BIN на бинарь venv форка."
}

update_fork() {
    [[ -n "$FORK_DIR" ]] || { echo "В .env нет ANSWER42_FORK_DIR (путь к чекауту форка)" >&2; exit 2; }
    [[ -d "$FORK_DIR/.git" ]] || { echo "Не похоже на git-чекаут: $FORK_DIR" >&2; exit 2; }

    echo "fetch $FORK_REMOTE…"
    git -C "$FORK_DIR" fetch "$FORK_REMOTE" --tags --prune

    local target="$REF"
    if [[ -z "$target" ]]; then
        target="$(git -C "$FORK_DIR" tag --sort=-v:refname | head -1)"
    fi
    [[ -n "$target" ]] || { echo "Не удалось определить ref upstream (нет тегов?)" >&2; exit 2; }
    if ! git -C "$FORK_DIR" rev-parse --verify --quiet "$target^{commit}" >/dev/null; then
        echo "Неизвестный ref upstream: $target (нет такого тега/ветки у $FORK_REMOTE)" >&2
        exit 2
    fi

    local current; current="$(git -C "$FORK_DIR" rev-parse --abbrev-ref HEAD)"
    if [[ "$current" != "$FORK_BRANCH" ]]; then
        git -C "$FORK_DIR" checkout "$FORK_BRANCH"
    fi
    local dirty; dirty="$(git -C "$FORK_DIR" status --porcelain)"
    [[ -z "$dirty" ]] || { echo "В чекауте форка есть незакоммиченные изменения — разберитесь вручную:" >&2; printf '%s\n' "$dirty" >&2; exit 2; }

    # ^{commit} — теги у upstream аннотированные: rev-parse вернул бы SHA тега
    local target_sha base_sha
    target_sha="$(git -C "$FORK_DIR" rev-parse "$target^{commit}")"
    base_sha="$(git -C "$FORK_DIR" merge-base HEAD "$target^{commit}")"
    if [[ "$target_sha" == "$base_sha" ]]; then
        echo "$FORK_BRANCH уже основана на $target ($(printf '%s' "$target_sha" | cut -c1-8)) — обновлять нечего."
    else
        echo "rebase $FORK_BRANCH → $target…"
        if ! git -C "$FORK_DIR" rebase "$target"; then
            echo "rebase не прошёл (конфликт?). Разрешить вручную в $FORK_DIR: git rebase --continue | --abort" >&2
            exit 1
        fi
    fi

    grep -q "_tool_error_text" "$FORK_DIR/src/mcp_1c/server.py" || {
        echo "Патч (_tool_error_text) не найден в $target — проверить ветку $FORK_BRANCH" >&2
        exit 1
    }

    local py; py="$(venv_python "$FORK_DIR/.venv")" || {
        echo "Нет venv форка ($FORK_DIR/.venv). Сначала: answer42.sh install --fork" >&2
        exit 2
    }
    clean_pip_debris "$py"
    local was_running=0
    if service_running; then
        was_running=1
        echo "останавливаю HTTP-сервис на время переустановки…"
        stop_service
    fi
    mkdir -p "$STATE_DIR"
    echo "пересобираю CF…"
    build_cf "$FORK_DIR" "$py"
    "$py" -m pip install -q -e "$FORK_DIR[screenshot,linux-window-control]"

    if ((PUSH)); then
        echo "push → $FORK_PUSH_REMOTE/$FORK_BRANCH…"
        git -C "$FORK_DIR" push --force-with-lease "$FORK_PUSH_REMOTE" "$FORK_BRANCH"
    fi
    if ((was_running)) && ((RESTART)); then
        start_service
    fi
    echo "Готово. Проверка: answer42.sh smoke и битая навигационная ссылка (в ответе должен быть текст 1С)."
}

usage() {
    cat <<'EOF'
Использование: bash tools/answer42/answer42.sh <действие> [опции]

Действия:
  install [--fork]   установить сборку: PyPI в .venv-answer42 (по умолчанию)
                     или editable-сборку форка (ANSWER42_FORK_DIR) + локальные CF
  start              запустить HTTP-сервис (ANSWER42_MCP_URL/TOKEN, фоном в .tmp/answer42)
  stop               остановить сервис
  restart            stop + start
  status             pid, порт, ответ эндпоинта
  smoke              smoke-проверка через tools/answer42/smoke.py
  update             форк: fetch → rebase на новейший тег (или --ref) → проверка
                     патча → пересборка CF → pip install -e

Опции:
  --ref TAG          update: ref upstream вместо новейшего тега
  --push             update: запушить ветку в ANSWER42_FORK_PUSH_REMOTE
  --no-restart       update: не поднимать сервис обратно
  -h, --help         эта справка
EOF
}

case "$ACTION" in
    install)
        if ((FORK_INSTALL)); then
            install_fork
        else
            python3 -m venv "$VENV_DIR"
            "$PYTHON" -m pip install --upgrade pip
            "$PYTHON" -m pip install "answer42[screenshot,linux-window-control]"
            echo "Готово: $VENV_DIR (проверка: $DEFAULT_BIN --version)"
        fi
        ;;
    start) start_service ;;
    stop) stop_service ;;
    restart)
        stop_service
        start_service
        ;;
    status)
        code="$(http_status)"
        echo "url         : $MCP_URL"
        echo "account_id  : $ACCOUNT_ID"
        echo "bin         : $BIN"
        echo "pid         : $(cat "$PID_FILE" 2>/dev/null || echo '-')"
        echo "port_open   : $([[ -f "$PID_FILE" ]] && port_open && echo True || echo False)"
        echo "http_status : $code"
        if [[ "$code" != "200" ]]; then
            echo "err_log     : $ERR_LOG" >&2
            exit 2
        fi
        echo "Проверка эндпоинта: bash tools/mcp-call/mcp-call.sh --server answer42 session_status"
        ;;
    smoke)
        "$(smoke_python)" "$ROOT/tools/answer42/smoke.py" --bin "$BIN" --account-id "$ACCOUNT_ID"
        ;;
    update) update_fork ;;
    help) usage ;;
esac
