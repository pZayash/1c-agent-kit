"""Корень ящика шины и пути claim/task."""

from __future__ import annotations

import os
from pathlib import Path

STATUSES = (
    "submitted",
    "working",
    "input-required",
    "completed",
    "failed",
    "canceled",
    "rejected",
)
KINDS = ("slot-transfer", "review", "handoff")
DATA_MODES = ("none", "slot", "dev_dt")


def _parse_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        val = val.strip().strip('"').strip("'")
        out[key.strip()] = val
    return out


def mailbox_root() -> Path:
    if os.environ.get("AGENT_SLOT") == "true":
        return Path("/work/mailbox")
    env = os.environ.get("AGENTS_MAILBOX")
    if env:
        return Path(env)
    compose_env = Path("docker/agent-container/.env")
    parsed = _parse_env_file(compose_env)
    if parsed.get("AGENTS_MAILBOX"):
        return Path(parsed["AGENTS_MAILBOX"])
    root = parsed.get("AGENTS_ROOT") or os.environ.get("AGENTS_ROOT")
    if root:
        return Path(root) / "mailbox"
    return Path("/work/mailbox")


def inbox_token(to: str, task_id: str, root: Path | None = None) -> Path:
    base = root or mailbox_root()
    return base / "inbox" / to / task_id


def processing_token(to: str, task_id: str, root: Path | None = None) -> Path:
    base = root or mailbox_root()
    return base / "processing" / to / task_id


def archive_token(to: str, task_id: str, root: Path | None = None) -> Path:
    base = root or mailbox_root()
    return base / "archive" / to / task_id


def task_dir(task_id: str, root: Path | None = None) -> Path:
    base = root or mailbox_root()
    return base / "tasks" / task_id


def task_json_path(task_id: str, root: Path | None = None) -> Path:
    return task_dir(task_id, root) / "task.json"


def slot_to_identity(slot: int | str) -> str:
    return f"slot-{int(slot)}"


def list_inbox(to: str, root: Path | None = None) -> list[str]:
    d = (root or mailbox_root()) / "inbox" / to
    if not d.is_dir():
        return []
    return sorted(p.name for p in d.iterdir() if p.name and not p.name.startswith("."))


if __name__ == "__main__":
    import json
    import sys

    cmd = sys.argv[1] if len(sys.argv) > 1 else "root"
    root = mailbox_root()
    if cmd == "root":
        print(root)
    elif cmd == "inbox":
        if len(sys.argv) < 3:
            raise SystemExit("usage: paths.py inbox <to>")
        for name in list_inbox(sys.argv[2], root):
            print(name)
    elif cmd == "open-reviews":
        tasks = root / "tasks"
        if not tasks.is_dir():
            raise SystemExit(0)
        for path in sorted(tasks.glob("*/task.json")):
            try:
                task = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if task.get("kind") != "review":
                continue
            if task.get("status") not in ("submitted", "input-required"):
                continue
            print(f"{task.get('id', path.parent.name)}\t{task.get('status')}\t{task.get('slug', '')}")
    else:
        raise SystemExit("usage: paths.py [root|inbox <to>|open-reviews]")

