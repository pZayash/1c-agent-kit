#!/usr/bin/env bash
# deps-check хук стека 1c — стеко-специфичные host-deps из stack.json,
# не покрытые core dep_* (bsl-language-server, designer-ibcmd, answer42).
# Контракт (spec «Per-stack deps-check хук»):
#   env:  CONSUMER_ROOT, HARNESS_ROOT, INSTALL, STACK_DEPS (id через пробел)
#   cwd:  consumer root
#   stdout: статусные строки формата dep_* (OK/WARN/FAIL)
#   exit: 0 при OK и при WARN-only; != 0 → fail в init-kit-deps
set -euo pipefail

CONSUMER_ROOT="${CONSUMER_ROOT:-.}"
HARNESS_ROOT="${HARNESS_ROOT:-$CONSUMER_ROOT/harness}"
STACK_DEPS="${STACK_DEPS:-}"

have() { command -v "$1" >/dev/null 2>&1; }

dep_answer42() {
  if [[ -e "$CONSUMER_ROOT/tools/answer42" ]]; then echo "OK answer42 (consumer tools/)"
  else echo "WARN answer42 не слинкован (tools/answer42) — bootstrap-kit"; fi
}

dep_bsl_language_server() {
  local bslls_py="" bslls_script bslls_out bslls_rc
  if have python3; then bslls_py="python3"; elif have python; then bslls_py="python"; fi
  bslls_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tools/bsl-check/check-bsl.py"
  [[ -f "$bslls_script" ]] || bslls_script="$HARNESS_ROOT/stacks/1c/tools/bsl-check/check-bsl.py"
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

for d in $STACK_DEPS; do
  fn="dep_${d//-/_}"
  if declare -F "$fn" >/dev/null; then "$fn"
  else echo "WARN unknown dep id: $d (нет check-функции в deps-check стека)"; fi
done

exit 0
