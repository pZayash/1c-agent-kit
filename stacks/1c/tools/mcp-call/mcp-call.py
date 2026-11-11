#!/usr/bin/env python3
"""Делегат в mcp-call.sh (обратная совместимость и старый allowlist).

Предпочтительный вызов: bash tools/mcp-call/mcp-call.sh
Allowlist: Bash(bash tools/mcp-call/mcp-call.sh:*)
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    sh = Path(__file__).with_name("mcp-call.sh")
    if not sh.is_file():
        print(f"Не найден: {sh}", file=sys.stderr)
        return 4
    cmd = ["bash", str(sh), *(argv if argv is not None else sys.argv[1:])]
    return subprocess.call(cmd)


if __name__ == "__main__":
    raise SystemExit(main())
