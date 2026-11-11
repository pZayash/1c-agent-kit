#!/usr/bin/env python3
"""Запуск/останов отладочного узла 1С на автономном сервере (ibsrv).

Читает параметры из .env потребителя (префикс IBSRV_*), генерирует
конфигурационный yaml автономного сервера и управляет процессом.

Примеры:
  python db-server.py -Action yaml
  python db-server.py -Action start
  python db-server.py -Action status
  python db-server.py -Action stop
  python db-server.py -Action basic        # Authorization: Basic (UTF-8), скрыт
  python db-server.py -Action basic --show
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shlex
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path

DEFAULT_ACTIONS = ('yaml', 'start', 'stop', 'status', 'basic')

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')


def die(msg: str, code: int = 4) -> None:
    print(f'ОШИБКА: {msg}', file=sys.stderr)
    raise SystemExit(code)


def read_env(root: Path) -> dict:
    env = dict(os.environ)
    env_file = root / '.env'
    if not env_file.is_file():
        return env
    for raw in env_file.read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, val = line.split('=', 1)
        key, val = key.strip(), val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in '"\'':
            val = val[1:-1]
        env.setdefault(key, val)
    return env


def cfg(env: dict, name: str, default: str = '') -> str:
    return (env.get(name) or default).strip()


def yaml_scalar(value: str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


class Node:
    def __init__(self, root: Path, env: dict) -> None:
        self.root = root
        self.env = env
        self.exe = cfg(env, 'IBSRV_PATH')
        if not self.exe:
            die('в .env нет IBSRV_PATH (путь к ibsrv.exe)')
        work = root / '.tmp' / 'ibsrv'
        work.mkdir(parents=True, exist_ok=True)
        self.work = work
        self.pid_file = work / 'ibsrv.pid'
        self.log_file = work / 'ibsrv.log'
        # Пауза watchdog'а (\ibsrv\ibsrv-nodes-start): пустой файл .hold — узел не поднимается.
        # Ставится на время оффлайн-цикла ibcmd (apply метаданных 20-25 мин).
        self.hold_file = work / '.hold'
        self.db_path = cfg(env, 'IBSRV_DB_PATH')
        self.name = cfg(env, 'IBSRV_NAME') or (Path(self.db_path).name if self.db_path else 'ib')
        self.config = cfg(env, 'IBSRV_CONFIG') or str(work / 'server.yaml')
        self.data = cfg(env, 'IBSRV_DATA') or str(work / 'data')
        self.http_address = cfg(env, 'IBSRV_HTTP_ADDRESS', 'localhost')
        self.http_port = int(cfg(env, 'IBSRV_HTTP_PORT', '8315'))
        self.http_base = cfg(env, 'IBSRV_HTTP_BASE', '/')
        self.regport = int(cfg(env, 'IBSRV_DIRECT_REGPORT', '1542'))
        self.debug = cfg(env, 'IBSRV_DEBUG', 'http')
        self.debug_port = int(cfg(env, 'IBSRV_DEBUG_PORT', '1551'))
        # Доп. аргументы ibsrv (напр. --enable-extended-designer-features).
        self.extra_args = cfg(env, 'IBSRV_EXTRA_ARGS')
        self.services = [s.strip() for s in cfg(env, 'IBSRV_SERVICES',
                                                'mcp,mcp-dev').split(',') if s.strip()]

    # --- конфигурационный yaml -------------------------------------------
    def read_yaml_id(self) -> str:
        path = Path(self.config)
        if path.is_file():
            for line in path.read_text(encoding='utf-8').splitlines():
                if line.strip().startswith('id:'):
                    return line.split(':', 1)[1].strip().strip("'\"") or ''
        return ''

    def render_yaml(self) -> str:
        if not self.db_path:
            die('в .env нет IBSRV_DB_PATH (каталог файловой базы)')
        ib_id = self.read_yaml_id() or str(uuid.uuid4())
        lines = [
            '# Конфигурация автономного сервера 1С (генерируется db-server.py)',
            'server:',
            f'  address: {yaml_scalar(self.http_address)}',
            f'  port: {self.http_port}',
            'database:',
            f'  path: {yaml_scalar(self.db_path)}',
            'infobase:',
            f'  id: {yaml_scalar(ib_id)}',
            f'  name: {yaml_scalar(self.name)}',
            '  distribute-licenses: yes',
            '  schedule-jobs: allow',
            'http:',
            f'  base: {yaml_scalar(self.http_base)}',
            '  http-services:',
            '    publish-extensions-by-default: yes',
            '    service:',
        ]
        for svc in self.services:
            lines += [f'    - name: {yaml_scalar(svc)}',
                      f'      root: {yaml_scalar(svc)}',
                      '      publish: true']
        return '\n'.join(lines) + '\n'

    # --- процесс ---------------------------------------------------------
    def pid(self) -> int:
        try:
            pid = int(self.pid_file.read_text(encoding='utf-8').strip())
        except Exception:  # noqa: BLE001
            return 0
        if pid and self._alive(pid):
            return pid
        return 0

    @staticmethod
    def _alive(pid: int) -> bool:
        if os.name == 'nt':
            out = subprocess.run(['tasklist', '/FI', f'PID eq {pid}'],
                                 capture_output=True, text=True).stdout
            return str(pid) in out
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def port_open(self, port: int) -> bool:
        with socket.socket() as s:
            s.settimeout(2)
            return s.connect_ex(('127.0.0.1', port)) == 0

    def action_yaml(self) -> int:
        path = Path(self.config)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.render_yaml(), encoding='utf-8')
        print(f'конфигурация записана: {path}')
        return 0

    def action_start(self) -> int:
        if self.pid():
            print(f'узел уже запущен, pid={self.pid()}')
            self.hold_file.unlink(missing_ok=True)
            self.stop_file.unlink(missing_ok=True)
            return 0
        # Явный старт = узел снова под контролем watchdog'а.
        if self.hold_file.exists():
            self.hold_file.unlink()
            print(f'снят hold-файл watchdog\'а: {self.hold_file}')
        self.stop_file.unlink(missing_ok=True)
        self.action_yaml()
        Path(self.data).mkdir(parents=True, exist_ok=True)
        args = [self.exe, f'--config={self.config}', f'--data={self.data}']
        if self.debug:
            args += [f'--debug={self.debug}', f'--debug-port={self.debug_port}']
        if self.regport:
            args += [f'--direct-regport={self.regport}']
        if self.extra_args:
            args += shlex.split(self.extra_args)
        log = open(self.log_file, 'wb')
        kwargs: dict = {'stdout': log, 'stderr': subprocess.STDOUT, 'stdin': subprocess.DEVNULL}
        if os.name == 'nt':
            kwargs['creationflags'] = 0x00000008 | 0x08000000  # DETACHED | NEW_GROUP
        else:
            kwargs['start_new_session'] = True
        proc = subprocess.Popen(args, **kwargs)
        self.pid_file.write_text(str(proc.pid), encoding='utf-8')
        for _ in range(30):
            time.sleep(1)
            if proc.poll() is not None:
                print('узел завершился сразу — смотри лог:')
                print(self.log_file.read_text(encoding='utf-8', errors='replace')[-1500:])
                return 1
            if self.port_open(self.http_port):
                break
        print(f'узел запущен: pid={proc.pid}')
        print(f'  веб-клиент/HTTP-сервисы: http://{self.http_address}:{self.http_port}/')
        print(f'  прямое соединение (/S): {self.http_address}:{self.regport}\\{self.name}')
        print(f'  отладка ({self.debug}): порт {self.debug_port}')
        print(f'  лог: {self.log_file}')
        return 0

    @property
    def stop_file(self) -> Path:
        # Запрос на остановку для elevated-задачи (watchdog): обычный шелл не может убить
        # процесс, запущенный более привилегированной сессией (bb-агент / задача Highest).
        return self.work / '.stop'

    def _kill(self, pid: int) -> tuple:
        """Убить процесс и проверить результат. (успех, текст taskkill)"""
        out = ''
        if os.name == 'nt':
            res = subprocess.run(['taskkill', '/PID', str(pid), '/F'],
                                 capture_output=True, text=True)
            out = ((res.stdout or '') + (res.stderr or '')).strip()
        else:
            import signal
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError as exc:
                out = str(exc)
        for _ in range(10):
            time.sleep(1)
            if not self._alive(pid):
                return True, out
        return False, out

    def action_stop(self, hold: bool = True) -> int:
        pid = self.pid()
        if not pid:
            print('узел не запущен (hold-файл не ставится: базу держать нечего)')
            return 0
        # hold — до остановки узла, иначе watchdog успеет поднять базу посреди цикла.
        if hold:
            self.hold_file.parent.mkdir(parents=True, exist_ok=True)
            self.hold_file.write_text('', encoding='utf-8')
            print(f'hold-файл watchdog\'а поставлен: {self.hold_file}')
            print('  снять: -Action start (или удалить файл, если узел должен подниматься сам)')
        else:
            self.hold_file.unlink(missing_ok=True)
        ok, out = self._kill(pid)
        if ok:
            self.pid_file.unlink(missing_ok=True)
            self.stop_file.unlink(missing_ok=True)
            print(f'узел остановлен (pid={pid})')
            return 0
        # НЕ рапортуем успех: база осталась занятой, любая загрузка потом упадёт
        # «Ошибка блокировки информационной базы для конфигурирования».
        print(f'НЕ УДАЛОСЬ остановить узел (pid={pid}) — процесс жив, база заблокирована.')
        first = (out.splitlines() or [''])[0]
        if first:
            print(f'  taskkill: {first}')
        print('  причина: процесс запущен более привилегированной сессией (bb-агент или')
        print('  задача \\ibsrv\\ibsrv-nodes-start с RunLevel Highest) — из обычного шелла не убивается.')
        self.stop_file.write_text('', encoding='utf-8')
        print(f'  запрос на остановку поставлен: {self.stop_file}')
        print('  выполнить (без прав администратора — задачу запустит elevated-сессия):')
        print('    MSYS_NO_PATHCONV=1 schtasks /Run /TN "\\ibsrv\\ibsrv-nodes-start"')
        print('  либо из шелла «от имени администратора»:')
        print(f'    taskkill /PID {pid} /F')
        print('  hold-файл оставлен: база не поднимется сама, пока не сделаете -Action start')
        return 2

    def action_status(self) -> int:
        pid = self.pid()
        print(f'узел: {"запущен pid=" + str(pid) if pid else "нет pid-файла"}')
        listening = 0
        for label, port in (('http', self.http_port), ('отладка', self.debug_port),
                            ('прямое соединение', self.regport)):
            open_ = self.port_open(port)
            listening += 1 if open_ else 0
            print(f'  {label}: {port} — {"слушает" if open_ else "закрыт"}')
        if not pid and listening:
            print('  ВНИМАНИЕ: порты слушают, а pid-файла нет — узел запущен другой сессией')
            print('  (pid-файл потерян старым stop/taskkill). Гасить: -Action stop (создаст .stop)')
            print('  или tasklist /FI "IMAGENAME eq ibsrv.exe" + taskkill из elevated-шелла.')
        if self.hold_file.exists():
            age = int(time.time() - self.hold_file.stat().st_mtime) // 3600
            print(f'  hold-файл: есть ({self.hold_file}, {age} ч) — watchdog базу не поднимает')
            if age >= 24:
                print('  ВНИМАНИЕ: hold старше суток — если оффлайн-цикл закончен, удалите файл')
        else:
            print('  hold-файл: нет — база под контролем watchdog\'а')
        return 0

    def action_basic(self, show: bool) -> int:
        user = cfg(self.env, 'IBSRV_USER') or cfg(self.env, 'WEB_TEST_USER')
        pwd = cfg(self.env, 'IBSRV_PASSWORD') or cfg(self.env, 'WEB_TEST_PASSWORD')
        if not user:
            die('нет IBSRV_USER/WEB_TEST_USER в .env')
        token = base64.b64encode(f'{user}:{pwd}'.encode('utf-8')).decode()
        print('Authorization: Basic ' + (token if show else '<скрыт, добавь --show>'))
        print('важно: учётка ИБ должна быть в UTF-8 '
              '(curl -u в Git Bash/MSYS ломает кириллицу -> 401)')
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(description='Отладочный узел 1С на автономном сервере')
    parser.add_argument('-Action', default='status', choices=DEFAULT_ACTIONS)
    parser.add_argument('--show', action='store_true', help='показать Basic-заголовок целиком')
    parser.add_argument('--no-hold', action='store_true',
                        help='stop: не ставить hold-файл watchdog-а (для скриптов, напр. start-ibsrv-nodes.ps1)')
    parser.add_argument('--root', default='.', help='корень потребителя (где .env)')
    args = parser.parse_args()

    root = Path(args.root).resolve()
    env = read_env(root)
    node = Node(root, env)

    if args.Action == 'yaml':
        return node.action_yaml()
    if args.Action == 'start':
        return node.action_start()
    if args.Action == 'stop':
        return node.action_stop(hold=not args.no_hold)
    if args.Action == 'basic':
        return node.action_basic(args.show)
    return node.action_status()


if __name__ == '__main__':
    raise SystemExit(main())
