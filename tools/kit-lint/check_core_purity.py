#!/usr/bin/env python3
"""Purity-lint core-слоя kit: harness/core/cursor/{skills,rules} MUST NOT
содержать стеко-специфичных ссылок. Generic-указатель компаньона
(`.cursor/skills/<name>-<s>/SKILL.md`) и литерал `1c-agent-kit` (имя
репозитория) — whitelist, вырезаются перед матчем.

Паттерны: conf/ | cfe.xml | \bИБ\b | \bBSL\b | метадан | .bsl |
bsl-check | cc-1c | \b1[cс]\b (кириллическое «1с» тоже) |
^####\\s+stack\\s*: (стековые секции в core запрещены).

Exit 0 — чисто, exit 1 — находки. В kit — гейт (CI); в kit-doctor — WARN.

Использование:
    python tools/kit-lint/check_core_purity.py [KIT_ROOT]
"""

import re
import sys
from pathlib import Path

PATTERNS = re.compile(
    r"conf/|cfe\.xml|\bИБ\b|\bBSL\b|метадан|\.bsl|bsl-check|cc-1c"
    r"|\b(?i:1[cс])\b|^####\s+stack\s*:", re.IGNORECASE)
# Whitelist, вырезается из строки ДО матча:
#  - литерал имени репозитория;
#  - generic-указатель компаньона .cursor/skills/<name>-<s>/SKILL.md.
WHITELIST = [
    re.compile(r"1c-agent-kit"),
    re.compile(r"\.cursor/skills/[^\s/]+-<s>"),
]

SCAN_DIRS = ("core/cursor/skills", "core/cursor/rules")
SCAN_GLOBS = ("*.md", "*.mdc")


def iter_files(kit_root: Path):
    for rel in SCAN_DIRS:
        base = kit_root / rel
        if not base.is_dir():
            continue
        for glob in SCAN_GLOBS:
            yield from sorted(base.rglob(glob))


def flagged_lines(path: Path):
    """Yield (lineno, line, match) для находок вне whitelist."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for n, line in enumerate(lines, 1):
        rest = line
        for w in WHITELIST:
            rest = w.sub("", rest)
        m = PATTERNS.search(rest)
        if m:
            yield n, line, m.group(0)


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="replace")
    kit_root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else (
        Path(__file__).resolve().parents[2]
    )
    findings = []
    for path in iter_files(kit_root):
        for n, line, match in flagged_lines(path):
            findings.append((path.relative_to(kit_root), n, match, line.strip()))
    for rel, n, match, text in findings:
        print(f"{rel}:{n}: [{match}] {text[:160]}")
    if findings:
        print(f"\ncore-purity: {len(findings)} находок", file=sys.stderr)
        return 1
    print("core-purity: чисто")
    return 0


if __name__ == "__main__":
    sys.exit(main())
