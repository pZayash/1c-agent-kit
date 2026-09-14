#!/usr/bin/env bash
# Apply slot-transfer на хосте без Docker (канон SRV01).
# Тот же tools/mailbox/apply.py. Протокол task.json не меняется.
# Playwright нет. data.mode=none only (slot/dev_dt — Docker-обёртка).
#
# Не ставить AGENT_SLOT: иначе ящик резолвится в /work/mailbox.
# AGENTS_MAILBOX — локальный NTFS, не UNC (claim = rename на том же томе).
#
# Примеры (42):
#   export MAILBOX_WORK=D:/dev/proj/slot-3
#   export AGENTS_MAILBOX=D:/org/agents/mailbox
#   bash tools/mailbox/apply-host.sh 3 <uuid>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY_PY="${SCRIPT_DIR}/apply.py"

SLOT=""
ID=""
PASSTHRU=()

usage() {
  cat <<'EOF'
Использование: bash tools/mailbox/apply-host.sh N <id> [--peek|--complete ...]

  N   слот-приёмник 1, 2 или 3 (на 42 канон — 3 = host worktree)
  id  UUID задачи kind=slot-transfer

Env (обязательны, кроме --peek если AGENTS_MAILBOX уже в окружении):
  MAILBOX_WORK     worktree приёмника (42: D:/dev/proj/slot-3)
  AGENTS_MAILBOX   локальный NTFS ящика (42: D:/org/agents/mailbox)
  PYTHON           интерпретатор; иначе python3 | py -3 | python

Не cron-load в живую ИБ. Cron только list: python tools/mailbox/paths.py inbox slot-3
Docker-слоты ноутбука: docker/agent-container/mailbox-apply.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --peek | --complete)
      PASSTHRU+=("$1")
      shift
      ;;
    --artifact)
      [[ $# -ge 2 ]] || { echo "--artifact name=uri" >&2; exit 4; }
      PASSTHRU+=("$1" "$2")
      shift 2
      ;;
    *)
      if [[ -z "$SLOT" ]]; then
        SLOT="$1"
        shift
      elif [[ -z "$ID" ]]; then
        ID="$1"
        shift
      else
        echo "лишний аргумент: $1" >&2
        usage >&2
        exit 4
      fi
      ;;
  esac
done

[[ -n "$SLOT" && -n "$ID" ]] || { usage >&2; exit 4; }
[[ "$SLOT" =~ ^[123]$ ]] || { echo "Слот: только 1, 2 или 3" >&2; exit 4; }

: "${MAILBOX_WORK:?задай MAILBOX_WORK (worktree приёмника)}"
: "${AGENTS_MAILBOX:?задай AGENTS_MAILBOX (локальный NTFS ящика, не UNC)}"

unset AGENT_SLOT
export MAILBOX_WORK AGENTS_MAILBOX

run_py() {
  if [[ -n "${PYTHON:-}" ]]; then
    "$PYTHON" "$@"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 "$@"
    return
  fi
  if command -v py >/dev/null 2>&1; then
    py -3 "$@"
    return
  fi
  if command -v python >/dev/null 2>&1; then
    python "$@"
    return
  fi
  echo "нужен CPython (не Microsoft Store-заглушка). Поставь python.org / winget, или PYTHON=..." >&2
  exit 4
}

# load-changed-files.sh ищет .env от cwd = worktree
cd "$MAILBOX_WORK"

set +e
APPLY_OUT="$(run_py "$APPLY_PY" --slot "$SLOT" --id "$ID" "${PASSTHRU[@]+"${PASSTHRU[@]}"}" 2>&1)"
APPLY_CODE=$?
set -e
printf '%s\n' "${APPLY_OUT}"

if [[ "${APPLY_CODE}" -eq 2 ]]; then
  echo "input-required: конфликт merge, Playwright не запускался" >&2
  exit 2
fi
[[ "${APPLY_CODE}" -eq 0 ]] || exit "${APPLY_CODE}"

if printf '%s\n' "${APPLY_OUT}" | grep -q '^NEED_DATA='; then
  echo "на хосте без Docker только data.mode=none; slot/dev_dt — mailbox-apply.sh (контейнер)" >&2
  exit 4
fi
