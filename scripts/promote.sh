#!/usr/bin/env bash
# Promote: commit+push kit from consumer's harness/, then bump gitlink SHA.
# Does not auto-push the consumer repo. Does not bump other projects.

set -euo pipefail

CONSUMER="${1:-}"
MSG="${2:-chore(kit): promote from consumer}"
EXTRA_PATHS=("${@:3}")

if [[ -z "$CONSUMER" ]]; then
  echo "Usage: scripts/promote.sh /path/to/consumer-repo [commit-message] [consumer-rel-path ...]" >&2
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

# Copy-fallback paths: правки по ссылкам и так лежат в harness/, а фолбэки —
# реальные файлы потребителя; маппим обратно через engine resolve-source.
if [[ "${#EXTRA_PATHS[@]}" -gt 0 ]]; then
  PY="$(command -v python || command -v python3 || true)"
  KL="$CONSUMER/harness/tools/kit-layout/kit_layout.py"
  if [[ -z "$PY" || ! -f "$KL" ]]; then
    echo "WARN: no python / kit_layout.py — resolve-source пропущен" >&2
  fi
  for rel in ${EXTRA_PATHS[@]+"${EXTRA_PATHS[@]}"}; do
    if [[ -n "$PY" && -f "$KL" ]] && \
       src="$("$PY" "$KL" resolve-source "$rel" --root "$CONSUMER" --harness-rel harness 2>&1)"; then
      echo "resolve-source: $rel -> $src"
      echo "  перенеси правку в kit: $CONSUMER/harness/$src (или поправь исходник и перелинкуй)"
    else
      echo "WARN resolve-source: $rel — не удалось отмапить (правь kit-side исходник вручную)" >&2
    fi
  done
fi
