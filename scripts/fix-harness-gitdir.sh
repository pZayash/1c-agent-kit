#!/usr/bin/env bash
# Rewrite harness/.git for git worktrees (consumer .git is a file).
#
# Usage:
#   bash harness/scripts/fix-harness-gitdir.sh [ConsumerRoot]
# Env:
#   HARNESS_REL=harness
#   COPY_FROM=/path/to/other/worktree/modules/harness  — copy gitdir if missing
#   DRY_RUN=1
set -euo pipefail

CONSUMER_ROOT="$(cd "${1:-.}" && pwd)"
HARNESS_REL="${HARNESS_REL:-harness}"
DRY_RUN="${DRY_RUN:-0}"
GIT_FILE="$CONSUMER_ROOT/.git"
HARNESS_DIR="$CONSUMER_ROOT/$HARNESS_REL"
HARNESS_GIT="$HARNESS_DIR/.git"

if [[ ! -e "$GIT_FILE" ]]; then
  echo "FAIL: no .git at $CONSUMER_ROOT" >&2
  exit 1
fi

abs_from_rel() {
  local base="$1" rel="$2"
  if [[ "$rel" = /* ]]; then
    echo "$rel"
  else
    (cd "$base" && cd "$rel" && pwd)
  fi
}

if [[ -f "$GIT_FILE" ]]; then
  line="$(head -n1 "$GIT_FILE" | tr -d '\r')"
  raw="${line#gitdir:}"
  raw="$(echo "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  WT_GITDIR="$(abs_from_rel "$CONSUMER_ROOT" "$raw")"
elif [[ -d "$GIT_FILE" ]]; then
  WT_GITDIR="$GIT_FILE"
else
  echo "FAIL: $GIT_FILE is neither file nor directory" >&2
  exit 1
fi

CANDIDATE_WT="$WT_GITDIR/modules/harness"
CANDIDATE_COMMON=""
if [[ -f "$WT_GITDIR/commondir" ]]; then
  common_raw="$(head -n1 "$WT_GITDIR/commondir" | tr -d '\r')"
  COMMON_ABS="$(abs_from_rel "$WT_GITDIR" "$common_raw")"
  CANDIDATE_COMMON="$COMMON_ABS/modules/harness"
fi

TARGET=""
if [[ -d "$CANDIDATE_WT" ]]; then
  TARGET="$CANDIDATE_WT"
elif [[ -n "${COPY_FROM:-}" ]]; then
  if [[ ! -d "$COPY_FROM" ]]; then
    echo "FAIL: COPY_FROM not a directory: $COPY_FROM" >&2
    exit 1
  fi
  echo "copy modules/harness from $COPY_FROM -> $CANDIDATE_WT"
  if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$(dirname "$CANDIDATE_WT")"
    cp -a "$COPY_FROM" "$CANDIDATE_WT"
  fi
  TARGET="$CANDIDATE_WT"
elif [[ -n "$CANDIDATE_COMMON" && -d "$CANDIDATE_COMMON" ]]; then
  TARGET="$CANDIDATE_COMMON"
  echo "WARN: using shared $TARGET (not worktree-local). Checkout SHA here moves HEAD for every consumer of this gitdir." >&2
else
  echo "FAIL: harness gitdir missing." >&2
  echo "  tried: $CANDIDATE_WT" >&2
  [[ -n "$CANDIDATE_COMMON" ]] && echo "  tried: $CANDIDATE_COMMON" >&2
  echo "  fix: COPY_FROM=<other-wt>/modules/harness or git submodule update --init after git works" >&2
  echo "  emergency: mv $HARNESS_DIR ${HARNESS_DIR}.bak  (unblocks parent git)" >&2
  exit 1
fi

echo "consumer .git -> $WT_GITDIR"
echo "harness gitdir -> $TARGET"

if [[ -f "$GIT_FILE" ]]; then
  current="$(head -n1 "$HARNESS_GIT" 2>/dev/null | tr -d '\r' || true)"
  if [[ "$current" == "gitdir: ../.git/modules/harness" || "$current" == "gitdir: ../.git/modules/harness/" ]]; then
    echo "PITFALL: relative gitdir ../.git/modules/harness with file-gitdir (parent git broken on Windows)"
  fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN: would write $HARNESS_GIT"
  exit 0
fi

mkdir -p "$HARNESS_DIR"
printf 'gitdir: %s\n' "$TARGET" > "$HARNESS_GIT"
echo "wrote $HARNESS_GIT"
