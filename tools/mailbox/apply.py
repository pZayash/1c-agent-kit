#!/usr/bin/env python3
"""Apply задачи шины в слоте-приёмнике: claim → merge → load. Playwright нет.

Docker-слот (ноутбук): docker/agent-container/mailbox-apply.sh N <id>
  → python3 /opt/agent-repo/tools/mailbox/apply.py (AGENT_SLOT, /work).
Хост без Docker (SRV01): tools/mailbox/apply-host.sh N <id>
  → MAILBOX_WORK + AGENTS_MAILBOX (локальный NTFS), без AGENT_SLOT.

Протокол task.json тот же. На хосте v1 — только data.mode=none.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

from paths import (  # noqa: E402
    DATA_MODES,
    KINDS,
    STATUSES,
    archive_token,
    inbox_token,
    mailbox_root,
    processing_token,
    slot_to_identity,
    task_dir,
    task_json_path,
)

SCHEMA_VERSION = 1


def work_root() -> Path:
    raw = os.environ.get("MAILBOX_WORK", "").strip()
    if raw:
        return Path(raw).expanduser().resolve()
    return Path("/work")


def load_sh() -> Path:
    return work_root() / "load-changed-files.sh"


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def die(msg: str, code: int = 1) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def load_task(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"task.json: {exc}")


def validate_task(task: dict[str, Any]) -> None:
    required = (
        "schemaVersion",
        "id",
        "kind",
        "from",
        "to",
        "status",
        "createdAt",
        "updatedAt",
        "statusHistory",
        "artifacts",
    )
    missing = [k for k in required if k not in task]
    if missing:
        die(f"нет полей: {', '.join(missing)}")
    if task.get("schemaVersion") != SCHEMA_VERSION:
        die(f"schemaVersion: нужен {SCHEMA_VERSION}")
    if task.get("kind") not in KINDS:
        die(f"kind: {task.get('kind')}")
    if task.get("status") not in STATUSES:
        die(f"status: {task.get('status')}")
    hist = task.get("statusHistory")
    if not isinstance(hist, list) or not hist:
        die("statusHistory пуст")
    arts = task.get("artifacts")
    if not isinstance(arts, list):
        die("artifacts не массив")
    for art in arts:
        if not isinstance(art, dict) or "name" not in art or "uri" not in art:
            die("артефакт без name/uri")
        if "xml" in art.get("name", "").lower() and "<" in str(art.get("uri", "")):
            die("XML в uri запрещён — файл в artifacts/")
    if task["kind"] == "slot-transfer":
        git = task.get("git") or {}
        if not git.get("theirs"):
            die("slot-transfer: нужен git.theirs")
    data = task.get("data") or {}
    mode = data.get("mode", "none")
    if mode not in DATA_MODES:
        die(f"data.mode: {mode}")


def save_task(path: Path, task: dict[str, Any]) -> None:
    path.write_text(json.dumps(task, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def set_status(task: dict[str, Any], status: str) -> None:
    now = utc_now()
    task["status"] = status
    task["updatedAt"] = now
    hist = task.setdefault("statusHistory", [])
    hist.append({"at": now, "status": status})


def add_artifact(task: dict[str, Any], name: str, uri: str, media: str | None = None) -> None:
    arts = task.setdefault("artifacts", [])
    arts.append({"name": name, "uri": uri, **({"mediaType": media} if media else {})})


def atomic_claim(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.rename(src, dst)
    except FileNotFoundError:
        die(f"нет claim-токена: {src}")
    except OSError as exc:
        die(f"claim rename: {exc}")


def git_merge(theirs: str) -> tuple[int, list[str]]:
    work = work_root()
    proc = subprocess.run(
        ["git", "-C", str(work), "merge", "--no-edit", theirs],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    if proc.returncode == 0:
        return 0, []
    unmerged = subprocess.run(
        ["git", "-C", str(work), "diff", "--name-only", "--diff-filter=U"],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    files = [ln for ln in unmerged.stdout.splitlines() if ln.strip()]
    return proc.returncode, files


def git_head() -> str:
    proc = subprocess.run(
        ["git", "-C", str(work_root()), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=True,
    )
    return proc.stdout.strip()


def load_config(theirs: str) -> None:
    work = work_root()
    script = load_sh()
    if not script.is_file():
        die(f"нет {script}")
    tmp = work / ".tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    list_file = tmp / "mailbox-load.txt"
    diff = subprocess.run(
        [
            "git",
            "-C",
            str(work),
            "diff-tree",
            "--no-commit-id",
            "--name-only",
            "-r",
            theirs,
            "--",
            "conf/",
            "cfe.xml/",
        ],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    files = [ln.strip() for ln in diff.stdout.splitlines() if ln.strip()]
    if not files:
        proc = subprocess.run(["bash", str(script), "-U"], cwd=str(work))
    else:
        list_file.write_text("\n".join(files) + "\n", encoding="utf-8")
        proc = subprocess.run(
            ["bash", str(script), "-U", "--list-file", str(list_file)],
            cwd=str(work),
        )
    if proc.returncode != 0:
        die(f"load-changed-files.sh -U: exit {proc.returncode}", 1)


def finish(task: dict[str, Any], path: Path, to: str, task_id: str, root: Path, status: str) -> None:
    set_status(task, status)
    save_task(path, task)
    proc = processing_token(to, task_id, root)
    arch = archive_token(to, task_id, root)
    if proc.exists():
        arch.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(proc), str(arch))


def cmd_peek(args: argparse.Namespace) -> None:
    root = mailbox_root()
    path = task_json_path(args.id, root)
    if not path.is_file():
        die(f"нет {path}")
    task = load_task(path)
    validate_task(task)
    data = task.get("data") or {}
    refs = data.get("refs") or []
    payload = refs if isinstance(refs, dict) else {"refs": refs}
    print(
        json.dumps(
            {
                "kind": task["kind"],
                "from": task["from"],
                "to": task["to"],
                "reset": bool(data.get("reset")),
                "mode": data.get("mode", "none"),
                "refs": payload,
            },
            ensure_ascii=False,
        )
    )


def cmd_complete(args: argparse.Namespace) -> None:
    root = mailbox_root()
    path = task_json_path(args.id, root)
    task = load_task(path)
    validate_task(task)
    if args.artifact:
        name, _, uri = args.artifact.partition("=")
        if not name or not uri:
            die("--artifact name=uri")
        media = "application/xml" if uri.endswith(".xml") else None
        add_artifact(task, name, uri, media)
    finish(task, path, task["to"], args.id, root, "completed")
    print("DONE")


def cmd_apply(args: argparse.Namespace) -> None:
    root = mailbox_root()
    to = slot_to_identity(args.slot)
    path = task_json_path(args.id, root)
    if not path.is_file():
        die(f"нет {path}")
    task = load_task(path)
    validate_task(task)
    if task["to"] != to:
        die(f"to={task['to']}, слот {to}")
    if task["kind"] != "slot-transfer":
        die(f"apply только slot-transfer, kind={task['kind']}")

    src = inbox_token(to, args.id, root)
    dst = processing_token(to, args.id, root)
    atomic_claim(src, dst)
    set_status(task, "working")
    save_task(path, task)

    theirs = task["git"]["theirs"]
    code, conflicts = git_merge(theirs)
    if conflicts or code != 0:
        tdir = task_dir(args.id, root)
        (tdir / "artifacts").mkdir(parents=True, exist_ok=True)
        conf_file = tdir / "artifacts" / "conflicts.txt"
        conf_file.write_text("\n".join(conflicts) + ("\n" if conflicts else ""), encoding="utf-8")
        add_artifact(task, "conflicts", "artifacts/conflicts.txt", "text/plain")
        set_status(task, "input-required")
        save_task(path, task)
        print("CONFLICT", file=sys.stderr)
        raise SystemExit(2)

    sha = git_head()
    add_artifact(task, "merge", f"git:{sha}")
    save_task(path, task)
    try:
        load_config(theirs)
    except SystemExit:
        set_status(task, "failed")
        save_task(path, task)
        raise

    mode = (task.get("data") or {}).get("mode", "none")
    if mode == "none":
        finish(task, path, to, args.id, root, "completed")
        print("DONE")
        return
    save_task(path, task)
    print(f"NEED_DATA={mode}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Apply slot-transfer в ящике шины")
    parser.add_argument("--slot", required=True, type=int, choices=(1, 2, 3))
    parser.add_argument("--id", required=True)
    parser.add_argument("--peek", action="store_true", help="JSON полей data/from без claim")
    parser.add_argument(
        "--complete",
        action="store_true",
        help="после host data-copy: completed + archive token",
    )
    parser.add_argument(
        "--artifact",
        help="при --complete: name=uri (dump=artifacts/dump.xml)",
    )
    args = parser.parse_args()
    if args.peek:
        cmd_peek(args)
    elif args.complete:
        cmd_complete(args)
    else:
        cmd_apply(args)


if __name__ == "__main__":
    main()
