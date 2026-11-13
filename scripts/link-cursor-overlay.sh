#!/usr/bin/env bash
# Link harness/{core,stacks/<s>}/cursor overlay into consumer .cursor/ (Linux ln -sfn).
# Стековые источники — только при выбранных стеках (.kit.json); без него — legacy (всё).
# On Windows/Git Bash: delegates to link-cursor-overlay.ps1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_link-common.sh
source "$SCRIPT_DIR/_link-common.sh"

CONSUMER_ROOT="${1:-.}"
HARNESS_REL="${HARNESS_REL:-harness}"
LOCAL_MANIFEST="${2:-}"
DRY_RUN="${DRY_RUN:-0}"

CONSUMER_ROOT="$(cd "$CONSUMER_ROOT" && pwd)"
[[ -n "$LOCAL_MANIFEST" ]] || LOCAL_MANIFEST="$(kit_local_manifest_rel "$CONSUMER_ROOT" overlay)"
case "$LOCAL_MANIFEST" in
  /*|[A-Za-z]:*) MANIFEST="$LOCAL_MANIFEST" ;;
  *) MANIFEST="$CONSUMER_ROOT/$LOCAL_MANIFEST" ;;
esac

if kit_is_windows; then
  PS1="$SCRIPT_DIR/link-cursor-overlay.ps1"
  args=(-ConsumerRoot "$CONSUMER_ROOT" -HarnessRel "$HARNESS_REL" -LocalManifest "$MANIFEST")
  [[ "$DRY_RUN" == "1" ]] && args+=(-DryRun)
  [[ "${KIT_REPLACE_COPIES:-0}" == "1" ]] && args+=(-ReplaceCopies)
  ps_exe="$(kit_powershell)" || { echo "ERROR: PowerShell не найден (Windows-ветка kit идёт через .ps1)" >&2; exit 1; }
  exec "$ps_exe" -NoProfile -ExecutionPolicy Bypass -File "$PS1" "${args[@]}"
fi

HARNESS_ROOT="$CONSUMER_ROOT/$HARNESS_REL"
managed=()

# Источники: core всегда; стеки — по выбору (.kit.json через print-config).
OVERLAYS=("$HARNESS_ROOT/core/cursor")
sel_rc=0
kit_stack_selected "$CONSUMER_ROOT" "1c" || sel_rc=$?
case "$sel_rc" in
  0) OVERLAYS+=("$HARNESS_ROOT/stacks/1c/cursor") ;;
  1) ;;
  *) exit 1 ;;
esac

mkdir -p "$CONSUMER_ROOT/.cursor/skills" "$CONSUMER_ROOT/.cursor/rules" "$CONSUMER_ROOT/.cursor/commands"

declare -A local_names=()
kit_load_manifest "$MANIFEST" local_names

found=0
for OVERLAY in "${OVERLAYS[@]}"; do
  [[ -d "$OVERLAY" ]] || continue
  found=1

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
done

[[ "$found" == "1" ]] || { echo "missing overlay: ${OVERLAYS[*]}" >&2; exit 1; }

kit_update_gitignore "$CONSUMER_ROOT" "cursor-overlay" ${managed[@]+"${managed[@]}"}

echo "Done."
