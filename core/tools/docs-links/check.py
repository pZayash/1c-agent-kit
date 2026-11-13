#!/usr/bin/env python3
"""docs-links — граф ссылок документации: битые ссылки и достижимость от входа.

Термины (русский канон первым, английский — синоним для поиска):
  точка входа (entry) — файл(ы), с которых начинается обход, обычно `AGENTS.md`;
  оглавление (TOC) — `docs/README.md`, `memory/INDEX.md`, `README.md` каталога;
  висячий документ (dangling) — ноль входящих ссылок от других документов;
  недостижимый (unreachable) — не достигается от точки входа по цепочке ссылок;
  заглушка (stub) — короткий файл «перенесено в kit», ссылки внутрь не проверяем;
  ссылка на каталог (dir-link) — ведёт на папку, а не на файл.

Режимы:
  report — полный аудит (числа + списки), по умолчанию не падает;
  check  — то же, но печатает находки построчно и годится для хука/CI;
           `--strict` → exit 1 при ошибках.

Конфиг: `.docs-links.json` в корне репозитория (необязателен, дефолты в коде).
Запуск: `python tools/docs-links/check.py report`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote

DEFAULT_CONFIG: dict = {
    "entry": ["AGENTS.md"],
    "roots": [
        "AGENTS.md",
        "README.md",
        "CLAUDE.md",
        "CONTEXT.md",
        "TAGS.md",
        "ROLES.md",
        "memory.md",
        "docs",
        "memory",
        "research",
        "tools",
        "docker",
        "scripts",
        "tests",
        ".cursor/commands",
        ".cursor/agents",
        ".cursor/rules",
    ],
    "exclude": [
        ".git/",
        "node_modules/",
        "tmp/",
        ".tmp/",
        "outputs/",
        "handoffs/",
        "specs/",
        "openspec/",
        "harness/",
        "conf/",
        "cfe.xml/",
        "cfe.local/",
        "унфТиповая.xml/",
        "унфТиповаяРБ.xml/",
        "docs/1c-help/",
        "docs/bsl-graph/",
        "docs/conf-help/",
        "git-commit-summary/",
        ".cursor/skills/",
        "tools/bsl-check/",
        "tools/cc-1c-skills/",
        "tools/skillopt/",
        "tools/business-info-generator/",
        "tools/bb-bitrix-bridge/",
    ],
    "stubs": {
        "max_bytes": 700,
        "markers": ["перенесено в kit", "перенесен в kit", "канон:"],
    },
    "severity": {
        "broken": "error",
        "untracked-target": "warning",
        "anchor": "error",
        "unreachable": "error",
        "dangling": "warning",
        "dir-link": "warning",
    },
    "max_per_section": 15,
    "untracked_targets": True,
}

LINK_RE = re.compile(r"!?\[[^\]]*\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+[\"'][^\"']*[\"'])?\s*\)")
REF_RE = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(\S+)")
HREF_RE = re.compile(r"<a\s[^>]*href=[\"']([^\"']+)[\"']", re.IGNORECASE)
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")
SCHEME_RE = re.compile(r"^(https?:|mailto:|tel:|ftp:|data:|javascript:)", re.IGNORECASE)
WINDOWS_ABS_RE = re.compile(r"^[a-zA-Z]:[\\/]")
FENCE_RE = re.compile(r"^\s*(```|~~~)")


@dataclass(frozen=True)
class Finding:
    kind: str
    file: str
    line: int | None
    message: str

    @property
    def severity(self) -> str:
        return SEVERITY.get(self.kind, "warning")

    def format_line(self) -> str:
        loc = self.file if self.line is None else f"{self.file}:{self.line}"
        return f"docs-links: {loc}: {self.severity}: {self.message}"


@dataclass
class Audit:
    root: Path
    nodes: list[str]
    stubs: set[str]
    edges: dict[str, set[str]]
    inbound: dict[str, int]
    reachable: set[str]
    findings: list[Finding]
    link_count: int

    def of_kind(self, kind: str) -> list[Finding]:
        return [f for f in self.findings if f.kind == kind]


SEVERITY: dict[str, str] = {}


def norm(path: str) -> str:
    return path.replace("\\", "/")


def deep_merge(base: dict, overlay: dict) -> dict:
    result = dict(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def load_config(root: Path, explicit: str | None) -> dict:
    path = Path(explicit) if explicit else root / ".docs-links.json"
    if explicit and not path.is_file():
        raise SystemExit(f"docs-links: конфиг не найден: {path}")
    if not path.is_file():
        return dict(DEFAULT_CONFIG)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"docs-links: битый JSON в {path}: {exc}") from exc
    return deep_merge(DEFAULT_CONFIG, data)


def is_excluded(rel: str, exclude: list[str]) -> bool:
    return any(rel == prefix.rstrip("/") or rel.startswith(prefix) for prefix in exclude)


def under_roots(rel: str, roots: list[str]) -> bool:
    for root in roots:
        r = norm(root).rstrip("/")
        if rel == r or rel.startswith(r + "/"):
            return True
    return False


def list_tracked(root: Path) -> list[str] | None:
    """Git-файлы .md: в индексе и неигнорируемые новые (ещё не закоммичены)."""
    try:
        proc = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.md"],
            cwd=root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    return [norm(p) for p in proc.stdout.split("\0") if p]


def list_tracked_paths(root: Path) -> set[str] | None:
    """Все git-пути (файлы): отличить «вне git» от битой ссылки."""
    try:
        proc = subprocess.run(
            ["git", "ls-files", "-z"],
            cwd=root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    return {norm(p) for p in proc.stdout.split("\0") if p}


def is_tracked_target(rel: str, tracked: set[str]) -> bool:
    """Цель в git: сам файл или каталог, под которым есть отслеживаемые файлы."""
    if rel in tracked:
        return True
    prefix = rel.rstrip("/") + "/"
    return any(p.startswith(prefix) for p in tracked)


def walk_md(root: Path) -> list[str]:
    found: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git" and d != "node_modules"]
        for name in filenames:
            if name.lower().endswith(".md"):
                found.append(norm(str(Path(dirpath, name).relative_to(root))))
    return found


def gather_nodes(root: Path, config: dict) -> list[str]:
    if "roots" not in config or not config["roots"]:
        return []
    tracked = list_tracked(root)
    candidates = tracked if tracked is not None else walk_md(root)
    roots = [norm(r) for r in config["roots"]]
    exclude = [norm(e) for e in config["exclude"]]
    nodes = [
        rel
        for rel in candidates
        if under_roots(rel, roots) and not is_excluded(rel, exclude) and (root / rel).is_file()
    ]
    return sorted(set(nodes))


def is_stub(root: Path, rel: str, config: dict) -> bool:
    path = root / rel
    try:
        if path.stat().st_size >= int(config["stubs"]["max_bytes"]):
            return False
        text = path.read_text(encoding="utf-8", errors="replace").lower()
    except OSError:
        return False
    return any(marker.lower() in text for marker in config["stubs"]["markers"])


def slug(text: str) -> str:
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"[`*_~]", "", text)
    text = text.strip().lower()
    text = re.sub(r"[^\w\s-]", "", text, flags=re.UNICODE)
    return re.sub(r"\s+", "-", text)


def heading_anchors(path: Path) -> set[str]:
    anchors: set[str] = set()
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return anchors
    in_fence = False
    for line in text.splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        match = re.match(r"^(#{1,6})\s+(.*)$", line)
        if match:
            anchors.add(slug(match.group(2)))
    return anchors


def extract_targets(text: str):
    """(строка, цель) — без содержимого код-фенсов и inline-кода."""
    in_fence = False
    for lineno, line in enumerate(text.splitlines(), start=1):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        clean = INLINE_CODE_RE.sub("", line)
        for match in LINK_RE.finditer(clean):
            yield lineno, match.group(1).strip("<>")
        ref = REF_RE.match(clean)
        if ref:
            yield lineno, ref.group(1)
        for match in HREF_RE.finditer(clean):
            yield lineno, match.group(1)


def analyze(root: Path, config: dict) -> Audit:
    global SEVERITY
    SEVERITY = config["severity"]
    nodes = gather_nodes(root, config)
    node_set = set(nodes)
    lowered = {n.lower(): n for n in nodes}
    stubs = {n for n in nodes if is_stub(root, n, config)}

    edges: dict[str, set[str]] = {n: set() for n in nodes}
    inbound: dict[str, int] = {n: 0 for n in nodes}
    findings: list[Finding] = []
    link_count = 0
    anchor_cache: dict[str, set[str]] = {}
    tracked_paths = (
        list_tracked_paths(root) if config.get("untracked_targets", True) else None
    )

    for src in nodes:
        try:
            text = (root / src).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for lineno, raw in extract_targets(text):
            target = raw.strip()
            if not target or target.startswith("#"):
                continue
            if SCHEME_RE.match(target) or WINDOWS_ABS_RE.match(target):
                continue
            link_count += 1
            hash_pos = target.find("#")
            anchor = target[hash_pos + 1 :] if hash_pos >= 0 else ""
            path_part = target[:hash_pos] if hash_pos >= 0 else target
            path_part = path_part.split("?")[0].replace("\\", "/")
            try:
                path_part = unquote(path_part)
            except ValueError:
                pass
            if not path_part:
                continue
            # normpath, не resolve: симлинк (CLAUDE.md → AGENTS.md) должен
            # оставаться собственной целью, иначе документ «теряется».
            abs_target = Path(
                os.path.normpath(
                    str(root / path_part.lstrip("/"))
                    if path_part.startswith("/")
                    else str((root / src).parent / path_part)
                )
            )
            try:
                rel_target = norm(str(abs_target.relative_to(root.resolve())))
            except ValueError:
                findings.append(
                    Finding("broken", src, lineno, f"битая ссылка: {target} (вне репозитория)")
                )
                continue
            if not abs_target.exists():
                if tracked_paths is not None and not is_tracked_target(rel_target, tracked_paths):
                    # Цель вне git (handoffs/, сгенерированные выгрузки, xlsx/docx):
                    # у автора локально работает, у остальных — никогда. Warning,
                    # не error: текстом такое не лечится — либо артефакт в git,
                    # либо ссылки быть не должно.
                    findings.append(
                        Finding(
                            "untracked-target",
                            src,
                            lineno,
                            f"ссылка на путь вне git: {target} -> {rel_target}",
                        )
                    )
                else:
                    findings.append(
                        Finding("broken", src, lineno, f"битая ссылка: {target} -> {rel_target}")
                    )
                continue
            if abs_target.is_dir():
                # Ссылка на каталог допустима, если у него нет оглавления.
                # Есть README/index — вести надо на него, иначе читатель
                # получает список файлов вместо TOC.
                index = next(
                    (name for name in ("README.md", "index.md") if (abs_target / name).is_file()),
                    None,
                )
                if index:
                    findings.append(
                        Finding(
                            "dir-link",
                            src,
                            lineno,
                            f"ссылка на каталог: {target} (есть {index})",
                        )
                    )
                continue
            real_target = lowered.get(rel_target.lower())
            if real_target is None:
                # Файл существует, но вне области аудита (код, kit, specs…).
                continue
            edges[src].add(real_target)
            inbound[real_target] = inbound.get(real_target, 0) + 1
            if anchor:
                if real_target not in anchor_cache:
                    anchor_cache[real_target] = heading_anchors(root / real_target)
                if slug(anchor) not in anchor_cache[real_target]:
                    findings.append(
                        Finding("anchor", src, lineno, f"битый якорь: {target}")
                    )

    reachable: set[str] = set()
    queue: deque[str] = deque()
    for entry in config["entry"]:
        entry_rel = norm(entry)
        if entry_rel in node_set:
            reachable.add(entry_rel)
            queue.append(entry_rel)
    while queue:
        current = queue.popleft()
        for target in edges.get(current, ()):
            if target not in reachable:
                reachable.add(target)
                queue.append(target)

    for node in nodes:
        if node in stubs:
            continue
        if node not in reachable:
            entry_list = ", ".join(config["entry"])
            findings.append(
                Finding("unreachable", node, None, f"недостижим от точки входа ({entry_list})")
            )
        if inbound.get(node, 0) == 0 and node not in config["entry"]:
            findings.append(
                Finding("dangling", node, None, "висячий документ: 0 входящих ссылок")
            )

    findings.sort(key=lambda f: (f.file, f.line or 0, f.kind))
    return Audit(root, nodes, stubs, edges, inbound, reachable, findings, link_count)


def report(audit: Audit, args: argparse.Namespace) -> int:
    kinds = [
        ("broken", "Битые ссылки"),
        ("anchor", "Битые якоря"),
        ("unreachable", "Недостижимые от точки входа"),
        ("dangling", "Висячие документы"),
        ("dir-link", "Ссылки на каталог"),
    ]
    counts = {kind: len(audit.of_kind(kind)) for kind, _ in kinds}
    if args.json:
        payload = {
            "root": str(audit.root),
            "documents": len(audit.nodes),
            "stubs": len(audit.stubs),
            "links": audit.link_count,
            "counts": counts,
            "findings": [
                {"kind": f.kind, "file": f.file, "line": f.line, "message": f.message}
                for f in audit.findings
            ],
        }
        print(json.dumps(payload, ensure_ascii=False, indent=1))
        return 0

    print(f"docs-links: точка входа: {', '.join(args._config['entry'])}")
    print(f"Документов: {len(audit.nodes)} (заглушек: {len(audit.stubs)})")
    print(f"Внутренних ссылок: {audit.link_count}")
    for kind, title in kinds:
        print(f"{title}: {counts[kind]}")

    for kind, title in kinds:
        items = audit.of_kind(kind)
        if not items:
            continue
        print(f"\n## {title}")
        shown = items if args.all else items[: args.max_per_section]
        for finding in shown:
            loc = finding.file if finding.line is None else f"{finding.file}:{finding.line}"
            print(f"- {loc} — {finding.message}")
        if len(items) > len(shown):
            print(f"- … ещё {len(items) - len(shown)} (--all или --json)")

    errors = sum(1 for f in audit.findings if f.severity == "error")
    if errors:
        print(f"\nОшибок: {errors}. Режим --strict вернёт exit 1.")
    return 0


def check(audit: Audit, args: argparse.Namespace) -> int:
    selected = audit.findings
    if args.files:
        changed = {norm(f) for f in args.files}
        selected = [f for f in selected if f.file in changed]
    for finding in selected:
        print(finding.format_line())
    errors = sum(1 for f in selected if f.severity == "error")
    if errors:
        print(f"docs-links: ошибок {errors}", file=sys.stderr)
    if args.strict and errors:
        return 1
    return 0


def parse_note(path: Path) -> tuple[str | None, list[str]]:
    """Заголовок (H1) и теги записи памяти."""
    title: str | None = None
    tags: list[str] = []
    in_tags = False
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None, tags
    for line in text.splitlines():
        if in_tags:
            if line.startswith("## "):
                in_tags = False
            elif line.strip():
                tags.extend(part.strip() for part in re.split(r"[,;]", line) if part.strip())
        if title is None and line.startswith("# "):
            title = line[2:].strip()
        if re.match(r"^##\s+Теги", line, re.IGNORECASE):
            in_tags = True
    return title, tags


def command_index(args: argparse.Namespace, config: dict) -> int:
    root = Path(args.root).resolve()
    source = norm(args.path or config.get("index_source", "memory"))
    out_rel = norm(args.out or config.get("index_path", "memory/INDEX.md"))
    source_dir = root / source
    if not source_dir.is_dir():
        raise SystemExit(f"docs-links: нет каталога индекса: {source_dir}")
    notes = sorted(
        p
        for p in source_dir.rglob("*.md")
        if norm(str(p.relative_to(root))) != out_rel
        # README самого каталога индекса — шаблон/формат, не запись; README
        # подкаталогов — обычные документы.
        and not (p.parent == source_dir and p.name == "README.md")
    )
    # Группа: месяц из имени файла; иначе первый подкаталог; иначе «без даты».
    groups: dict[str, list[tuple[Path, str | None, list[str]]]] = {}
    for note in notes:
        name = note.name
        rel_note = note.relative_to(source_dir)
        match = re.match(r"^(\d{4}-\d{2})-\d{2}", name)
        if match:
            group = match.group(1)
        elif len(rel_note.parts) > 1:
            group = rel_note.parts[0]
        else:
            group = "без даты"
        title, tags = parse_note(note)
        groups.setdefault(group, []).append((note, title, tags))

    title = config.get("index_title") or (
        "Индекс памяти" if source == "memory" else f"Индекс: {source}"
    )
    lines = [
        f"# {title}",
        "",
        "Автогенерируется: `python tools/docs-links/check.py index`.",
        "Руками не править — правь сам документ и перегенерируй.",
    ]
    if (source_dir / "README.md").is_file():
        lines.append("Формат записи: [README.md](README.md).")
    lines.extend(["", f"Всего записей: {len(notes)}.", ""])
    dated = sorted((g for g in groups if re.match(r"^\d{4}-\d{2}$", g)), reverse=True)
    named = sorted(g for g in groups if g not in dated and g != "без даты")
    ordered = dated + named + (["без даты"] if "без даты" in groups else [])
    for group in ordered:
        lines.append(f"## {group}")
        lines.append("")
        for note, title, tags in sorted(groups[group], key=lambda item: item[0].name, reverse=True):
            label = title or note.stem
            link = Path(os.path.relpath(note, (root / out_rel).parent)).as_posix()
            suffix = f" — теги: {', '.join(tags)}" if tags else ""
            lines.append(f"- [{label}]({link}){suffix}")
        lines.append("")
    target = root / out_rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    print(f"docs-links: индекс обновлён: {out_rel} ({len(notes)} записей)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="docs-links",
        description="Граф ссылок документации: битые ссылки и достижимость от точки входа.",
    )
    parser.add_argument("command", choices=["report", "check", "index"])
    parser.add_argument("--root", default=".", help="корень репозитория (по умолчанию текущий)")
    parser.add_argument("--config", default=None, help="путь к .docs-links.json")
    parser.add_argument("--files", nargs="*", default=None, help="только эти файлы (для check)")
    parser.add_argument("--path", default=None, help="каталог записей (для index)")
    parser.add_argument("--out", default=None, help="файл индекса (для index)")
    parser.add_argument("--json", action="store_true", help="машиночитаемый отчёт (report)")
    parser.add_argument("--all", action="store_true", help="не обрезать списки в report")
    parser.add_argument("--max-per-section", type=int, default=None)
    parser.add_argument("--strict", action="store_true", help="exit 1 при ошибках")
    return parser


def main(argv: list[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, OSError):
            pass
    args = build_parser().parse_args(argv)
    root = Path(args.root).resolve()
    if not root.is_dir():
        raise SystemExit(f"docs-links: корень не найден: {root}")
    config = load_config(root, args.config)
    if args.command == "index":
        return command_index(args, config)
    if args.max_per_section is None:
        args.max_per_section = int(config.get("max_per_section", 15))
    args._config = config
    audit = analyze(root, config)
    if args.command == "report":
        return report(audit, args)
    return check(audit, args)


if __name__ == "__main__":
    raise SystemExit(main())
