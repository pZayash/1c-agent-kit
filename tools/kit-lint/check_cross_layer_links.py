#!/usr/bin/env python3
"""Cross-layer link lint для kit: резолв КАЖДОЙ relative-ссылки
(markdown `[text](target)`) в файлах `core/**` и `stacks/**`.

FAIL если:
- ссылка резолвится внутрь kit, но файл не существует;
- из `core/` ссылка резолвится в `stacks/` (core не знает о стеках;
  обратное — stacks -> core — разрешено);
- относительная ссылка выходит за корень потребителя.

Семантика резолва — **смонтированный потребитель** (layout.json):
файлы `*/cursor/skills/<n>` читаются агентом как `.cursor/skills/<n>`,
`*/cursor/{rules,commands}` → `.cursor/{rules,commands}`,
`*/tools/<n>` → `tools/<n>`, `*/skills/<n>` (вендорные) → `.cursor/skills/<n>`.
Немонтируемые файлы (docs/, templates/, kit-internal tools) читаются
как `harness/<rel>`. Ссылка резолвится от смонтированного пути:
- результат под `harness/` — цель внутри kit: проверяем существование
  и слой;
- результат вне `harness/` и внутри корня потребителя — цель на стороне
  потребителя (его `docs/ai`, `memory/`, `AGENTS.md`): пропускаем
  (потребитель ведёт заглушки по docs-layout);
- результат внутри `.cursor/`, `tools/` и т.п. — транслируем обратно
  через mount-таблицу в kit-путь и проверяем существование; если
  consumer-ребёнок не из kit — это consumer-owned файл, пропускаем;
- `..` выше корня — FAIL.

Grep-паттерн по `../` недопустим: `../../cursor/…` из `core/docs/ai/`
валиден — резолв только через normpath по смонтированному пути.

Ссылки в fenced-блоках ``` и inline-коде не проверяются.
Anchors (`#section`) отрезаются. `http(s):`, `mailto:`, абсолютные `/`
и `\\` пути пропускаются.

Exit 0 — чисто, exit 1 — находки. В kit — гейт; в kit-doctor — WARN.

Использование:
    python tools/kit-lint/check_cross_layer_links.py [KIT_ROOT]
"""

import json
import re
import subprocess
import sys
from pathlib import Path

SCAN_DIRS = ("core", "stacks")
SCAN_GLOBS = ("*.md", "*.mdc")
# Корни алиас-монтирования: consumer-пути под ними либо kit-ссылки,
# либо файлы потребителя — транслируем через mount-таблицу.
ALIAS_ROOTS = (".cursor", ".claude", ".agents", ".pi", ".kilo",
               ".opencode", "tools")

FENCED = re.compile(r"^(```|~~~)")
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(\s*<([^>]+)>\s*(?:\"[^\"]*\"\s*)?\)|"
                  r"(?<!!)\[[^\]]*\]\(\s*([^\s)]+)")
SKIP_SCHEMES = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")

_HERE = Path(__file__).resolve()
sys.path.insert(0, str(_HERE.parent.parent / "kit-layout"))
import kit_layout  # noqa: E402  (pure functions only; stdlib)


def load_mounts(kit_root: Path):
    """(source_prefix, target_prefix, kind) из layout.json + convention-
    synthesized stack resources (engine, не сырой JSON). Kit без .git —
    синтез по диску + WARN."""
    layout = kit_root / "tools" / "kit-layout" / "layout.json"
    mounts = []
    if layout.is_file():
        if not (kit_root / ".git").exists():
            print("WARN: kit without .git — synthesized resources resolved "
                  "from disk only", file=sys.stderr)
        resources, errors = kit_layout.all_layout_resources(
            json.loads(layout.read_text(encoding="utf-8")), kit_root)
        for e in errors:
            print(f"WARN: {e}", file=sys.stderr)
        for res in resources:
            src = res["source"].rstrip("/")
            if src.startswith("harness/"):
                src = src[len("harness/"):]
            mounts.append((src, res["target"].rstrip("/"), res["kind"]))
    mounts.sort(key=lambda m: -len(m[0]))
    return mounts


def mounted_path(kit_rel: str, mounts) -> str:
    """Consumer-путь файла: через самый длинный подходящий source-
    префикс; немонтируемое — harness/<rel>."""
    for src, tgt, kind in mounts:
        if kind == "alias":
            continue
        if kit_rel.startswith(src + "/"):
            rest = kit_rel[len(src) + 1:]
            if kind == "child-files" and "/" in rest:
                continue  # child-files монтирует только файлы 1-го уровня
            return f"{tgt}/{rest}"
    return f"harness/{kit_rel}"


def norm_join(base: str, target: str):
    """normpath(base/target) как список сегментов; None если выше корня."""
    parts = []
    for p in (base + "/" + target).replace("\\", "/").split("/"):
        if p == "..":
            if not parts:
                return None
            parts.pop()
        elif p not in ("", "."):
            parts.append(p)
    return parts


def kit_path_via_mounts(parts, mounts, kit_root: Path):
    """Consumer-путь под alias-корнем -> (kit_rels | None, provided).

    provided=False — ребёнок не поставляется ни одним kit-ресурсом
    (consumer-owned файл/каталог): пропускаем. provided=True — ребёнок
    из kit; kit_rels — все существующие кандидаты, либо первый
    кандидат, если конкретный путь внутри ребёнка не найден (missing).
    Несколько ресурсов могут монтироваться в один target
    (.cursor/skills <- core + stacks): пробуем все кандидаты."""
    joined = "/".join(parts)
    candidates = []
    for src, tgt, kind in mounts:
        if kind == "alias":
            continue
        if not joined.startswith(tgt + "/"):
            continue
        rest = joined[len(tgt) + 1:]
        if kind == "child-files":
            if "/" in rest:
                continue
            # child-files: «предоставлен» только реально существующий файл —
            # иначе это consumer-owned правило/команда.
            if (kit_root / src / rest).exists():
                candidates.append(f"{src}/{rest}")
        else:
            child = rest.split("/", 1)[0]
            if (kit_root / src / child).exists():
                candidates.append(f"{src}/{rest}")
    existing = [c for c in candidates if (kit_root / c).exists()]
    if existing:
        return existing, True
    if candidates:
        return candidates[:1], True
    return None, False


def tracked_files(kit_root: Path):
    try:
        out = subprocess.run(
            ["git", "-C", str(kit_root), "ls-files", "-z", "--",
             *SCAN_DIRS],
            capture_output=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return {p for p in out.decode("utf-8", "replace").split("\0") if p}


def iter_files(kit_root: Path):
    tracked = tracked_files(kit_root)
    for rel in SCAN_DIRS:
        base = kit_root / rel
        if not base.is_dir():
            continue
        for glob in SCAN_GLOBS:
            for path in sorted(base.rglob(glob)):
                rel = path.relative_to(kit_root).as_posix()
                if tracked is not None and rel not in tracked:
                    continue
                yield path, rel


def strip_code(lines):
    """Yield (lineno, text) без fenced-блоков и inline-кода."""
    fenced = False
    for n, line in enumerate(lines, 1):
        if FENCED.match(line.strip()):
            fenced = not fenced
            continue
        if fenced:
            continue
        yield n, re.sub(r"`[^`]*`", "", line)


def check_file(kit_root: Path, rel: str, mounts):
    """Yield (lineno, why, target)."""
    path = kit_root / rel
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return
    in_core = rel.startswith("core/")
    m_dir = str(Path(mounted_path(rel, mounts)).parent).replace("\\", "/")
    for n, line in strip_code(lines):
        for m in LINK.finditer(line):
            target = (m.group(1) or m.group(2) or "").strip()
            target = target.split("#", 1)[0].strip()
            if not target or SKIP_SCHEMES.match(target):
                continue
            if target.startswith(("/", "\\")):
                continue
            parts = norm_join(m_dir, target)
            if parts is None:
                yield n, "escapes consumer root", target
                continue
            if parts[0] == "harness":
                kit_rels = ["/".join(parts[1:])]
            elif parts[0] in ALIAS_ROOTS:
                kit_rels, provided = kit_path_via_mounts(
                    parts, mounts, kit_root)
                if not provided:
                    continue  # consumer-owned файл под alias-корнем
            else:
                continue  # цель на стороне потребителя
            if in_core and all(r.split("/", 1)[0] == "stacks"
                               for r in kit_rels):
                yield n, "cross-layer core->stacks", target
            elif not any((kit_root / r).exists() for r in kit_rels):
                yield n, "missing", target


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="replace")
    kit_root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else (
        Path(__file__).resolve().parents[2]
    )
    mounts = load_mounts(kit_root)
    findings = []
    for path, rel in iter_files(kit_root):
        for n, why, target in check_file(kit_root, rel, mounts):
            findings.append((rel, n, why, target))
    for rel, n, why, target in findings:
        print(f"{rel}:{n}: [{why}] {target[:160]}")
    if findings:
        print(f"\ncross-layer-links: {len(findings)} находок",
              file=sys.stderr)
        return 1
    print("cross-layer-links: чисто")
    return 0


if __name__ == "__main__":
    sys.exit(main())
