#!/usr/bin/env bash
# Pi harness roots для потребителя kit:
#   .pi/skills     -> .cursor/skills     (относительные ссылки из prompts)
#   .pi/prompts    -> .cursor/commands   (prompt templates /имя)
#   .pi/extensions -> harness/pi/extensions
# Навыки pi и так видит из .agents/skills (link-editor-roots).
# On Windows/Git Bash: delegates to link-pi-roots.ps1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_link-common.sh
source "$SCRIPT_DIR/_link-common.sh"

CONSUMER_ROOT="${1:-.}"
HARNESS_REL="${HARNESS_REL:-harness}"
DRY_RUN="${DRY_RUN:-0}"

if kit_is_windows; then
  args=(-ConsumerRoot "$(cd "$CONSUMER_ROOT" && pwd)" -HarnessRel "$HARNESS_REL")
  [[ "$DRY_RUN" == "1" ]] && args+=(-DryRun)
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/link-pi-roots.ps1" "${args[@]}"
fi

CONSUMER_ROOT="$(cd "$CONSUMER_ROOT" && pwd)"
HARNESS_ROOT="$CONSUMER_ROOT/$HARNESS_REL"
CURSOR_SKILLS="$CONSUMER_ROOT/.cursor/skills"
CURSOR_CMDS="$CONSUMER_ROOT/.cursor/commands"
KIT_EXT="$HARNESS_ROOT/pi/extensions"

if [[ -d "$CURSOR_SKILLS" ]]; then
  mkdir -p "$CONSUMER_ROOT/.pi"
  kit_ln_sfn "$CURSOR_SKILLS" "$CONSUMER_ROOT/.pi/skills"
else
  echo "SKIP .pi/skills (no .cursor/skills)"
fi

if [[ -d "$CURSOR_CMDS" ]]; then
  mkdir -p "$CONSUMER_ROOT/.pi"
  kit_ln_sfn "$CURSOR_CMDS" "$CONSUMER_ROOT/.pi/prompts"
else
  echo "SKIP .pi/prompts (no .cursor/commands)"
fi

if [[ -d "$KIT_EXT" ]]; then
  mkdir -p "$CONSUMER_ROOT/.pi"
  kit_ln_sfn "$KIT_EXT" "$CONSUMER_ROOT/.pi/extensions"
else
  echo "SKIP .pi/extensions (no $KIT_EXT)"
fi

echo "Done."
