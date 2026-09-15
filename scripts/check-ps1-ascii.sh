#!/usr/bin/env bash
# Guard: scripts/*.ps1 must be pure ASCII.
# PS 5.1 reads BOM-less .ps1 as ANSI (CP1251 on ru hosts): UTF-8 bytes of
# non-ASCII (e.g. em-dash U+2014 -> 0x94) decode to smart quotes that the
# parser treats as string terminators -> ParserError TerminatorExpectedAtEndOfString.
# Keep .ps1 ASCII-only (comments too). Run in kit repo root or pass dir.
set -euo pipefail

DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
fail=0

while IFS= read -r f; do
  # bytes outside printable ASCII + tab/CR/LF
  if LC_ALL=C grep -n '[^ -~	]' "$f" >/dev/null 2>&1; then
    echo "FAIL non-ASCII: $f" >&2
    LC_ALL=C grep -n '[^ -~	]' "$f" >&2 || true
    fail=1
  fi
done < <(find "$DIR" -maxdepth 1 -name '*.ps1' -type f)

if [[ "$fail" -ne 0 ]]; then
  echo "check-ps1-ascii: refuse. PS 5.1 + BOM-less UTF-8 + ANSI host = ParserError." >&2
  exit 1
fi
echo "check-ps1-ascii: OK"
