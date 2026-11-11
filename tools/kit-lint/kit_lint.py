#!/usr/bin/env python3
"""kit-lint: структурные правила стеков и реестров kit.

Правила (все находки — WARN-уровень семантики; exit 1 при любой, чтобы
doctor мог отразить; в kit-CI это гейт):
- stacks/<s>/stack.json: layout_version int >= 1 и <= SUPPORTED
  (lint валидирует ВСЕ стеки; engine — только effective);
- стек без единого публикуемого ресурса (0 каноничных каталогов и
  0 явных записей) -> WARN;
- стек с deps, не покрытыми core dep_* (id сравнивается после
  нормализации '-' -> '_'), без deps-check.{sh,ps1} (нужны оба файла)
  -> WARN;
- duplicate explicit vs synthesized resources (engine) -> FAIL.

Использование:
    python tools/kit-lint/kit_lint.py [KIT_ROOT]
"""

import json
import re
import sys
from pathlib import Path

_HERE = Path(__file__).resolve()
sys.path.insert(0, str(_HERE.parent.parent / "kit-layout"))
import kit_layout as kl  # noqa: E402

DEP_ID = re.compile(r"\bdep_([A-Za-z0-9_]+)")


def core_dep_ids(kit_root: Path):
    """dep_* id, реализованные core-скриптами init-kit-deps (sh+ps1)."""
    ids = set()
    for rel in ("scripts/init-kit-deps.sh", "scripts/init-kit-deps.ps1"):
        p = kit_root / rel
        if p.is_file():
            ids.update(DEP_ID.findall(
                p.read_text(encoding="utf-8", errors="replace")))
    return ids


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="replace")
    kit_root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else (
        Path(__file__).resolve().parents[2]
    )
    findings = []

    layout_path = kit_root / "tools" / "kit-layout" / "layout.json"
    resources = []
    if layout_path.is_file():
        if not (kit_root / ".git").exists():
            print("WARN: kit without .git — synthesized resources resolved "
                  "from disk only", file=sys.stderr)
        resources, errors, warns = kl.all_layout_resources(
            json.loads(layout_path.read_text(encoding="utf-8")), kit_root)
        findings += [("FAIL", e) for e in errors]
        findings += [("WARN", w) for w in warns]

    stack_ids = [sj.parent.name
                 for sj in kit_root.glob("stacks/*/stack.json")]
    claimed = {}
    for r in resources:
        for s in r.get("stacks") or []:
            # '*' resources publish to every stack - count for all ids.
            for sid in (stack_ids if s == '*' else [s]):
                claimed[sid] = claimed.get(sid, 0) + 1
    dep_ids = core_dep_ids(kit_root)

    for sj in sorted(kit_root.glob("stacks/*/stack.json")):
        s = sj.parent.name
        try:
            meta = json.loads(sj.read_text(encoding="utf-8"))
        except ValueError as e:
            findings.append(("FAIL", f"stacks/{s}/stack.json: {e}"))
            continue
        v = meta.get("layout_version")
        if v is not None:
            if type(v) is not int or v < 1:
                findings.append(("FAIL", f"stacks/{s}/stack.json: "
                                         f'"layout_version" must be int >= 1'))
            elif v > kl.SUPPORTED_LAYOUT_VERSION:
                findings.append(("FAIL", f"stacks/{s}/stack.json: "
                                         f"layout_version {v} > поддерживаемого "
                                         f"{kl.SUPPORTED_LAYOUT_VERSION}"))
        if claimed.get(s, 0) == 0:
            findings.append(("WARN", f'stack "{s}": no publishable resources'))
        unhandled = [d for d in (meta.get("deps") or [])
                     if d.replace("-", "_") not in dep_ids]
        if unhandled:
            missing = [n for n in ("deps-check.sh", "deps-check.ps1")
                       if not (sj.parent / n).is_file()]
            if missing:
                findings.append((
                    "WARN",
                    f'stack "{s}": deps {unhandled} not covered by core '
                    f'dep_* and missing {", ".join(missing)}'))

    for level, msg in findings:
        print(f"{level}: {msg}")
    if findings:
        print(f"\nkit-lint: {len(findings)} находок", file=sys.stderr)
        return 1
    print("kit-lint: чисто")
    return 0


if __name__ == "__main__":
    sys.exit(main())
