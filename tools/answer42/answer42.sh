#!/usr/bin/env bash
# Answer42 (UI-driver MCP для 1С) — установка и HTTP-режим на Linux.
#
# Требуется X11 или Xvfb (Answer42 поднимает окна 1cv8c).
#
# Примеры:
#   bash tools/answer42/answer42.sh install
#   bash tools/answer42/answer42.sh start|stop|restart|status|smoke
set -euo pipefail

ACTION="${1:-status}"
ROOT="${ANSWER42_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[[ -f "$ROOT/.env.example" ]] || { echo "Не найден корень проекта: $ROOT" >&2; exit 2; }

STATE_DIR="$ROOT/.tmp/answer42"
PID_FILE="$STATE_DIR/http.pid"
ERR_LOG="$STATE_DIR/http.err.log"
OUT_LOG="$STATE_DIR/http.out.log"
VENV_DIR="$ROOT/.venv-answer42"
PYTHON="$VENV_DIR/bin/python"
DEFAULT_BIN="$VENV_DIR/bin/answer42"

env_value() {
    local key="$1" default="${2:-}" value=""
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
BIN="$(env_value ANSWER42_BIN "$DEFAULT_BIN")"

http_status() {
    local body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"answer42-sh","version":"1"}}}'
    curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST "$MCP_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Authorization: Bearer $TOKEN" \
        --data-binary "$body" 2>/dev/null || echo "000"
}

case "$ACTION" in
    install)
        python3 -m venv "$VENV_DIR"
        "$PYTHON" -m pip install --upgrade pip
        "$PYTHON" -m pip install "answer42[screenshot,linux-window-control]"
        echo "Готово: $VENV_DIR (проверка: $DEFAULT_BIN --version)"
        ;;
    start)
        [[ -n "$TOKEN" ]] || { echo "В .env нет ANSWER42_TOKEN" >&2; exit 2; }
        [[ -x "$BIN" ]] || { echo "Нет $BIN — сначала install" >&2; exit 2; }
        mkdir -p "$STATE_DIR"
        if [[ -f "$PID_FILE" ]]; then
            kill "$(cat "$PID_FILE")" 2>/dev/null || true
            rm -f "$PID_FILE"
        fi
        # cwd = state dir: Answer42 складывает рядом build/ (CF, RAG sqlite)
        (cd "$STATE_DIR" && nohup "$BIN" \
            --http --http-host 127.0.0.1 \
            --http-port "${MCP_URL##*:}" \
            --http-account-id "$ACCOUNT_ID" \
            --http-token "$TOKEN" \
            >"$OUT_LOG" 2>"$ERR_LOG" & echo $! >"$PID_FILE")
        for _ in $(seq 1 30); do
            sleep 0.5
            if [[ "$(http_status)" == "200" ]]; then
                echo "Answer42 HTTP поднят: $MCP_URL (pid $(cat "$PID_FILE"))"
                exit 0
            fi
        done
        echo "Answer42 HTTP не ответил. Лог: $ERR_LOG" >&2
        exit 1
        ;;
    stop)
        if [[ -f "$PID_FILE" ]]; then
            kill "$(cat "$PID_FILE")" 2>/dev/null || true
            rm -f "$PID_FILE"
            echo "Остановлен"
        else
            echo "Не запущен"
        fi
        ;;
    restart)
        "$0" stop
        "$0" start
        ;;
    status)
        code="$(http_status)"
        echo "url         : $MCP_URL"
        echo "account_id  : $ACCOUNT_ID"
        echo "bin         : $BIN"
        echo "pid         : $(cat "$PID_FILE" 2>/dev/null || echo '-')"
        echo "http_status : $code"
        [[ "$code" == "200" ]] || { echo "err_log     : $ERR_LOG" >&2; exit 2; }
        ;;
    smoke)
        "$PYTHON" "$ROOT/tools/answer42/smoke.py" --bin "$BIN" --account-id "$ACCOUNT_ID"
        ;;
    *)
        echo "Неизвестное действие: $ACTION (install|start|stop|restart|status|smoke)" >&2
        exit 2
        ;;
esac
