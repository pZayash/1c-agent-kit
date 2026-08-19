#!/usr/bin/env bash
# Link harness/cursor overlay into consumer .cursor/
set -euo pipefail

CONSUMER_ROOT="${1:-.}"
LOCAL_MANIFEST="${2:-tools/cc-1c-skills-sync/local-overlay.txt}"
HARNESS_REL="${HARNESS_REL:-harness}"
DRY_RUN="${DRY_RUN:-0}"

PS1="$(cd "$(dirname "$0")" && pwd)/link-cursor-overlay.ps1"
args=(-ConsumerRoot "$(cd "$CONSUMER_ROOT" && pwd)" -HarnessRel "$HARNESS_REL")
if [[ -n "$LOCAL_MANIFEST" && -f "$CONSUMER_ROOT/$LOCAL_MANIFEST" ]]; then
  args+=(-LocalManifest "$(cd "$CONSUMER_ROOT" && pwd)/$LOCAL_MANIFEST")
fi
if [[ "$DRY_RUN" == "1" ]]; then
  args+=(-DryRun)
fi
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1" "${args[@]}"
