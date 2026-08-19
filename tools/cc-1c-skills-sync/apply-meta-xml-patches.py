#!/usr/bin/env python3
"""Re-apply meta-* XML patches after upstream sync (overlay trees in overlays/)."""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

KIT_ROOT = Path(__file__).resolve().parents[2]
OVERLAYS = Path(__file__).resolve().parent / "overlays"
TARGET = KIT_ROOT / "skills" / "cc-1c"
META = ("meta-edit", "meta-compile", "meta-validate")


def ignore(_d: str, names: list[str]) -> list[str]:
    return [n for n in names if n in ("node_modules", "__pycache__", ".git")]


def main() -> int:
    for name in META:
        src = OVERLAYS / name
        dst = TARGET / name
        if not src.is_dir():
            print(f"ERROR no overlay {src}", file=sys.stderr)
            return 1
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst, ignore=ignore)
        print(f"  overlay {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
