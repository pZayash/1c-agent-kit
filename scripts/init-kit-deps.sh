#!/usr/bin/env bash
# Check (and optionally install) kit host PATH tools. Never openspec init / rtk init.
# Deps: core/deps.json + stacks/<s>/stack.json выбранных стеков (.kit.json).
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
OPENSPEC_PKG="@fission-ai/openspec@1.2.0"

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
dep_openspec() {
  if have openspec; then echo "OK openspec"; else
    echo "FAIL missing: openspec  (npm i -g $OPENSPEC_PKG)"; fail=1
    if [[ "$INSTALL" == "1" ]] && have npm; then
      echo "install $OPENSPEC_PKG"; npm install -g "$OPENSPEC_PKG" || true
    fi
  fi
}
dep_rtk()     { need rtk "https://github.com/rtk-ai/rtk — поставь вручную, как удобно"; }
dep_rg()      { need rg "apt install ripgrep"; }
dep_docker()  { warn_have docker; }
dep_python()  { if have python || have python3; then echo "OK python"; else echo "WARN python not on PATH"; fi; }
dep_qmd()     { warn_have qmd; }
dep_unzip()   { warn_have unzip "BSLLS download"; }
dep_answer42() {
  if [[ -e "$CONSUMER_ROOT/tools/answer42" ]]; then echo "OK answer42 (consumer tools/)"
  else echo "WARN answer42 не слинкован (tools/answer42) — bootstrap-kit"; fi
}
dep_bsl_language_server() {
  local bslls_py="" bslls_script bslls_out bslls_rc
  if have python3; then bslls_py="python3"; elif have python; then bslls_py="python"; fi
  bslls_script="$HARNESS_ROOT/stacks/1c/tools/bsl-check/check-bsl.py"
  [[ -f "$bslls_script" ]] || bslls_script="$CONSUMER_ROOT/tools/bsl-check/check-bsl.py"
  if [[ -z "$bslls_py" ]]; then
    echo "WARN BSLLS: no python to run check-bsl.py --which"
  elif [[ ! -f "$bslls_script" ]]; then
    echo "WARN BSLLS: check-bsl.py missing"
  else
    bslls_out=""; bslls_rc=0
    bslls_out="$("$bslls_py" "$bslls_script" --which 2>&1)" || bslls_rc=$?
    if [[ "$bslls_rc" -eq 0 ]]; then
      echo "OK BSLLS $bslls_out"
    else
      echo "WARN BSLLS runtime missing"
      printf '%s\n' "$bslls_out"
    fi
  fi
}
dep_designer_ibcmd() {
  if have ibcmd || have designer; then echo "OK designer/ibcmd"
  else echo "WARN designer/ibcmd not on PATH (проверь DESIGNER_PATH в .env)"; fi
}

run_dep() { # $1=dep id → dep_*
  local fn="dep_${1//-/_}"
  if declare -F "$fn" >/dev/null; then "$fn"; else
    echo "WARN unknown dep id: $1 (нет check-функции)"
  fi
}

# dep ids из JSON-реестра (однострочный формат stack.json/deps.json).
deps_ids() { # $1=json file
  tr -d ' \t' <"$1" | sed -n 's/.*"deps":\[\(.*\)\].*/\1/p' | tr ',' '\n' | tr -d '"'
}

echo "NEVER: openspec init  (own openspec/ + kit skills)"
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
check_deps_file() { # $1=json $2=label
  [[ -f "$1" ]] || { echo "WARN missing deps registry: $1"; return; }
  echo "=== deps: $2 ==="
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    [[ -n "${seen[$d]:-}" ]] && continue
    seen["$d"]=1
    run_dep "$d"
  done < <(deps_ids "$1")
}

check_deps_file "$HARNESS_ROOT/core/deps.json" "core"
for s in $stacks; do
  check_deps_file "$HARNESS_ROOT/stacks/$s/stack.json" "stack $s"
done

echo "=== consumer ==="
if [[ -d "$CONSUMER_ROOT/openspec" ]]; then
  echo "OK openspec/ (from git, not init)"
else
  echo "FAIL missing: openspec/  — merge consumer branch; NEVER openspec init"
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
