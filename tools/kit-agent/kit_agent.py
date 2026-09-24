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
import datetime
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
                behind_n = int(behind) if behind else 0
                ahead_n = int(ahead) if ahead else 0
                if behind_n > 0 and ahead_n > 0:
                    hints.append(
                        f'harness (kit) разошёлся с локальным origin/master '
                        f'(впереди {ahead_n}, позади {behind_n}) — расхождение, а не '
                        f'отставание: checkout origin/master потеряет локальные '
                        f'коммиты. Канон: cherry-pick локальных коммитов на '
                        f'origin/master и push (skill harness-promote), затем '
                        f'bump gitlink.')
                elif behind_n > 0:
                    hints.append(
                        f'harness (kit) отстал от локального origin/master на {behind} '
                        f'коммит(ов). Обнови: git -C {harness_rel} fetch origin && '
                        f'git -C {harness_rel} checkout origin/master && '
                        f'bash {harness_rel}/scripts/bootstrap-kit.sh .')
                elif ahead_n > 0:
                    hints.append(
                        f'harness (kit) впереди origin/master на {ahead} коммит(ов) — '
                        f'локальная линия? Канон: promote в kit (skill harness-promote).')

    # stale kit links + namespace (engine plan --strict).
    # ВНЕ git-ветки: в sandbox/контейнере git нет, а именно там важно поймать
    # FOREIGN-NS и не отправить агента перезапускать bootstrap не в том месте.
    layout = harness / 'tools' / 'kit-layout' / 'kit_layout.py'
    if layout.is_file():
        try:
            r = subprocess.run(
                [sys.executable, str(layout), 'plan', '--strict', str(root)],
                capture_output=True, text=True, timeout=60,
                env={**os.environ, 'HARNESS_REL': harness_rel})
            if r.returncode == 2:
                # kit-layout refuses a foreign/sandbox namespace (exit 2);
                # do not send the agent to bootstrap in the wrong place.
                err = next((l for l in (r.stderr or '').splitlines()
                            if l.startswith('ERROR:')), 'foreign namespace')
                hints.append(
                    f'kit-layout не может работать в этом namespace ({err}). '
                    f'Запусти на хосте: bash {harness_rel}/scripts/bootstrap-kit.sh .')
            elif r.returncode != 0:
                summary = [l for l in (r.stdout or '').splitlines()
                           if l.startswith('kit-layout plan:')]
                hints.append(
                    f'есть ожидающие изменения раскладки kit '
                    f'({summary[0] if summary else "plan --strict exit 1"}). '
                    f'Выполни: bash {harness_rel}/scripts/bootstrap-kit.sh .')
        except (OSError, subprocess.TimeoutExpired):
            pass  # layout check is best-effort

    # friction-сигналы, ждущие разбора (memory/rule-friction, ленивая папка)
    # ВНЕ git-ветки: работает и в sandbox/контейнере без git.
    fdir = root / 'memory' / 'rule-friction'
    if fdir.is_dir():
        pending = sorted(fdir.glob('*.md'))
        if pending:
            names = ', '.join(p.name for p in pending[:5])
            more = '' if len(pending) <= 5 else f' и ещё {len(pending) - 5}'
            hints.append(
                f'{len(pending)} friction-сигнал(ов) ждут разбора в '
                f'memory/rule-friction/ ({names}{more}). Канон: '
                f'memory-format.md § Разлад, skill evolve.')

    for h in hints:
        print(f'[!] {h}')
    return 0


def load_guards():
    return json.loads(GUARDS_FILE.read_text(encoding='utf-8'))['rules']


def cmd_record_friction(a):
    """Записать friction-сигнал (memory/rule-friction) по канону kit.

    Ленивая папка; один файл на (дата, rule-id); повторные срабатывания
    увеличивают счётчик и добавляют строку-факт.
    """
    root = Path(a.root).resolve()
    rules = {r['id']: r for r in load_guards()}
    rule = rules.get(a.rule_id)
    fdir = root / 'memory' / 'rule-friction'
    fdir.mkdir(parents=True, exist_ok=True)
    today = datetime.date.today().isoformat()
    now = datetime.datetime.now().strftime('%H:%M')
    rule_msg = rule['message'] if rule else 'См. guards.json в kit.'
    path = fdir / f'{today}-{a.rule_id}.md'
    cmd = (a.command or '-')[:300]

    if path.exists():
        text = path.read_text(encoding='utf-8')
        m = re.search(r'^Повторы: (\d+)$', text, re.M)
        n = int(m.group(1)) + 1 if m else 2
        if m:
            text = text[:m.start()] + f'Повторы: {n}' + text[m.end():]
        else:
            text = text.rstrip() + f'\n\nПовторы: {n}\n'
        text = text.rstrip() + f'\n- {now} {a.kind}: `{cmd}`\n'
        path.write_text(text, encoding='utf-8')
        print(f'friction updated: memory/rule-friction/{path.name} (повторы: {n})')
        return 0

    body = f'''# kit guard: {a.rule_id}

## Контекст
Агент выполнил команду, на которую сработало guard-правило kit ({a.kind}).
Команда: `{cmd}`

## Факт
Правило `{a.rule_id}` из harness/tools/kit-agent/guards.json сработало.

## Решение / правило
{rule_msg}

## Теги
kit, guard, {a.rule_id}

## Дата и источник
{today}, kit-agent{', сессия ' + a.session_id if a.session_id else ''}

Повторы: 1
'''
    path.write_text(body, encoding='utf-8')
    print(f'friction recorded: memory/rule-friction/{path.name}')
    return 0


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

    pf = sub.add_parser('record-friction', help='append a friction signal to memory/rule-friction')
    pf.add_argument('--rule-id', required=True)
    pf.add_argument('--kind', choices=['block', 'warn'], default='block')
    pf.add_argument('--command', default='')
    pf.add_argument('--session-id', default='')
    pf.add_argument('--root', default='.')
    pf.set_defaults(fn=cmd_record_friction)

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
