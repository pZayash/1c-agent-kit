#!/usr/bin/env bash
# Verify kit links declared in layout.json — single source of truth:
# tools/kit-layout/layout.json (resources[].include).
#
# Delegates to `kit_layout.py verify`, т.е. проверяется ровно тот же список, что
# создаёт `apply`. Раньше здесь был свой хардкод из трёх линков: tools/docs-links
# в нём отсутствовал и его потеря в раскладке проходила незамеченной (доктор
# рапортовал PASS, а чек docs-links был мёртв).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONSUMER_ROOT="${1:-.}"
HARNESS_REL="${HARNESS_REL:-harness}"
ENGINE="$SCRIPT_DIR/../tools/kit-layout/kit_layout.py"

PY="$(command -v python || command -v python3 || true)"
if [[ -z "$PY" ]]; then
  echo "ERROR: python не найден на PATH — verify идёт через kit-layout ($ENGINE)" >&2
  exit 1
fi
if [[ ! -f "$ENGINE" ]]; then
  echo "ERROR: не найден движок kit-layout: $ENGINE" >&2
  exit 1
fi

export PYTHONUTF8=1
exec "$PY" "$ENGINE" verify "$CONSUMER_ROOT" --harness-rel "$HARNESS_REL"
