#!/usr/bin/env bash
# Link harness/cursor overlay into consumer .cursor/ (Linux ln -sfn).
# On Windows/Git Bash: delegates to link-cursor-overlay.ps1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_link-common.sh
source "$SCRIPT_DIR/_link-common.sh"

CONSUMER_ROOT="${1:-.}"
HARNESS_REL="${HARNESS_REL:-harness}"
LOCAL_MANIFEST="${2:-tools/cc-1c-skills-sync/local-overlay.txt}"
DRY_RUN="${DRY_RUN:-0}"

if kit_is_windows; then
  PS1="$SCRIPT_DIR/link-cursor-overlay.ps1"
  root="$(cd "$CONSUMER_ROOT" && pwd)"
  args=(-ConsumerRoot "$root" -HarnessRel "$HARNESS_REL")
  [[ -f "$root/$LOCAL_MANIFEST" ]] && args+=(-LocalManifest "$root/$LOCAL_MANIFEST")
  [[ "$DRY_RUN" == "1" ]] && args+=(-DryRun)
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1" "${args[@]}"
fi

CONSUMER_ROOT="$(cd "$CONSUMER_ROOT" && pwd)"
HARNESS_ROOT="$CONSUMER_ROOT/$HARNESS_REL"
OVERLAY="$HARNESS_ROOT/cursor"
MANIFEST="$CONSUMER_ROOT/$LOCAL_MANIFEST"
managed=()

[[ -d "$OVERLAY" ]] || { echo "missing overlay: $OVERLAY" >&2; exit 1; }
mkdir -p "$CONSUMER_ROOT/.cursor/skills" "$CONSUMER_ROOT/.cursor/rules" "$CONSUMER_ROOT/.cursor/commands"

declare -A local_names=()
kit_load_manifest "$MANIFEST" local_names

if [[ -d "$OVERLAY/skills" ]]; then
  for d in "$OVERLAY/skills"/*; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    if [[ -n "${local_names[$name]:-}" ]]; then
      echo "SKIP LOCAL: $name"
      continue
    fi
    kit_ln_sfn "$d" "$CONSUMER_ROOT/.cursor/skills/$name"
    managed+=(".cursor/skills/$name")
  done
  kit_prune_stale_links "$CONSUMER_ROOT/.cursor/skills" "$OVERLAY/skills" local_names
fi

if [[ -d "$OVERLAY/rules" ]]; then
  for f in "$OVERLAY/rules"/*; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    if [[ -n "${local_names[$name]:-}" ]]; then
      echo "SKIP LOCAL: $name"
      continue
    fi
    kit_ln_sfn "$f" "$CONSUMER_ROOT/.cursor/rules/$name"
    managed+=(".cursor/rules/$name")
  done
  kit_prune_stale_links "$CONSUMER_ROOT/.cursor/rules" "$OVERLAY/rules" local_names
fi

if [[ -d "$OVERLAY/commands" ]]; then
  for f in "$OVERLAY/commands"/*; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    if [[ -n "${local_names[$name]:-}" ]]; then
      echo "SKIP LOCAL: $name"
      continue
    fi
    kit_ln_sfn "$f" "$CONSUMER_ROOT/.cursor/commands/$name"
    managed+=(".cursor/commands/$name")
  done
  kit_prune_stale_links "$CONSUMER_ROOT/.cursor/commands" "$OVERLAY/commands" local_names
fi

kit_update_gitignore "$CONSUMER_ROOT" "cursor-overlay" ${managed[@]+"${managed[@]}"}

echo "Done."
