#!/usr/bin/env bash
# Guard: BOM-less *.ps1 must be pure ASCII.
# PS 5.1 reads BOM-less .ps1 as ANSI (CP1251 on ru hosts): UTF-8 bytes of
# non-ASCII (e.g. em-dash U+2014 -> 0x94) decode to smart quotes that the
# parser treats as string terminators -> ParserError TerminatorExpectedAtEndOfString.
# A file WITH UTF-8 BOM (EF BB BF) is read as UTF-8 correctly - non-ASCII allowed.
# Rule: BOM-less => ASCII-only (comments too); BOM => anything goes.
# Usage: check-ps1-ascii.sh [dir]   (recursive; default: dir of this script)
set -euo pipefail

DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
fail=0

while IFS= read -r f; do
  # skip files with UTF-8 BOM
  if [[ "$(head -c3 "$f" | od -An -tx1 | tr -d ' \n')" == "efbbbf" ]]; then
    continue
  fi
  # bytes outside printable ASCII + tab/CR/LF
  if LC_ALL=C grep -q '[^ -~	]' "$f"; then
    echo "FAIL non-ASCII (BOM-less): $f" >&2
    LC_ALL=C grep -n '[^ -~	]' "$f" | head -5 >&2 || true
    fail=1
  fi
done < <(find "$DIR" -name '*.ps1' -type f)

if [[ "$fail" -ne 0 ]]; then
  echo "check-ps1-ascii: refuse. BOM-less + non-ASCII + PS 5.1 + ANSI host = ParserError." >&2
  echo "Either keep the file pure ASCII or save it with UTF-8 BOM." >&2
  exit 1
fi
echo "check-ps1-ascii: OK"
