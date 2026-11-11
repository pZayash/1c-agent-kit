#!/usr/bin/env python3
"""Purity-lint core-слоя kit: harness/core/cursor/{skills,rules} MUST NOT
содержать стеко-специфичных ссылок вне секций `#### stack: <id>` и
компаньон-ссылок `skills/<name>-1c`.

Паттерны: conf/ | cfe.xml | \bИБ\b | \bBSL\b | метадан

Секция `#### stack:` вырезается целиком: от заголовка до следующего
заголовка уровня <= 4 (`#`..`####`) либо EOF. Строки-ссылки формата
`skills/<name>-1c` исключаются из проверки (компаньон-скиллы).

Exit 0 — чисто, exit 1 — находки. В kit — гейт (CI); в kit-doctor — WARN.

Использование:
    python tools/kit-lint/check_core_purity.py [KIT_ROOT]
"""

import re
import sys
from pathlib import Path

PATTERNS = re.compile(r"conf/|cfe\.xml|\bИБ\b|\bBSL\b|метадан")
STACK_SECTION = re.compile(r"^#{1,4}\s")
STACK_SECTION_START = re.compile(r"^####\s+stack\s*:", re.IGNORECASE)
# Компаньон-ссылка: skills/<name>-1c (точный паттерн, не *-1c вольно).
COMPANION_REF = re.compile(r"skills/[A-Za-z0-9_-]+-1c(?![A-Za-z0-9_-])")

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
    """Yield (lineno, line, match) для находок вне stack-секций."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    in_stack = False
    for n, line in enumerate(lines, 1):
        if STACK_SECTION_START.match(line):
            in_stack = True
            continue
        if in_stack:
            if STACK_SECTION.match(line):
                in_stack = False  # новый заголовок <= 4 уровня — секция кончилась
            else:
                continue
        # Вырезать компаньон-ссылки, проверить остаток строки.
        rest = COMPANION_REF.sub("", line)
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
