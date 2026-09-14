#!/usr/bin/env python3
"""Sync upstream cc-1c-skills into kit skills/cc-1c/ (1c-agent-kit).

Upstream clone: tools/cc-1c-skills (gitignore).
Consumer projects link via harness/scripts/link-cc-1c-skills.

See openspec/changes/cc-1c-skills-in-kit/
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UPSTREAM = ROOT / "tools" / "cc-1c-skills"
SWITCH = UPSTREAM / "scripts" / "switch.py"
TARGET = ROOT / "skills" / "cc-1c"
MANIFEST = Path(__file__).resolve().parent / "last-sync.json"
APPLY_META = Path(__file__).resolve().parent / "apply-meta-xml-patches.py"
META_SKILLS = frozenset({"meta-edit", "meta-compile", "meta-validate"})

EXCLUDED_SKILLS = frozenset({
    "db-load-cf",
    "db-load-dt",
    "db-load-git",
    "db-load-xml",
    "db-update",
    "db-dump-dt",
})

# Slice 1: no web-test in kit (fork stays LOCAL at consumer)
SKIP_SKILLS = EXCLUDED_SKILLS | frozenset({"web-test"})

RX_PS = re.compile(
    r"powershell\.exe\s+"
    r"(?:-NoProfile\s+)?"
    r"(?:-ExecutionPolicy\s+\S+\s+)?"
    r"-File\s+(?P<q>[\"']?)(?P<path>[^\"\s]+?)\.ps1(?P=q)?"
)
RX_PY = re.compile(r"(?<![/\w])python\s+(?P<q>[\"']?)(?P<path>[^\"\s]+?)\.py(?P=q)?")
RX_PS_FENCE = re.compile(r"```powershell\b")
SANDBOX_PREFIX = "bash tools/sandbox/run.sh python "


def run(cmd: list[str], cwd: Path | None = None) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, cwd=cwd, check=True)


def _read_git_head(repo: Path) -> str:
    head = (repo / ".git" / "HEAD").read_text(encoding="utf-8").strip()
    if head.startswith("ref:"):
        ref = head.split(":", 1)[1].strip()
        return (repo / ".git" / ref).read_text(encoding="utf-8").strip()
    return head


def upstream_commit() -> str:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(UPSTREAM), "rev-parse", "HEAD"],
            text=True,
        )
        return out.strip()
    except FileNotFoundError:
        return _read_git_head(UPSTREAM)


def pull_upstream(skip_pull: bool) -> None:
    if not UPSTREAM.is_dir():
        raise SystemExit(
            f"Нет каталога {UPSTREAM}. Клонируйте в корень kit:\n"
            "  git clone https://github.com/Nikolay-Shirokov/cc-1c-skills.git tools/cc-1c-skills"
        )
    if skip_pull:
        return
    try:
        run(["git", "-C", str(UPSTREAM), "pull", "--ff-only"])
    except FileNotFoundError:
        print("git нет в PATH — pull пропущен, используем текущий HEAD клона")


def build_staging(staging: Path) -> None:
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    run(
        [
            sys.executable,
            str(SWITCH),
            "cursor",
            "--runtime",
            "python",
            "--project-dir",
            str(staging),
        ],
        cwd=UPSTREAM,
    )


def kit_py_path(py_rel: str) -> Path | None:
    prefix = ".cursor/skills/"
    if not py_rel.startswith(prefix):
        return None
    p = TARGET / py_rel[len(prefix):]
    return p if p.is_file() else None


def patch_sandbox_in_text(content: str) -> tuple[str, bool]:
    changed = False

    def py_to_sandbox(m: re.Match[str]) -> str:
        nonlocal changed
        path = m.group("path")
        q = m.group("q") or ""
        if path.startswith(SANDBOX_PREFIX) or "tools/sandbox/run.sh" in path:
            return m.group(0)
        changed = True
        return f"{SANDBOX_PREFIX}{q}{path}.py{q}"

    new = RX_PY.sub(py_to_sandbox, content)

    def ps_to_sandbox(m: re.Match[str]) -> str:
        nonlocal changed
        path = m.group("path")
        q = m.group("q") or ""
        if kit_py_path(f"{path}.py") is None and not (ROOT / f"{path}.py").is_file():
            return m.group(0)
        py_rel = path if path.startswith(".cursor/skills/") else path
        if not py_rel.startswith(".cursor/skills/"):
            return m.group(0)
        changed = True
        return f"{SANDBOX_PREFIX}{q}{py_rel}.py{q}"

    new = RX_PS.sub(ps_to_sandbox, new)

    if RX_PS_FENCE.search(new) and "tools/sandbox/run.sh" in new:
        new2, n = RX_PS_FENCE.subn("```bash", new)
        if n:
            changed = True
            new = new2

    return new, changed


def patch_skill_tree(skill_dir: Path) -> int:
    n = 0
    for md in skill_dir.rglob("*.md"):
        text = md.read_text(encoding="utf-8")
        patched, changed = patch_sandbox_in_text(text)
        if changed:
            md.write_text(patched, encoding="utf-8")
            n += 1
    return n


def copy_skill(src: Path, dst: Path) -> int:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst, ignore=lambda _d, names: [n for n in names if n == "node_modules"])
    return patch_skill_tree(dst)


def apply_meta_overlays() -> None:
    run([sys.executable, str(APPLY_META)], cwd=ROOT)


def sync(dry_run: bool, skip_pull: bool) -> int:
    pull_upstream(skip_pull)
    commit = upstream_commit()

    staging = ROOT / ".tmp" / "cc-1c-skills-staging"
    build_staging(staging)
    stage_skills = staging / ".cursor" / "skills"

    to_sync = sorted(
        d.name
        for d in stage_skills.iterdir()
        if d.is_dir() and d.name not in SKIP_SKILLS
    )

    print(f"\nUpstream: {commit[:12]}")
    print(f"Синхронизировать в kit: {len(to_sync)} навыков")
    print(f"Пропуск (excluded/slice1): {sorted(SKIP_SKILLS)}")

    if dry_run:
        for name in to_sync:
            flag = " + overlay" if name in META_SKILLS else ""
            print(f"  would sync: {name}{flag}")
        return 0

    patched_total = 0
    for name in to_sync:
        patched_total += copy_skill(stage_skills / name, TARGET / name)
        print(f"  [OK] {name}")

    if META_SKILLS & set(to_sync):
        print("\nOverlay meta-* patches...")
        apply_meta_overlays()

    shutil.rmtree(staging, ignore_errors=True)

    manifest = {
        "synced_at": datetime.now(timezone.utc).isoformat(),
        "upstream_repo": "https://github.com/Nikolay-Shirokov/cc-1c-skills",
        "upstream_commit": commit,
        "runtime": "python",
        "sandbox_wrapper": "bash tools/sandbox/run.sh python",
        "target": "skills/cc-1c",
        "skills_synced": to_sync,
        "skipped_skills": sorted(SKIP_SKILLS),
    }
    MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"\nГотово. Манифест: {MANIFEST.relative_to(ROOT)}")
    print(f"Патч sandbox в .md: {patched_total} файлов")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Только показать план")
    parser.add_argument("--skip-pull", action="store_true", help="Не делать git pull upstream")
    args = parser.parse_args()
    return sync(dry_run=args.dry_run, skip_pull=args.skip_pull)


if __name__ == "__main__":
    raise SystemExit(main())
