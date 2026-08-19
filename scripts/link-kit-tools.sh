#!/usr/bin/env bash
# Junction consumer tools/* -> harness/tools/* (Windows mklink /J).
set -euo pipefail

CONSUMER_ROOT="${1:-.}"
HARNESS_REL="${HARNESS_REL:-harness}"
LOCAL_MANIFEST="${2:-tools/cc-1c-skills-sync/local-tools.txt}"
DRY_RUN="${DRY_RUN:-0}"

PS1="$(cd "$(dirname "$0")" && pwd)/link-kit-tools.ps1"
if [[ ! -f "$PS1" ]]; then
  echo "missing $PS1" >&2
  exit 1
fi

args=(-ConsumerRoot "$(cd "$CONSUMER_ROOT" && pwd)" -HarnessRel "$HARNESS_REL" -LocalManifest "$(cd "$CONSUMER_ROOT" && pwd)/$LOCAL_MANIFEST")
if [[ "$DRY_RUN" == "1" ]]; then
  args+=(-DryRun)
fi

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1" "${args[@]}"
