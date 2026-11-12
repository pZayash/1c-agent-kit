#!/usr/bin/env python3
"""Запуск/останов отладочного узла 1С на автономном сервере (ibsrv).

Читает параметры из .env потребителя (префикс IBSRV_*), генерирует
конфигурационный yaml автономного сервера и управляет процессом.

Примеры:
  python db-server.py -Action yaml
  python db-server.py -Action start
  python db-server.py -Action start --force            # снять чужой hold осознанно
  python db-server.py -Action status
  python db-server.py -Action stop                     # + hold «пауза»
  python db-server.py -Action stop --offline           # + hold «оффлайн-цикл» (ttl 45 мин)
  python db-server.py -Action stop --no-hold           # для watchdog
  python db-server.py -Action hold-release              # снять свой hold (движок: конец цикла)
  python db-server.py -Action basic        # Authorization: Basic (UTF-8), скрыт
  python db-server.py -Action basic --show

Коды возврата (важно для скриптов: 127 у ibcmd — общий «не выполнено»):

  0  успех (start: узел наш, порт наш, HTTP отвечает; stop/hold-release: снимать нечего)
  2  не удалось погасить процесс (права/сессия) — pid-файл сохранён, поставлен .stop
  3  start не поднял узел: порт не открылся или его держит чужой pid
  4  отказ из-за чужого hold (start/hold-release) либо ошибка конфигурации
     (.env: нет IBSRV_PATH, IBSRV_PATH не файл, нет IBSRV_DB_PATH)
  5  отказ без действий: лок старта занят (параллельный start/stop) либо порт
     держит чужой процесс — чужое не глушим

Грабли, из-за которых это переписано (2026-11-11):
  * «узел запущен: pid=…» печаталось и при закрытых портах — агент считал базу
    поднятой и воевал с watchdog'ом;
  * -Action start снимал .hold любого владельца: чужой оффлайн-цикл ломался;
  * параллельные старты (агент + watchdog + руками) оставляли два ibsrv и pid-файл
    на проигравшего, а следующий stop гасил победителя;
  * stop гасил владельца порта не глядя, что это за процесс: узел чужой базы на
    том же порту умирал молча (2026-11-12);
  * движок загрузки ставил hold kind=pause с ttl 4 ч и не снимал его: возврат
    `-Action start` из другого треда получал rc=4 и узел лежал до истечения ttl
    (2026-11-12: движок ставит kind=offline и снимает его сам — hold-release).
"""

from __future__ import annotations

import argparse
import base64
import http.client
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path

DEFAULT_ACTIONS = ('yaml', 'start', 'stop', 'status', 'basic', 'hold-release')

# Сколько живёт hold по умолчанию. Оффлайн-цикл (import+apply) — 20–25 мин,
# поэтому 45 мин: успевает любой apply, но забытый hold не блокирует базу навсегда.
TTL_OFFLINE = 45 * 60
TTL_PAUSE = 4 * 3600
# Лок старта считается протухшим, если процесс, взявший его, мёртв, или он старше.
TTL_START_LOCK = 300
# Сколько ждать готовности узла (1С открывает файловую ИБ 17 ГБ не мгновенно).
DEFAULT_START_TIMEOUT = 180

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


def norm_path(value: str) -> str:
    """Путь к виду для сравнения: слэши, без хвостового слэша, без регистра."""
    return value.replace('\\', '/').rstrip('/').lower()


def fmt_age(seconds: float) -> str:
    seconds = int(max(0, seconds))
    if seconds < 120:
        return f'{seconds} с'
    if seconds < 7200:
        return f'{seconds // 60} мин'
    return f'{seconds / 3600:.1f} ч'


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
        # Пауза watchdog'а (\ibsrv\ibsrv-nodes-start): файл .hold — узел не поднимается.
        # Формат — JSON (owner/reason/since/ttl/kind), пустой файл = «человек, без владельца».
        self.hold_file = work / '.hold'
        # Мьютекс старта: два start одновременно (агент + watchdog + руками) недопустимы.
        self.start_lock = work / '.start.lock'
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
        self.start_timeout = int(cfg(env, 'IBSRV_START_TIMEOUT', str(DEFAULT_START_TIMEOUT)))

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
        """Жив ли процесс. Точное сравнение pid, не подстрока (pid 1053 ≠ 10536)."""
        if not pid:
            return False
        if os.name == 'nt':
            out = subprocess.run(['tasklist', '/FI', f'PID eq {pid}', '/NH', '/FO', 'CSV'],
                                 capture_output=True, text=True, errors='replace').stdout or ''
            for line in out.splitlines():
                m = re.match(r'^"([^"]*)"\s*,\s*"(\d+)"', line)
                if m and int(m.group(2)) == pid:
                    return True
            # tasklist на некоторых локалях печатает «нет задач» в stdout — не наш pid
            return False
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def port_owner(self, port: int) -> int:
        """pid процесса, который слушает TCP-порт (0 — никто)."""
        if os.name != 'nt':
            out = subprocess.run(['lsof', '-nP', f'-iTCP:{port}', '-sTCP:LISTEN', '-t'],
                                 capture_output=True, text=True).stdout or ''
            try:
                return int(out.split()[0])
            except Exception:  # noqa: BLE001
                return 0
        out = subprocess.run(['netstat', '-ano', '-p', 'tcp'],
                             capture_output=True, text=True, errors='replace').stdout or ''
        for line in out.splitlines():
            parts = line.split()
            if len(parts) < 5 or 'LISTENING' not in parts[-2]:
                continue
            if not re.search(rf':{port}$', parts[1]):
                continue
            try:
                return int(parts[-1])
            except ValueError:
                continue
        return 0

    def port_open(self, port: int) -> bool:
        with socket.socket() as s:
            s.settimeout(2)
            return s.connect_ex(('127.0.0.1', port)) == 0

    # --- опознание процесса, держащего порт/pid ---------------------------
    def proc_image(self, pid: int) -> str:
        """Имя образа процесса ('' — не смог узнать)."""
        if not pid:
            return ''
        if os.name == 'nt':
            out = subprocess.run(['tasklist', '/FI', f'PID eq {pid}', '/NH', '/FO', 'CSV'],
                                 capture_output=True, text=True, errors='replace').stdout or ''
            for line in out.splitlines():
                m = re.match(r'^"([^"]*)"\s*,\s*"(\d+)"', line)
                if m and int(m.group(2)) == pid:
                    return m.group(1)
            return ''
        out = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='],
                             capture_output=True, text=True, errors='replace').stdout or ''
        return out.strip()

    def proc_cmdline(self, pid: int) -> str:
        """Командная строка процесса ('' — не смог прочитать)."""
        if not pid:
            return ''
        if os.name != 'nt':
            out = subprocess.run(['ps', '-p', str(pid), '-o', 'args='],
                                 capture_output=True, text=True, errors='replace').stdout or ''
            return out.strip()
        if not shutil.which('powershell.exe'):
            return ''
        ps_cmd = ("[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
                  f"(Get-CimInstance Win32_Process -Filter 'ProcessId={pid}').CommandLine")
        out = subprocess.run(['powershell.exe', '-NoProfile', '-Command', ps_cmd],
                             capture_output=True, text=True, errors='replace').stdout or ''
        return out.strip()

    @staticmethod
    def _yaml_db_path(path: str) -> str:
        """Поле database.path из конфигурационного yaml автономного сервера."""
        try:
            for line in Path(path).read_text(encoding='utf-8', errors='replace').splitlines():
                s = line.strip()
                if s.startswith('path:'):
                    return s.split(':', 1)[1].strip().strip("'\"")
        except OSError:
            return ''
        return ''

    def node_owner_kind(self, pid: int) -> str:
        """Чей процесс: 'ours' (наш ibsrv), 'foreign' (чужой) или 'unknown'.

        Порядок: имя образа (ibsrv), затем — если командная строка читается —
        база из `--config`; чужой узел на том же порту гасить нельзя.
        """
        image = self.proc_image(pid)
        if not image:
            return 'unknown'
        if 'ibsrv' not in image.lower():
            return 'foreign'
        cmd = self.proc_cmdline(pid)
        if not cmd:
            return 'ours'
        if self.data and norm_path(self.data) in norm_path(cmd):
            return 'ours'
        m = re.search(r'--config=("([^"]+)"|(\S+))', cmd)
        if m and self.db_path:
            other = self._yaml_db_path(m.group(2) or m.group(3))
            if other and norm_path(other) != norm_path(self.db_path):
                return 'foreign'
        return 'ours'

    def http_probe(self, timeout: float = 5.0) -> int | None:
        """Код ответа узла на корень его публикации (любой код = узел отвечает)."""
        base = self.http_base if self.http_base.startswith('/') else '/' + self.http_base
        if not base.endswith('/'):
            base += '/'
        try:
            conn = http.client.HTTPConnection('127.0.0.1', self.http_port, timeout=timeout)
            conn.request('GET', base)
            resp = conn.getresponse()
            resp.read(1)
            conn.close()
            return resp.status
        except Exception:  # noqa: BLE001
            return None

    # --- hold (пауза для watchdog'а) и лок старта -------------------------
    def caller_thread(self) -> str:
        return (self.env.get('BB_THREAD_ID') or '').strip()

    def hold_read(self) -> dict:
        try:
            raw = self.hold_file.read_text(encoding='utf-8', errors='replace').strip()
        except FileNotFoundError:
            return {}
        if not raw:
            return {'kind': 'manual', 'owner_thread': '', 'reason': 'пустой файл (поставлен руками)'}
        try:
            data = json.loads(raw)
            return data if isinstance(data, dict) else {'kind': 'manual', 'reason': raw[:200]}
        except json.JSONDecodeError:
            return {'kind': 'manual', 'reason': raw[:200]}

    def hold_age(self, hold: dict) -> float:
        try:
            return time.time() - float(hold.get('since') or self.hold_file.stat().st_mtime)
        except Exception:  # noqa: BLE001
            return 0.0

    def hold_write(self, kind: str, ttl: int, reason: str = '') -> None:
        hold = {
            'kind': kind,
            'ttl': int(ttl),
            'since': int(time.time()),
            'owner_user': self.env.get('USERNAME') or self.env.get('USER') or '',
            'owner_thread': self.caller_thread(),
            'owner_cwd': str(Path.cwd()),
            'reason': reason or ('offline ibcmd cycle' if kind == 'offline' else 'pause before offline work'),
        }
        self.hold_file.write_text(json.dumps(hold, ensure_ascii=False, indent=2) + '\n',
                                  encoding='utf-8')

    def hold_blocker(self, force: bool) -> dict | None:
        """Возвращает hold, который запрещает start (None — можно стартовать)."""
        if not self.hold_file.exists():
            return None
        hold = self.hold_read()
        if force:
            print(f"ВНИМАНИЕ: --force — снимаю чужой hold: {self.hold_describe(hold)}")
            return None
        age = self.hold_age(hold)
        try:
            ttl = float(hold.get('ttl') or TTL_PAUSE)
        except (TypeError, ValueError):
            ttl = TTL_PAUSE
        if age > ttl:
            print(f"ВНИМАНИЕ: hold протух ({self.hold_describe(hold, age)}) — снимаю и стартую")
            return None
        owner = (hold.get('owner_thread') or '').strip()
        if owner and owner != self.caller_thread():
            return hold
        if owner and owner == self.caller_thread():
            print(f"hold этого же треда ({owner}) — снимаю и стартую")
            return None
        # hold без владельца-треда (руками/консоль/watchdog): ведём себя как раньше,
        # но громко говорим, чей он и сколько ему.
        print(f"ВНИМАНИЕ: снимаю hold без владельца-треда: {self.hold_describe(hold, age)}")
        return None

    def hold_describe(self, hold: dict, age: float | None = None) -> str:
        if age is None:
            age = self.hold_age(hold)
        kind = hold.get('kind') or '?'
        reason = hold.get('reason') or '—'
        thread = hold.get('owner_thread') or '—'
        user = hold.get('owner_user') or '—'
        ttl = hold.get('ttl') or '—'
        return (f"kind={kind}, возраст {fmt_age(age)}, ttl={ttl} с, "
                f"тред {thread}, пользователь {user}, причина: {reason}")

    def _lock_alive(self) -> tuple[int, float]:
        try:
            data = json.loads(self.start_lock.read_text(encoding='utf-8'))
            pid = int(data.get('pid') or 0)
            since = float(data.get('since') or 0)
        except Exception:  # noqa: BLE001
            return 0, 0.0
        if not self._alive(pid):
            return 0, time.time() - since
        return pid, time.time() - since

    def start_lock_acquire(self) -> int:
        """Взять лок старта. Возвращает pid чужого лока (0 — взяли)."""
        for _ in range(2):
            try:
                fd = os.open(self.start_lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            except FileExistsError:
                pid, age = self._lock_alive()
                if age > TTL_START_LOCK or (pid and not self._alive(pid)):
                    self.start_lock.unlink(missing_ok=True)
                    continue
                return pid or -1
            with os.fdopen(fd, 'w', encoding='utf-8') as fh:
                json.dump({'pid': os.getpid(), 'since': time.time()}, fh)
            return 0
        return -1

    def start_lock_release(self) -> None:
        try:
            data = json.loads(self.start_lock.read_text(encoding='utf-8'))
            if int(data.get('pid') or 0) == os.getpid():
                self.start_lock.unlink(missing_ok=True)
        except Exception:  # noqa: BLE001
            pass

    # --- действия --------------------------------------------------------
    def action_yaml(self) -> int:
        path = Path(self.config)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.render_yaml(), encoding='utf-8')
        print(f'конфигурация записана: {path}')
        return 0

    def _log_rotate(self) -> None:
        """Старый лог сохраняем: «лог пуст» после перезапуска убивал диагностику."""
        try:
            if self.log_file.exists() and self.log_file.stat().st_size > 0:
                prev = self.log_file.with_suffix('.log.prev')
                prev.unlink(missing_ok=True)
                self.log_file.replace(prev)
        except Exception:  # noqa: BLE001
            pass

    def _diagnose_not_ready(self, pid: int, owner: int, code: int | None) -> None:
        print('ОШИБКА: узел не готов (база не поднята).', file=sys.stderr)
        print(f'  мой pid: {pid} (жив: {"да" if self._alive(pid) else "нет"})', file=sys.stderr)
        print(f'  http {self.http_port}: {"слушает, pid " + str(owner) if owner else "закрыт"}'
              f', ответ узла: {code if code is not None else "нет"}', file=sys.stderr)
        print(f'  отладка {self.debug_port}: {"слушает" if self.port_open(self.debug_port) else "закрыт"}',
              file=sys.stderr)
        print(f'  /S {self.regport}: {"слушает" if self.port_open(self.regport) else "закрыт"}',
              file=sys.stderr)
        print(f'  лог: {self.log_file} ({self.log_file.stat().st_size if self.log_file.exists() else 0} байт)',
              file=sys.stderr)
        if owner and owner != pid:
            print(f'  ВНИМАНИЕ: порт держит чужой процесс {owner} — это не наш узел. '
                  f'Чужой не убиваем: {self._owner_hint(owner)}', file=sys.stderr)
        else:
            print('  что делать: подождать 1-2 мин и повторить status; не убивать процесс '
                  'taskkill /F (это блокировка ИБ/лицензия, а не битая база); '
                  'журнал 1С: .tmp/ibsrv/data/log-data', file=sys.stderr)

    def _owner_hint(self, owner: int) -> str:
        """Образ и командная строка процесса-владельца — для диагностики (кроссплатформенно:
        `tasklist` есть только на Windows, раньше на POSIX hint падал трейсбеком)."""
        image = self.proc_image(owner)
        cmd = self.proc_cmdline(owner)
        if image and cmd:
            return f'{image}: {cmd}'
        if image:
            return image
        return f'PID {owner}: образ/командную строку прочитать не удалось'

    def action_start(self, force: bool = False) -> int:
        pid = self.pid()
        owner = self.port_owner(self.http_port)
        if pid:
            if owner and owner != pid:
                print(f'ОШИБКА: pid-файл указывает на {pid}, а порт {self.http_port} держит {owner}.',
                      file=sys.stderr)
                print(f'  чужой узел не трогаем: {self._owner_hint(owner)}', file=sys.stderr)
                return 3
            if owner == pid and self.http_probe() is not None:
                print(f'узел уже запущен и отвечает, pid={pid}')
                self.hold_file.unlink(missing_ok=True)
                return 0
            print(f'ОШИБКА: узел pid={pid} жив, но не отвечает на http://127.0.0.1:{self.http_port}'
                  f'{self.http_base}', file=sys.stderr)
            print('  повторный запуск не делаю (это не «упал», а завис: база/лицензия/запрос).',
                  file=sys.stderr)
            self._diagnose_not_ready(pid, owner, None)
            return 3

        # Ошибка конфигурации — до лока и до Popen: раньше битый IBSRV_PATH давал
        # traceback FileNotFoundError вместо внятного rc=4.
        if not Path(self.exe).is_file():
            die(f'IBSRV_PATH не найден: {self.exe} (проверьте .env)', 4)
        if not self.db_path:
            die('в .env нет IBSRV_DB_PATH (каталог файловой базы)', 4)

        blocker = self.hold_blocker(force)
        if blocker is not None:
            print('ОТКАЗ: база на паузе другого владельца — не снимаю чужой hold.', file=sys.stderr)
            print(f'  hold: {self.hold_describe(blocker)}', file=sys.stderr)
            print('  чей hold — тот и возобновляет: его -Action start снимет hold сам,'
                  ' движок загрузки снимает свой hold в конце прогона (-Action hold-release).',
                  file=sys.stderr)
            print(f'  если пауза точно не нужна: {sys.argv[0]} -Action start --force', file=sys.stderr)
            print(f'  или дождаться ttl: {sys.argv[0]} -Action status покажет возраст и ttl hold',
                  file=sys.stderr)
            return 4

        lock_pid = self.start_lock_acquire()
        if lock_pid:
            print(f'ОТКАЗ: уже идёт старт (pid {lock_pid if lock_pid > 0 else "?"}, '
                  f'лок {self.start_lock}). Подождите 1-2 мин и повторите status.', file=sys.stderr)
            return 5
        try:
            if self.hold_file.exists():
                self.hold_file.unlink(missing_ok=True)
            self.action_yaml()
            Path(self.data).mkdir(parents=True, exist_ok=True)
            args = [self.exe, f'--config={self.config}', f'--data={self.data}']
            if self.debug:
                args += [f'--debug={self.debug}', f'--debug-port={self.debug_port}']
            if self.regport:
                args += [f'--direct-regport={self.regport}']
            if self.extra_args:
                args += shlex.split(self.extra_args)
            self._log_rotate()
            log = open(self.log_file, 'wb')
            kwargs: dict = {'stdout': log, 'stderr': subprocess.STDOUT, 'stdin': subprocess.DEVNULL}
            if os.name == 'nt':
                kwargs['creationflags'] = 0x00000008 | 0x08000000  # DETACHED | NEW_GROUP
            else:
                kwargs['start_new_session'] = True
            proc = subprocess.Popen(args, **kwargs)
            self.pid_file.write_text(str(proc.pid), encoding='utf-8')
            print(f'старт: pid={proc.pid}, ждём готовности до {self.start_timeout} с '
                  f'(порт {self.http_port}, база {self.db_path})')
            deadline = time.time() + self.start_timeout
            code: int | None = None
            while time.time() < deadline:
                time.sleep(1)
                if proc.poll() is not None:
                    print('ОШИБКА: узел завершился сразу — лог:', file=sys.stderr)
                    print(self.log_file.read_text(encoding='utf-8', errors='replace')[-1500:],
                          file=sys.stderr)
                    self.pid_file.unlink(missing_ok=True)
                    return 3
                owner = self.port_owner(self.http_port)
                if owner == proc.pid:
                    code = self.http_probe()
                    if code is not None:
                        break
                elif owner and owner != proc.pid:
                    print(f'ОШИБКА: порт {self.http_port} занял чужой процесс {owner} '
                          f'(наш pid {proc.pid} висит без порта).', file=sys.stderr)
                    print(f'  чужой узел не убиваем: {self._owner_hint(owner)}', file=sys.stderr)
                    print('  что делать: -Action status на обеих базах, затем освободить порт '
                          'у владельца (.stop + schtasks /Run или -Action stop в его воркспейсе).',
                          file=sys.stderr)
                    return 3
            owner = self.port_owner(self.http_port)
            if owner != proc.pid or code is None:
                self._diagnose_not_ready(proc.pid, owner, code)
                return 3
            print(f'узел запущен и отвечает: pid={proc.pid} (владелец порта {self.http_port}: {owner})')
            print(f'  веб-клиент/HTTP-сервисы: http://{self.http_address}:{self.http_port}/'
                  f'  (GET {self.http_base} → {code})')
            print(f'  прямое соединение (/S): {self.http_address}:{self.regport}\\{self.name}')
            print(f'  отладка ({self.debug}): порт {self.debug_port}')
            print(f'  лог: {self.log_file}')
            return 0
        finally:
            self.start_lock_release()

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
                                 capture_output=True, text=True, errors='replace')
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

    def action_stop(self, hold: bool = True, offline: bool = False, ttl: int = 0) -> int:
        # Лок — тот же, что у start: иначе окно «start увидел pid → stop убил»
        # даёт агенту rc=0 при мёртвом узле (2026-11-12).
        lock_pid = self.start_lock_acquire()
        if lock_pid:
            print(f'ОТКАЗ: уже идёт старт/останов (pid {lock_pid if lock_pid > 0 else "?"}, '
                  f'лок {self.start_lock}) — stop не выполнен, повторите через 1-2 мин.',
                  file=sys.stderr)
            return 5
        try:
            return self._stop_locked(hold=hold, offline=offline, ttl=ttl)
        finally:
            self.start_lock_release()

    def _stop_locked(self, hold: bool, offline: bool, ttl: int) -> int:
        owner = self.port_owner(self.http_port)
        file_pid = self.pid()
        pid = 0
        if owner:
            # Владелец порта — только кандидат: убивать можно лишь ibsrv своей базы.
            kind = self.node_owner_kind(owner)
            if kind != 'ours':
                image = self.proc_image(owner) or 'образ неизвестен'
                what = 'ibsrv ДРУГОЙ базы' if 'ibsrv' in image.lower() else 'не ibsrv'
                print(f'ОТКАЗ: порт {self.http_port} держит чужой процесс {owner} '
                      f'({image}, {what}) — не глушу.', file=sys.stderr)
                print(f'  чей процесс: {self._owner_hint(owner)}', file=sys.stderr)
                if file_pid and file_pid != owner:
                    print(f'  pid-файл при этом указывает на {file_pid}', file=sys.stderr)
                print('  что делать: -Action status, затем освободить порт у его владельца (его'
                      ' .stop / -Action stop в его воркспейсе) или сменить IBSRV_HTTP_PORT',
                      file=sys.stderr)
                return 5
            pid = owner
            if file_pid and file_pid != owner:
                print(f'ВНИМАНИЕ: pid-файл указывает на {file_pid}, а порт {self.http_port} '
                      f'держит {owner} — гашу владельца порта (это наш ibsrv, pid-файл протух).')
            elif not file_pid:
                print(f'ВНИМАНИЕ: pid-файла нет, но порт {self.http_port} держит {owner} — '
                      f'это наш ibsrv, гашу его.')
        elif file_pid:
            # Порт закрыт, а процесс из pid-файла жив: проверяем, что это ibsrv (защита от reuse pid).
            if self.node_owner_kind(file_pid) != 'ours':
                image = self.proc_image(file_pid) or 'образ неизвестен'
                print(f'ОТКАЗ: pid-файл указывает на {file_pid} ({image}) — это не ibsrv, не глушу.',
                      file=sys.stderr)
                print(f'  {self._owner_hint(file_pid)}', file=sys.stderr)
                print(f'  pid-файл протух; убрать его вручную: {self.pid_file}', file=sys.stderr)
                return 5
            pid = file_pid
        if not pid:
            print('узел не запущен (hold-файл не ставится: базу держать нечего)')
            self.pid_file.unlink(missing_ok=True)
            return 0
        # hold — до остановки узла, иначе watchdog успеет поднять базу посреди цикла.
        if hold:
            kind = 'offline' if offline else 'pause'
            self.hold_write(kind, ttl or (TTL_OFFLINE if offline else TTL_PAUSE))
            print(f'hold-файл watchdog\'а поставлен: {self.hold_file}')
            print(f'  {self.hold_describe(self.hold_read())}')
            print('  снять: -Action hold-release (тот же тред) или -Action start --force')
        else:
            self.hold_file.unlink(missing_ok=True)
        ok, out = self._kill(pid)
        still_owner = self.port_owner(self.http_port)
        if ok and not still_owner:
            self.pid_file.unlink(missing_ok=True)
            self.stop_file.unlink(missing_ok=True)
            print(f'узел остановлен (pid={pid}, порты закрыты)')
            return 0
        # НЕ рапортуем успех: база осталась занятой, любая загрузка потом упадёт
        # «Ошибка блокировки информационной базы для конфигурирования».
        print(f'НЕ УДАЛОСЬ остановить узел (pid={pid}) — процесс жив, база заблокирована.')
        if still_owner and still_owner != pid:
            print(f'  порт {self.http_port} держит {still_owner} — это другой процесс, '
                  f'проверьте, что база ваша: {self._owner_hint(still_owner)}')
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

    def action_hold_release(self, force: bool = False) -> int:
        """Снять hold. Зачем: движок загрузки сам ставит hold на оффлайн-цикл
        и сам же его снимает по завершении прогона (start из другого треда после
        цикла должен работать), а не ждать ttl.

        Чужой hold без --force не снимается (rc=4).
        """
        if not self.hold_file.exists():
            print('hold-файла нет — снимать нечего')
            return 0
        hold = self.hold_read()
        owner = (hold.get('owner_thread') or '').strip()
        caller = self.caller_thread()
        if owner and owner != caller and not force:
            print('ОТКАЗ: hold другого владельца — не снимаю (это защита чужого цикла).',
                  file=sys.stderr)
            print(f'  hold: {self.hold_describe(hold)}', file=sys.stderr)
            print(f'  снять осознанно: {sys.argv[0]} -Action hold-release --force',
                  file=sys.stderr)
            print(f'  или база поднимется после ttl: {sys.argv[0]} -Action start --force',
                  file=sys.stderr)
            return 4
        self.hold_file.unlink(missing_ok=True)
        where = 'принудительно (--force)' if (owner and owner != caller) else 'свой'
        print(f'hold снят {where}: {self.hold_describe(hold)}')
        return 0

    def action_status(self) -> int:
        pid = self.pid()
        print(f'узел: {"запущен pid=" + str(pid) if pid else "нет pid-файла"}')
        listening = 0
        for label, port in (('http', self.http_port), ('отладка', self.debug_port),
                            ('прямое соединение', self.regport)):
            open_ = self.port_open(port)
            listening += 1 if open_ else 0
            print(f'  {label}: {port} — {"слушает" if open_ else "закрыт"}')
        owner = self.port_owner(self.http_port)
        print(f'  владелец порта {self.http_port}: {owner if owner else "нет"}')
        if owner:
            kind = self.node_owner_kind(owner)
            label = {'ours': 'наш ibsrv', 'foreign': 'ЧУЖОЙ процесс (stop его не тронет)',
                     'unknown': 'образ прочитать не удалось'}[kind]
            print(f'  чей это процесс: {label}')
        code = self.http_probe() if owner else None
        print(f'  ответ узла: {code if code is not None else "нет"}')
        if pid and owner and owner != pid:
            print(f'  ОШИБКА: pid-файл ({pid}) ≠ владелец порта ({owner}) — узел запущен другой сессией, '
                  f'pid-файл протух')
        if not pid and listening and not owner:
            print('  ВНИМАНИЕ: порты слушают, а pid-файла нет — узел запущен другой сессией')
            print('  (pid-файл потерян старым stop/taskkill). Гасить: -Action stop')
            print('  или tasklist /FI "IMAGENAME eq ibsrv.exe" + taskkill из elevated-шелла.')
        if self.hold_file.exists():
            hold = self.hold_read()
            print(f'  hold-файл: есть — {self.hold_describe(hold)}')
            try:
                if self.hold_age(hold) > float(hold.get('ttl') or TTL_PAUSE):
                    print('  ВНИМАНИЕ: hold протух — -Action start снимет его сам; '
                          'если цикл ещё идёт, обновите hold (-Action stop)')
            except (TypeError, ValueError):
                pass
        else:
            print('  hold-файл: нет — база под контролем watchdog\'а')
        if self.start_lock.exists():
            lock_pid, lock_age = self._lock_alive()
            if lock_pid:
                print(f'  лок старта: занят pid {lock_pid}, возраст {fmt_age(lock_age)}')
            else:
                print(f'  лок старта: протух (pid мёртв, возраст {fmt_age(lock_age)}) — '
                      f'снимется следующим start')
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
    parser.add_argument('--offline', action='store_true',
                        help='stop: hold с kind=offline и ttl 45 мин (оффлайн-цикл ibcmd/designer)')
    parser.add_argument('--ttl', type=int, default=0,
                        help=f'stop: время жизни hold в секундах (по умолчанию {TTL_OFFLINE} для --offline, '
                             f'{TTL_PAUSE} для паузы)')
    parser.add_argument('--force', action='store_true',
                        help='start/hold-release: снять ЧУЖОЙ hold осознанно (печатает, чей он); '
                             'лок старта не снимает')
    parser.add_argument('--timeout', type=int, default=0,
                        help=f'start: сколько ждать готовности узла, с (по умолчанию IBSRV_START_TIMEOUT '
                             f'или {DEFAULT_START_TIMEOUT})')
    parser.add_argument('--root', default='.', help='корень потребителя (где .env)')
    args = parser.parse_args()

    root = Path(args.root).resolve()
    env = read_env(root)
    if args.timeout:
        env['IBSRV_START_TIMEOUT'] = str(args.timeout)
    node = Node(root, env)

    if args.Action == 'yaml':
        return node.action_yaml()
    if args.Action == 'start':
        return node.action_start(force=args.force)
    if args.Action == 'stop':
        return node.action_stop(hold=not args.no_hold, offline=args.offline, ttl=args.ttl)
    if args.Action == 'hold-release':
        return node.action_hold_release(force=args.force)
    if args.Action == 'basic':
        return node.action_basic(args.show)
    return node.action_status()


if __name__ == '__main__':
    raise SystemExit(main())
