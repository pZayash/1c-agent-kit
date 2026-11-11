#!/usr/bin/env bash
# Загрузка/обновление расширения (.cfe) через MCP extension_load_post (/mcp-privileged).
# Обходит ARG_MAX: args JSON в файл → mcp-call.sh @file (jq --slurpfile).
#
# Использование (из корня репо):
#   bash tools/mcp-call/extension-load-cfe.sh \
#     --server dev_db_privileged \
#     --cfe .tmp/MyExtension.cfe
#   bash tools/mcp-call/extension-load-cfe.sh --server dev_dt_privileged --cfe .tmp/MCP_Сервер.cfe
#
# Опции:
#   --server KEY     ключ mcpServers (обычно *_privileged)
#   --cfe PATH       путь к .cfe (обяз.)
#   --active true|false     (default true)
#   --safe-mode true|false  (default false)
#   --timeout SEC    (default 600)
#   --help
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

SERVER=""
CFE=""
ACTIVE="true"
SAFE_MODE="false"
TIMEOUT="600"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER="${2:-}"; shift 2 ;;
    --cfe) CFE="${2:-}"; shift 2 ;;
    --active) ACTIVE="${2:-}"; shift 2 ;;
    --safe-mode) SAFE_MODE="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "неизвестная опция: $1" >&2; usage; exit 4 ;;
  esac
done

[[ -n "$SERVER" ]] || { echo "нужен --server" >&2; exit 4; }
[[ -n "$CFE" && -f "$CFE" ]] || { echo "нужен существующий --cfe PATH" >&2; exit 4; }

mkdir -p .tmp
ARGS_JSON=".tmp/extension-load-args-$$.json"
cleanup() { rm -f "$ARGS_JSON"; }
trap cleanup EXIT

export EXT_LOAD_CFE="$CFE"
export EXT_LOAD_ARGS_JSON="$ARGS_JSON"
export EXT_LOAD_ACTIVE="$ACTIVE"
export EXT_LOAD_SAFE_MODE="$SAFE_MODE"

bash tools/sandbox/run.sh python - <<'PY'
import base64, json, os
from pathlib import Path

cfe_path = Path(os.environ["EXT_LOAD_CFE"])
out_path = Path(os.environ["EXT_LOAD_ARGS_JSON"])
active = os.environ.get("EXT_LOAD_ACTIVE", "true").strip().lower() in ("1", "true", "yes", "да")
safe_mode = os.environ.get("EXT_LOAD_SAFE_MODE", "false").strip().lower() in ("1", "true", "yes", "да")
data = cfe_path.read_bytes()
args = {
    "data_base64": base64.b64encode(data).decode("ascii"),
    "active": active,
    "safe_mode": safe_mode,
}
out_path.write_text(json.dumps(args), encoding="utf-8")
print(f"cfe={len(data)} json={out_path.stat().st_size}", flush=True)
PY

# ponytail: не `exec` — trap EXIT при exec сносит ARGS_JSON до mcp-call
# («Файл аргументов не найден»). Обычный вызов → cleanup после exit.
bash tools/mcp-call/mcp-call.sh \
  --server "$SERVER" \
  --timeout "$TIMEOUT" \
  extension_load_post @"$ARGS_JSON"
