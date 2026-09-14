#!/usr/bin/env bash
# Check (and optionally install) kit host PATH tools. Never openspec init / rtk init.
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
OPENSPEC_PKG="@fission-ai/openspec@1.2.0"

if kit_is_windows; then
  args=(-ConsumerRoot "$(cd "$CONSUMER_ROOT" && pwd)")
  [[ "$INSTALL" == "1" ]] && args+=(-Install)
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/init-kit-deps.ps1" "${args[@]}"
fi

CONSUMER_ROOT="$(cd "$CONSUMER_ROOT" && pwd)"
fail=0

have() { command -v "$1" >/dev/null 2>&1; }

echo "NEVER: openspec init  (own openspec/ + kit skills)"
echo "NEVER: rtk init       (writes CLAUDE.md)"
echo "NEVER: rtk init -g    (Claude hook; Cursor prefixes rtk itself)"
echo "=== check ==="

if have git; then echo "OK git"; else echo "FAIL missing: git"; fail=1; fi

if have node; then
  maj="$(node -v | sed 's/^v//;s/\..*//')"
  maj="${maj:-0}"
  if [[ "$maj" -ge 18 ]]; then echo "OK node $(node -v)"; else
    echo "FAIL node $(node -v) (need 18+, prefer 20)"; fail=1
  fi
else
  echo "FAIL missing: node (Node 20; slot image already has it)"
  fail=1
fi

if have npm; then echo "OK npm"; else echo "FAIL missing: npm"; fail=1; fi

if have openspec; then echo "OK openspec"; else
  echo "FAIL missing: openspec  (npm i -g $OPENSPEC_PKG)"
  fail=1
  if [[ "$INSTALL" == "1" ]] && have npm; then
    echo "install $OPENSPEC_PKG"
    npm install -g "$OPENSPEC_PKG" || true
  fi
fi

if have rtk; then echo "OK rtk"; else
  echo "FAIL missing: rtk  (https://github.com/rtk-ai/rtk — поставь вручную, как удобно)"
  fail=1
fi

if have rg; then echo "OK rg"; else
  echo "FAIL missing: rg  (apt install ripgrep)"
  fail=1
fi

echo "=== consumer ==="
if [[ -d "$CONSUMER_ROOT/openspec" ]]; then
  echo "OK openspec/ (from git, not init)"
else
  echo "FAIL missing: openspec/  — merge consumer branch; NEVER openspec init"
  fail=1
fi
if [[ -f "$CONSUMER_ROOT/.env" ]]; then echo "OK .env"; else echo "WARN missing .env"; fi

if [[ -f "$CONSUMER_ROOT/.git" && -f "$CONSUMER_ROOT/harness/.git" ]]; then
  line="$(head -n1 "$CONSUMER_ROOT/harness/.git" | tr -d '\r')"
  if [[ "$line" == *'../.git/modules/harness'* ]]; then
    echo "FAIL harness gitdir relative ../.git/modules/harness — run fix-harness-gitdir"
    fail=1
  fi
fi

if have python || have python3; then echo "OK python"; else echo "WARN python not on PATH"; fi
if have qmd; then echo "OK qmd"; else echo "WARN qmd not on PATH"; fi
if have docker; then echo "OK docker"; else echo "WARN docker not on PATH"; fi
if have unzip; then echo "OK unzip"; else echo "WARN unzip not on PATH (BSLLS download)"; fi

bslls_py=""
if have python3; then bslls_py="python3"
elif have python; then bslls_py="python"
fi
bslls_script="$CONSUMER_ROOT/harness/tools/bsl-check/check-bsl.py"
if [[ ! -f "$bslls_script" ]]; then
  bslls_script="$CONSUMER_ROOT/tools/bsl-check/check-bsl.py"
fi
if [[ -z "$bslls_py" ]]; then
  echo "WARN BSLLS: no python to run check-bsl.py --which"
elif [[ ! -f "$bslls_script" ]]; then
  echo "WARN BSLLS: check-bsl.py missing"
else
  bslls_out=""
  bslls_rc=0
  bslls_out="$("$bslls_py" "$bslls_script" --which 2>&1)" || bslls_rc=$?
  if [[ "$bslls_rc" -eq 0 ]]; then
    echo "OK BSLLS $bslls_out"
  else
    echo "WARN BSLLS runtime missing"
    printf '%s\n' "$bslls_out"
  fi
fi

echo "see harness/docs/ai/kit-host-deps.md"
if [[ "$fail" -ne 0 ]]; then exit 1; fi
echo "init-kit-deps: OK"
