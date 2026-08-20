#!/usr/bin/env bash
# Editor skill roots: .agents/skills and .claude/skills|commands -> .cursor/*
# Cursor UI reads .agents/skills; kit junctions live in .cursor/skills.
# On Windows/Git Bash: delegates to link-editor-roots.ps1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_link-common.sh
source "$SCRIPT_DIR/_link-common.sh"

CONSUMER_ROOT="${1:-.}"
DRY_RUN="${DRY_RUN:-0}"

if kit_is_windows; then
  args=(-ConsumerRoot "$(cd "$CONSUMER_ROOT" && pwd)")
  [[ "$DRY_RUN" == "1" ]] && args+=(-DryRun)
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/link-editor-roots.ps1" "${args[@]}"
fi

CONSUMER_ROOT="$(cd "$CONSUMER_ROOT" && pwd)"
CURSOR_SKILLS="$CONSUMER_ROOT/.cursor/skills"
CURSOR_CMDS="$CONSUMER_ROOT/.cursor/commands"

if [[ -d "$CURSOR_SKILLS" ]]; then
  mkdir -p "$CONSUMER_ROOT/.agents" "$CONSUMER_ROOT/.claude"
  kit_ln_sfn "$CURSOR_SKILLS" "$CONSUMER_ROOT/.agents/skills"
  kit_ln_sfn "$CURSOR_SKILLS" "$CONSUMER_ROOT/.claude/skills"
else
  echo "SKIP editor skill roots (no .cursor/skills)"
fi

if [[ -d "$CURSOR_CMDS" ]]; then
  mkdir -p "$CONSUMER_ROOT/.claude"
  kit_ln_sfn "$CURSOR_CMDS" "$CONSUMER_ROOT/.claude/commands"
fi

echo "Done."
