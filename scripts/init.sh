#!/usr/bin/env bash
# Dry helper: print (or run with --apply) git submodule add for this kit.
# Does not copy docs from a consumer/pilot repo.

set -euo pipefail

APPLY=0
KIT_URL="${KIT_URL:-}"
TARGET="${1:-}"

usage() {
  cat <<'EOF'
Usage: scripts/init.sh [--apply] /path/to/consumer-repo

  KIT_URL  clone URL of 1c-agent-kit (required for --apply)

Without --apply: print commands only.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "--apply" ]]; then
  APPLY=1
  TARGET="${2:-}"
fi
if [[ -z "$TARGET" ]]; then
  usage
  exit 1
fi

if [[ ! -d "$TARGET/.git" ]]; then
  echo "not a git repo: $TARGET" >&2
  exit 1
fi

if [[ -e "$TARGET/harness" ]]; then
  echo "already exists: $TARGET/harness" >&2
  exit 1
fi

if [[ -z "$KIT_URL" ]]; then
  KIT_URL="$(git -C "$(dirname "$0")/.." remote get-url origin 2>/dev/null || true)"
fi
if [[ -z "$KIT_URL" ]]; then
  KIT_URL="/path/to/1c-agent-kit.git"
fi

cmds=$(cat <<EOF
git -C "$TARGET" submodule add "$KIT_URL" harness
git -C "$TARGET" submodule update --init
# copy hook: cp harness/hooks/pre-commit-harness "$TARGET/.githooks/"
# source it from .githooks/pre-commit
EOF
)

echo "$cmds"
if [[ "$APPLY" -eq 1 ]]; then
  if [[ "$KIT_URL" == "/path/to/1c-agent-kit.git" ]]; then
    echo "set KIT_URL to a real clone URL" >&2
    exit 1
  fi
  git -C "$TARGET" submodule add "$KIT_URL" harness
  git -C "$TARGET" submodule update --init
fi
