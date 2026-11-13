#!/usr/bin/env bash
# Check (and optionally install) kit host PATH tools. Never openspec init / rtk init
# (openspec CLI не используется — спеки через harness/tools/kit-spec).
# Deps: core/core.json + stacks/<s>/stack.json выбранных стеков (.kit.json),
# структурно — ключ `deps` из `kit_layout.py print-config --json`.
# Стеко-специфичные id без core dep_<d> → хук stacks/<s>/deps-check.sh.
#
# Usage:
#   bash harness/scripts/init-kit-deps.sh [ConsumerRoot]
# Env:
#   INSTALL=1
#   HARNESS_REL=harness
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_link-common.sh
source "$SCRIPT_DIR/_link-common.sh"

CONSUMER_ROOT="${1:-.}"
INSTALL="${INSTALL:-0}"
HARNESS_REL="${HARNESS_REL:-harness}"

if kit_is_windows; then
  args=(-ConsumerRoot "$(cd "$CONSUMER_ROOT" && pwd)" -HarnessRel "$HARNESS_REL")
  [[ "$INSTALL" == "1" ]] && args+=(-Install)
  ps_exe="$(kit_powershell)" || { echo "ERROR: PowerShell не найден (Windows-ветка kit идёт через .ps1)" >&2; exit 1; }
  exec "$ps_exe" -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/init-kit-deps.ps1" "${args[@]}"
fi

CONSUMER_ROOT="$(cd "$CONSUMER_ROOT" && pwd)"
HARNESS_ROOT="$CONSUMER_ROOT/$HARNESS_REL"
fail=0

have() { command -v "$1" >/dev/null 2>&1; }
need() { if have "$1"; then echo "OK $1"; else echo "FAIL missing: $1  ($2)"; fail=1; fi; }
warn_have() { if have "$1"; then echo "OK $1"; else echo "WARN $1 not on PATH${2:+ - $2}"; fi; }

# ── dep-id → check ───────────────────────────────────────────────────
dep_git()     { need git "install git"; }
dep_node() {
  if have node; then
    maj="$(node -v | sed 's/^v//;s/\..*//')"; maj="${maj:-0}"
    if [[ "$maj" -ge 18 ]]; then echo "OK node $(node -v)"; else
      echo "FAIL node $(node -v) (need 18+, prefer 20)"; fail=1; fi
  else
    echo "FAIL missing: node (Node 20; slot image already has it)"; fail=1
  fi
}
dep_npm()     { need npm "comes with node"; }
dep_rtk()     { need rtk "https://github.com/rtk-ai/rtk — поставь вручную, как удобно"; }
dep_rg()      { need rg "apt install ripgrep"; }
dep_docker()  { warn_have docker; }
dep_python()  { if have python || have python3 || have py; then echo "OK python"; else
    echo "FAIL missing: python  (kit tools: kit-layout, kit-spec, sandbox)"; fail=1
  fi; }
dep_qmd()     { warn_have qmd; }
dep_unzip()   { warn_have unzip "BSLLS download"; }

# Диспетчеризация dep-id (spec «Per-stack deps-check хук»):
# есть dep_<d> в этом скрипте → выполнить (дедуп seen между стеками);
# иначе id уходит в unhandled стека → один вызов stacks/<s>/deps-check.sh.
run_core_dep() { # $1=dep id
  local fn="dep_${1//-/_}"
  [[ -n "${seen[$1]:-}" ]] && return 0
  if declare -F "$fn" >/dev/null; then
    seen["$1"]=1
    "$fn"
  else
    echo "WARN unknown dep id: $1 (нет check-функции)"
  fi
}

# $1=stack id, остальные — его dep ids. unhandled → хук стека с env
# CONSUMER_ROOT/HARNESS_ROOT/INSTALL/STACK_DEPS, cwd=consumer root;
# exit != 0 → fail. Нет хука → WARN. «WARN unknown dep id» для unhandled
# здесь не печатается — это норма, их разбирает хук.
run_stack_deps() {
  local s="$1"; shift
  local unhandled=() d fn hook
  for d in "$@"; do
    fn="dep_${d//-/_}"
    if declare -F "$fn" >/dev/null; then
      run_core_dep "$d"
    else
      unhandled+=("$d")
    fi
  done
  [[ "${#unhandled[@]}" -gt 0 ]] || return 0
  hook="$HARNESS_ROOT/stacks/$s/deps-check.sh"
  if [[ -f "$hook" ]]; then
    if ! (cd "$CONSUMER_ROOT" && \
          CONSUMER_ROOT="$CONSUMER_ROOT" HARNESS_ROOT="$HARNESS_ROOT" \
          INSTALL="$INSTALL" STACK_DEPS="${unhandled[*]}" "$BASH" "$hook"); then
      fail=1
    fi
  else
    echo "WARN stack $s: deps не покрыты core dep_* (${unhandled[*]}) и нет stacks/$s/deps-check.sh"
  fi
}

echo "NEVER: openspec init  (kit_spec.py init вместо него; openspec CLI не нужен)"
echo "NEVER: rtk init       (writes CLAUDE.md)"
echo "NEVER: rtk init -g    (Claude hook; Cursor prefixes rtk itself)"

# ── effective stacks ─────────────────────────────────────────────────
stacks=""
stacks_rc=0
stacks="$(kit_effective_stacks "$CONSUMER_ROOT" "$HARNESS_REL")" || stacks_rc=$?
case "$stacks_rc" in
  0) ;;
  3) echo "WARN: .kit.json отсутствует — core-only (stacks: []). Создай файл для выбора стеков." ;;
  *) echo "init-kit-deps: не удалось прочитать стеки" >&2; exit 1 ;;
esac
[[ "$stacks" == "*" ]] && stacks="$(for sj in "$HARNESS_ROOT"/stacks/*/stack.json; do
    [[ -f "$sj" ]] && basename "$(dirname "$sj")"; done | tr '\n' ' ')"

echo "=== check ==="
declare -A seen=()

# deps-реестр — структурно, ключ deps из print-config --json
# (текстовый парсинг JSON запрещён). Нет python → WARN + пропуск секций.
deps_rows=""
deps_cfg=""
PY="$(command -v python || command -v python3 || command -v py || true)"
if [[ -n "$PY" ]] && deps_cfg="$(kit_print_config_json "$CONSUMER_ROOT" "$HARNESS_REL" 2>/dev/null)"; then
  deps_rows="$(printf '%s' "$deps_cfg" | "$PY" -c 'import json,sys
c=json.load(sys.stdin)
d=c.get("deps") or {}
print("core\t"+" ".join(str(x) for x in (d.get("core") or [])))
for s,ids in sorted((d.get("stacks") or {}).items()):
    print("stack\t"+s+"\t"+" ".join(str(x) for x in ids))' 2>/dev/null | tr -d '\r')" || deps_rows=""
fi

if [[ -z "$deps_rows" ]]; then
  echo "WARN deps registry не прочитан (нет python / print-config) — секции deps пропущены"
else
  while IFS=$'\t' read -r kind s ids; do
    case "$kind" in
      core)
        [[ -n "$s" ]] || continue
        echo "=== deps: core ==="
        for d in $s; do run_core_dep "$d"; done ;;
      stack)
        [[ -n "$ids" && " $stacks " == *" $s "* ]] || continue
        echo "=== deps: stack $s ==="
        # разбиение $ids по пробелам — намеренно
        run_stack_deps "$s" $ids ;;
    esac
  done <<<"$deps_rows"
fi

echo "=== consumer ==="
if [[ -d "$CONSUMER_ROOT/specs" ]]; then
  echo "OK specs/ (from git, not init)"
elif [[ -d "$CONSUMER_ROOT/openspec" ]]; then
  echo "WARN openspec/ legacy root — миграция: python $HARNESS_REL/tools/kit-spec/kit_spec.py migrate-root --apply"
else
  echo "FAIL missing: specs/  — merge consumer branch или kit_spec.py init; NEVER openspec init"
  fail=1
fi
if [[ -f "$CONSUMER_ROOT/.env" ]]; then echo "OK .env"; else echo "WARN missing .env"; fi

if [[ -f "$CONSUMER_ROOT/.git" && -f "$CONSUMER_ROOT/$HARNESS_REL/.git" ]]; then
  line="$(head -n1 "$CONSUMER_ROOT/$HARNESS_REL/.git" | tr -d '\r')"
  if [[ "$line" == *'../.git/modules/harness'* ]]; then
    echo "FAIL harness gitdir relative ../.git/modules/harness — run fix-harness-gitdir"
    fail=1
  fi
fi

echo "see harness/core/docs/ai/kit-host-deps.md"
if [[ "$fail" -ne 0 ]]; then exit 1; fi
echo "init-kit-deps: OK"
