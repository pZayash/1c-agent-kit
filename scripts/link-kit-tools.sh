#!/usr/bin/env bash
# Link consumer tools/* -> harness/tools/* (Linux ln -sfn).
# On Windows/Git Bash: delegates to link-kit-tools.ps1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_link-common.sh
source "$SCRIPT_DIR/_link-common.sh"

CONSUMER_ROOT="${1:-.}"
HARNESS_REL="${HARNESS_REL:-harness}"
LOCAL_MANIFEST="${2:-tools/cc-1c-skills-sync/local-tools.txt}"
DRY_RUN="${DRY_RUN:-0}"

if kit_is_windows; then
  PS1="$SCRIPT_DIR/link-kit-tools.ps1"
  args=(-ConsumerRoot "$(cd "$CONSUMER_ROOT" && pwd)" -HarnessRel "$HARNESS_REL" -LocalManifest "$(cd "$CONSUMER_ROOT" && pwd)/$LOCAL_MANIFEST")
  [[ "$DRY_RUN" == "1" ]] && args+=(-DryRun)
  ps_exe="$(kit_powershell)" || { echo "ERROR: PowerShell не найден (Windows-ветка kit идёт через .ps1)" >&2; exit 1; }
  exec "$ps_exe" -NoProfile -ExecutionPolicy Bypass -File "$PS1" "${args[@]}"
fi

CONSUMER_ROOT="$(cd "$CONSUMER_ROOT" && pwd)"
HARNESS_ROOT="$CONSUMER_ROOT/$HARNESS_REL"
KIT_TOOLS="$HARNESS_ROOT/tools"
CONSUMER_TOOLS="$CONSUMER_ROOT/tools"
MANIFEST="$CONSUMER_ROOT/$LOCAL_MANIFEST"
managed=()

[[ -d "$KIT_TOOLS" ]] || { echo "missing kit tools: $KIT_TOOLS" >&2; exit 1; }
mkdir -p "$CONSUMER_TOOLS"

declare -A local_names=()
kit_load_manifest "$MANIFEST" local_names

for name in bsl-check sandbox load-changed-files mcp-call answer42; do
  if [[ -n "${local_names[$name]:-}" ]]; then
    echo "SKIP LOCAL: $name"
    continue
  fi
  target="$KIT_TOOLS/$name"
  [[ -d "$target" ]] || { echo "SKIP missing in kit: $name"; continue; }
  kit_ln_sfn "$target" "$CONSUMER_TOOLS/$name"
  managed+=("tools/$name")
done

if [[ -z "${local_names[git-partial-stage.py]:-}" && -f "$KIT_TOOLS/git-partial-stage.py" ]]; then
  kit_ln_sfn "$KIT_TOOLS/git-partial-stage.py" "$CONSUMER_TOOLS/git-partial-stage.py"
  managed+=("tools/git-partial-stage.py")
fi

# Prune kit-owned links whose tool vanished upstream (tombstones).
kit_prune_stale_links "$CONSUMER_TOOLS" "$KIT_TOOLS" local_names

kit_update_gitignore "$CONSUMER_ROOT" "kit-tools" ${managed[@]+"${managed[@]}"}

echo "Done."
