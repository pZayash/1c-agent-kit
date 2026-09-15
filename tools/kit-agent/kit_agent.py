#!/usr/bin/env python3
"""kit-agent - harness-agnostic core for agent session hooks (idea: teamai hooks).

Single source of logic for all harness adapters (pi extension, kilo plugin,
AGENTS.md instructions for Zed/others, future Claude/Cursor hook commands).

Commands (all read-only, offline, fast):
  session-start [--root DIR]   Print hint lines for the agent (empty = all OK).
                               Checks: harness gitlink vs HEAD drift,
                               HEAD vs local origin/master (no fetch),
                               stale kit links (kit-layout plan --strict).
  check-command CMD            Evaluate a bash command against guards.json.
                               exit 1 = blocked (message on stdout),
                               exit 0 = allowed; warnings prefixed "WARN:".
  guards                       Dump guards.json (for adapters that evaluate
                               rules in-process).

Exit codes: 0 ok, 1 blocked (check-command), 2 usage/internal error
(adapters must treat 2 as "no-op", never break the session).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
GUARDS_FILE = HERE / 'guards.json'
GIT = shutil.which('git')  # None в контейнерах без git → git-проверки no-op


def harness_root(root, harness_rel):
    return Path(root).resolve() / harness_rel


def git(root, *args):
    if not GIT:
        return None
    try:
        r = subprocess.run(['git', '-C', str(root), *args],
                           capture_output=True, text=True, timeout=15)
        return r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def cmd_session_start(a):
    root = Path(a.root).resolve()
    harness_rel = os.environ.get('HARNESS_REL', a.harness_rel)
    harness = harness_root(root, harness_rel)
    hints = []

    if not harness.is_dir():
        hints.append(f'harness/ отсутствует в {root} — kit не подключен '
                     f'(git submodule update --init).')
    elif not GIT:
        pass  # git недоступен (sandbox/контейнер) — git-проверки no-op
    else:
        head = git(harness, 'rev-parse', 'HEAD')
        if head is None:
            hints.append(f'git -C {harness_rel} не работает (worktree file-gitdir?) — '
                         f'почини: bash {harness_rel}/scripts/fix-harness-gitdir.sh .')
        else:
            recorded = git(root, 'ls-files', '-s', '--', harness_rel)
            recorded_sha = recorded.split()[1] if recorded else None
            if recorded_sha and recorded_sha != head:
                hints.append(
                    f'дрейф сабмодуля: harness HEAD ({head[:7]}) != записанный gitlink '
                    f'({recorded_sha[:7]}). Либо submodule update (откат к gitlink), '
                    f'либо закоммить bump: git commit -m "chore(harness): bump kit" -- harness')
            upstream = git(harness, 'rev-parse', '--verify', '-q', 'origin/master')
            if upstream and head != upstream:
                behind = git(harness, 'rev-list', '--count', f'HEAD..origin/master')
                ahead = git(harness, 'rev-list', '--count', 'origin/master..HEAD')
                if behind and int(behind) > 0:
                    hints.append(
                        f'harness (kit) отстал от локального origin/master на {behind} '
                        f'коммит(ов). Обнови: git -C {harness_rel} fetch origin && '
                        f'git -C {harness_rel} checkout origin/master && '
                        f'bash {harness_rel}/scripts/bootstrap-kit.sh .')
                elif ahead and int(ahead) > 0:
                    hints.append(
                        f'harness (kit) впереди origin/master на {ahead} коммит(ов) — '
                        f'локальная линия? Канон: promote в kit (skill harness-promote).')

        # stale kit links (cheap: engine plan --strict)
        layout = harness / 'tools' / 'kit-layout' / 'kit_layout.py'
        if layout.is_file():
            try:
                r = subprocess.run(
                    [sys.executable, str(layout), 'plan', '--strict', str(root)],
                    capture_output=True, text=True, timeout=60,
                    env={**os.environ, 'HARNESS_REL': harness_rel})
                if r.returncode != 0:
                    summary = [l for l in (r.stdout or '').splitlines()
                               if l.startswith('kit-layout plan:')]
                    hints.append(
                        f'есть ожидающие изменения раскладки kit '
                        f'({summary[0] if summary else "plan --strict exit 1"}). '
                        f'Выполни: bash {harness_rel}/scripts/bootstrap-kit.sh .')
            except (OSError, subprocess.TimeoutExpired):
                pass  # layout check is best-effort

    for h in hints:
        print(f'[!] {h}')
    return 0


def load_guards():
    return json.loads(GUARDS_FILE.read_text(encoding='utf-8'))['rules']


def cmd_check_command(a):
    cmd = a.command
    for rule in load_guards():
        try:
            if re.search(rule['match'], cmd):
                if rule['action'] == 'block':
                    print(f"BLOCK [{rule['id']}]: {rule['message']}")
                    return 1
                print(f"WARN [{rule['id']}]: {rule['message']}")
        except re.error as e:
            print(f'WARN: bad guard rule {rule.get("id")}: {e}', file=sys.stderr)
    return 0


def cmd_guards(_a):
    print(GUARDS_FILE.read_text(encoding='utf-8'))
    return 0


def main(argv=None):
    # Windows: stdout/stderr всегда UTF-8, независимо от консольной локали.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding='utf-8')
        except (AttributeError, OSError):
            pass
    p = argparse.ArgumentParser(prog='kit-agent', description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)

    ps = sub.add_parser('session-start', help='print session-start hints (empty = ok)')
    ps.add_argument('--root', default='.')
    ps.add_argument('--harness-rel', default='harness')
    ps.set_defaults(fn=cmd_session_start)

    pc = sub.add_parser('check-command', help='evaluate a bash command against guards')
    pc.add_argument('command')
    pc.set_defaults(fn=cmd_check_command)

    pg = sub.add_parser('guards', help='dump guards.json')
    pg.set_defaults(fn=cmd_guards)

    a = p.parse_args(argv)
    try:
        return a.fn(a)
    except Exception as e:  # adapters must never break the session
        print(f'kit-agent: internal error (no-op): {e}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
