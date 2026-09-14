#!/usr/bin/env bash
# Promote: commit+push kit from consumer's harness/, then bump gitlink SHA.
# Does not auto-push the consumer repo. Does not bump other projects.

set -euo pipefail

CONSUMER="${1:-}"
MSG="${2:-chore(kit): promote from consumer}"

if [[ -z "$CONSUMER" ]]; then
  echo "Usage: scripts/promote.sh /path/to/consumer-repo [commit-message]" >&2
  exit 1
fi
if [[ ! -e "$CONSUMER/harness/.git" ]]; then
  echo "Expect submodule checkout at $CONSUMER/harness" >&2
  exit 1
fi

harness="$CONSUMER/harness"
git -C "$harness" add -A
if git -C "$harness" diff --cached --quiet; then
  echo "kit: nothing to commit"
else
  git -C "$harness" commit -m "$MSG"
  git -C "$harness" push
fi

# Stage gitlink only in consumer (do not commit unless user asks)
git -C "$CONSUMER" add harness
echo "consumer: staged harness gitlink. Commit in consumer repo yourself."
git -C "$CONSUMER" status -sb
