#!/usr/bin/env bash
# Verify key kit links are symlinks (Linux) / reparse (Win via .ps1).
# Exit 1 if a required path exists as a plain directory/file (copy), or missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_link-common.sh
source "$SCRIPT_DIR/_link-common.sh"

CONSUMER_ROOT="${1:-.}"
HARNESS_REL="${HARNESS_REL:-harness}"

if kit_is_windows; then
  ps_exe="$(kit_powershell)" || { echo "ERROR: PowerShell не найден (Windows-ветка kit идёт через .ps1)" >&2; exit 1; }
  exec "$ps_exe" -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/verify-kit-links.ps1" \
    -ConsumerRoot "$(cd "$CONSUMER_ROOT" && pwd)"
fi

CONSUMER_ROOT="$(cd "$CONSUMER_ROOT" && pwd)"
LOCAL_TOOLS="$CONSUMER_ROOT/tools/cc-1c-skills-sync/local-tools.txt"

declare -A local_tools=()
kit_load_manifest "$LOCAL_TOOLS" local_tools

fail=0
foreign=0
inside=0
check_link() {
  local path="$1"
  local label="$2"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    echo "FAIL missing: $label ($path)" >&2
    fail=1
    return
  fi
  if [[ ! -L "$path" ]]; then
    echo "FAIL not symlink (copy?): $label ($path)" >&2
    fail=1
    return
  fi
  # A link into another namespace (Windows checkout seen from a Linux
  # sandbox) cannot be validated here; it is not a broken consumer layout.
  if kit_link_is_foreign "$CONSUMER_ROOT" "$path"; then
    echo "SKIP FOREIGN-NS: $label -> $(readlink "$path") (layout from another namespace; run on the host)"
    foreign=$((foreign + 1))
    return
  fi
  inside=$((inside + 1))
  echo "OK $label -> $(readlink "$path")"
}

check_link "$CONSUMER_ROOT/.cursor/skills/handoff" "skills/handoff"
check_link "$CONSUMER_ROOT/tools/answer42" "tools/answer42"

if [[ -z "${local_tools[load-changed-files]:-}" ]]; then
  check_link "$CONSUMER_ROOT/tools/load-changed-files" "tools/load-changed-files"
else
  echo "SKIP LOCAL tools/load-changed-files"
fi

check_link "$CONSUMER_ROOT/.agents/skills" ".agents/skills"
if [[ -e "$CONSUMER_ROOT/.cursor/skills/explore/SKILL.md" || -L "$CONSUMER_ROOT/.cursor/skills/explore" ]]; then
  if [[ -f "$CONSUMER_ROOT/.agents/skills/explore/SKILL.md" ]]; then
    echo "OK .agents/skills/explore/SKILL.md"
  elif kit_link_is_foreign "$CONSUMER_ROOT" "$CONSUMER_ROOT/.agents/skills"; then
    echo "SKIP FOREIGN-NS: .agents/skills/explore/SKILL.md (layout from another namespace; run on the host)"
  else
    echo "FAIL missing: .agents/skills/explore/SKILL.md" >&2
    fail=1
  fi
fi

check_link "$CONSUMER_ROOT/.pi/skills" ".pi/skills"
check_link "$CONSUMER_ROOT/.pi/prompts" ".pi/prompts"
check_link "$CONSUMER_ROOT/.pi/extensions" ".pi/extensions"

if [[ "$foreign" -gt 0 && "$inside" -eq 0 ]]; then
  echo "WARN: all $foreign checked link(s) are FOREIGN-NS - verify-kit-links cannot validate this namespace" >&2
  echo "      run on the host (Git Bash / PowerShell), not through tools/sandbox/run.sh" >&2
fi

exit "$fail"
