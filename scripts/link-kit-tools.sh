#!/usr/bin/env bash
# Link consumer tools/* -> harness/{core,stacks/<s>}/tools/* (Linux ln -sfn).
# Стековые источники — только при выбранных стеках (.kit.json); без него — legacy.
# On Windows/Git Bash: delegates to link-kit-tools.ps1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_link-common.sh
source "$SCRIPT_DIR/_link-common.sh"

CONSUMER_ROOT="${1:-.}"
HARNESS_REL="${HARNESS_REL:-harness}"
LOCAL_MANIFEST="${2:-}"
DRY_RUN="${DRY_RUN:-0}"

CONSUMER_ROOT="$(cd "$CONSUMER_ROOT" && pwd)"
[[ -n "$LOCAL_MANIFEST" ]] || LOCAL_MANIFEST="$(kit_local_manifest_rel "$CONSUMER_ROOT" tools)"
case "$LOCAL_MANIFEST" in
  /*|[A-Za-z]:*) MANIFEST="$LOCAL_MANIFEST" ;;
  *) MANIFEST="$CONSUMER_ROOT/$LOCAL_MANIFEST" ;;
esac

if kit_is_windows; then
  PS1="$SCRIPT_DIR/link-kit-tools.ps1"
  args=(-ConsumerRoot "$CONSUMER_ROOT" -HarnessRel "$HARNESS_REL" -LocalManifest "$MANIFEST")
  [[ "$DRY_RUN" == "1" ]] && args+=(-DryRun)
  ps_exe="$(kit_powershell)" || { echo "ERROR: PowerShell не найден (Windows-ветка kit идёт через .ps1)" >&2; exit 1; }
  exec "$ps_exe" -NoProfile -ExecutionPolicy Bypass -File "$PS1" "${args[@]}"
fi

HARNESS_ROOT="$CONSUMER_ROOT/$HARNESS_REL"
CORE_TOOLS="$HARNESS_ROOT/core/tools"
TOOLS_1C="$HARNESS_ROOT/stacks/1c/tools"
KIT_TOOLS="$HARNESS_ROOT/tools"   # kit-internal (legacy-совместимость)
CONSUMER_TOOLS="$CONSUMER_ROOT/tools"
managed=()

mkdir -p "$CONSUMER_TOOLS"

declare -A local_names=()
kit_load_manifest "$MANIFEST" local_names

# name:srcdir — core всем; стековые по выбору; docs-links — legacy-экстра.
linkable=("sandbox:$CORE_TOOLS" "docs-links:$KIT_TOOLS")
sel_rc=0
kit_stack_selected "$CONSUMER_ROOT" "1c" || sel_rc=$?
case "$sel_rc" in
  0)
    for name in bsl-check load-changed-files mcp-call answer42 rights-xml-lint; do
      linkable+=("$name:$TOOLS_1C")
    done
    ;;
  1) ;;
  *) exit 1 ;;
esac

declare -A srcdirs=()
for e in "${linkable[@]}"; do
  name="${e%%:*}"; src="${e##*:}"
  srcdirs["$src"]=1
  if [[ -n "${local_names[$name]:-}" ]]; then
    echo "SKIP LOCAL: $name"
    continue
  fi
  target="$src/$name"
  [[ -d "$target" ]] || { echo "SKIP missing in kit: $name"; continue; }
  kit_ln_sfn "$target" "$CONSUMER_TOOLS/$name"
  managed+=("tools/$name")
done

if [[ -z "${local_names[git-partial-stage.py]:-}" && -f "$CORE_TOOLS/git-partial-stage.py" ]]; then
  kit_ln_sfn "$CORE_TOOLS/git-partial-stage.py" "$CONSUMER_TOOLS/git-partial-stage.py"
  managed+=("tools/git-partial-stage.py")
fi

# Prune kit-owned links whose tool vanished upstream (tombstones), per source.
for src in "${!srcdirs[@]}"; do
  kit_prune_stale_links "$CONSUMER_TOOLS" "$src" local_names
done

kit_update_gitignore "$CONSUMER_ROOT" "kit-tools" ${managed[@]+"${managed[@]}"}

echo "Done."
