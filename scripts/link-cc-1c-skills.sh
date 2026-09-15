#!/usr/bin/env bash
# Link .cursor/skills/<name> -> harness/skills/cc-1c/<name> (Linux ln -sfn).
# On Windows/Git Bash: delegates to link-cc-1c-skills.ps1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_link-common.sh
source "$SCRIPT_DIR/_link-common.sh"

CONSUMER_ROOT="${1:-.}"
HARNESS_REL="${HARNESS_REL:-harness}"
LOCAL_MANIFEST="${2:-tools/cc-1c-skills-sync/local-skills.txt}"
DRY_RUN="${DRY_RUN:-0}"

if kit_is_windows; then
  PS1="$SCRIPT_DIR/link-cc-1c-skills.ps1"
  args=(-ConsumerRoot "$(cd "$CONSUMER_ROOT" && pwd)" -HarnessRel "$HARNESS_REL" -LocalManifest "$(cd "$CONSUMER_ROOT" && pwd)/$LOCAL_MANIFEST")
  [[ "$DRY_RUN" == "1" ]] && args+=(-DryRun)
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1" "${args[@]}"
fi

CONSUMER_ROOT="$(cd "$CONSUMER_ROOT" && pwd)"
HARNESS_ROOT="$CONSUMER_ROOT/$HARNESS_REL"
KIT_SKILLS="$HARNESS_ROOT/skills/cc-1c"
CURSOR_SKILLS="$CONSUMER_ROOT/.cursor/skills"
MANIFEST="$CONSUMER_ROOT/$LOCAL_MANIFEST"

[[ -d "$KIT_SKILLS" ]] || { echo "missing kit skills: $KIT_SKILLS" >&2; exit 1; }
mkdir -p "$CURSOR_SKILLS"

declare -A local_names=()
kit_load_manifest "$MANIFEST" local_names

for d in "$KIT_SKILLS"/*; do
  [[ -d "$d" ]] || continue
  name="$(basename "$d")"
  if [[ -n "${local_names[$name]:-}" ]]; then
    echo "SKIP LOCAL: $name"
    continue
  fi
  kit_ln_sfn "$d" "$CURSOR_SKILLS/$name"
done

# Prune kit-owned links whose skill vanished upstream (tombstones).
kit_prune_stale_links "$CURSOR_SKILLS" "$KIT_SKILLS" local_names

echo "Done."
