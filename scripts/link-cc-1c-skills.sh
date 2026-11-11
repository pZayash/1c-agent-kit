#!/usr/bin/env bash
# Link .cursor/skills/<name> -> harness/stacks/1c/skills/<name> (Linux ln -sfn).
# 1C-часть — только при выбранном стеке "1c" (.kit.json); без .kit.json — legacy.
# On Windows/Git Bash: delegates to link-cc-1c-skills.ps1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_link-common.sh
source "$SCRIPT_DIR/_link-common.sh"

CONSUMER_ROOT="${1:-.}"
HARNESS_REL="${HARNESS_REL:-harness}"
LOCAL_MANIFEST="${2:-}"
DRY_RUN="${DRY_RUN:-0}"

CONSUMER_ROOT="$(cd "$CONSUMER_ROOT" && pwd)"
[[ -n "$LOCAL_MANIFEST" ]] || LOCAL_MANIFEST="$(kit_local_manifest_rel "$CONSUMER_ROOT" skills)"
case "$LOCAL_MANIFEST" in
  /*|[A-Za-z]:*) MANIFEST="$LOCAL_MANIFEST" ;;
  *) MANIFEST="$CONSUMER_ROOT/$LOCAL_MANIFEST" ;;
esac

if kit_is_windows; then
  PS1="$SCRIPT_DIR/link-cc-1c-skills.ps1"
  args=(-ConsumerRoot "$CONSUMER_ROOT" -HarnessRel "$HARNESS_REL" -LocalManifest "$MANIFEST")
  [[ "$DRY_RUN" == "1" ]] && args+=(-DryRun)
  ps_exe="$(kit_powershell)" || { echo "ERROR: PowerShell не найден (Windows-ветка kit идёт через .ps1)" >&2; exit 1; }
  exec "$ps_exe" -NoProfile -ExecutionPolicy Bypass -File "$PS1" "${args[@]}"
fi

HARNESS_ROOT="$CONSUMER_ROOT/$HARNESS_REL"
KIT_SKILLS="$HARNESS_ROOT/stacks/1c/skills"
CURSOR_SKILLS="$CONSUMER_ROOT/.cursor/skills"

# Стеко-гейт: конфиг только через print-config (kit_effective_stacks).
sel_rc=0
kit_stack_selected "$CONSUMER_ROOT" "1c" || sel_rc=$?
case "$sel_rc" in
  0) ;;
  1) echo "SKIP: стек 1c не выбран в .kit.json"; exit 0 ;;
  *) exit 1 ;;
esac

[[ -d "$KIT_SKILLS" ]] || { echo "missing kit skills: $KIT_SKILLS" >&2; exit 1; }
mkdir -p "$CURSOR_SKILLS"

declare -A local_names=()
kit_load_manifest "$MANIFEST" local_names
managed=()

for d in "$KIT_SKILLS"/*; do
  [[ -d "$d" ]] || continue
  name="$(basename "$d")"
  if [[ -n "${local_names[$name]:-}" ]]; then
    echo "SKIP LOCAL: $name"
    continue
  fi
  kit_ln_sfn "$d" "$CURSOR_SKILLS/$name"
  managed+=(".cursor/skills/$name")
done

# Prune kit-owned links whose skill vanished upstream (tombstones).
kit_prune_stale_links "$CURSOR_SKILLS" "$KIT_SKILLS" local_names

kit_update_gitignore "$CONSUMER_ROOT" "cc-1c-skills" ${managed[@]+"${managed[@]}"}

echo "Done."
