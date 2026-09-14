# Agent Sandbox (Docker)

Изолированный контейнер `agent-sandbox` для Python, Node.js и Java без ручных
разрешений PowerShell. Обёртка: `tools/sandbox/run.sh` (Bash/WSL) — **если есть
у потребителя** (каталог `tools/sandbox/` в репо).

Навык для агентов: `.cursor/skills/sandbox/SKILL.md` в потребителе — короткий
**interrupt** («Песочница!» / `/sandbox`): повторить заблокированную команду
через `run.sh` без ручного approve. Полные правила и примеры — **этот** файл.

Разрешения allowlist для `bash tools/sandbox/run.sh …`:
[agent-command-allowlist.md](agent-command-allowlist.md) (`.cursor/cli.json`
потребителя).

## Обязательное правило для агентов

### Хост (Windows / WSL)

В shell Cursor на **хосте** **любой** Python, `pip` и **типовые** bash-скрипты
проекта — **только** через:

```bash
bash tools/sandbox/run.sh <команда и аргументы>
```

**Запрещено** на хосте: `python`, `python3`, `py`, `pip`, а также
`powershell.exe … python …` для скриптов репозитория.

Исключение — интерактивная настройка среды разработчиком, не автономные вызовы агента.

### Agent-slot (Linux-контейнер) — sandbox не нужен

**Слот и есть песочница.** Агент уже внутри изолированного Linux-контейнера:
полные права на инструменты (`python3`, `pip`, `node`, `bash`, `git`, …),
`sudo`-free, зависимости нативно. Обёртка `tools/sandbox/run.sh` / контейнер
`agent-sandbox` **не обязательны** — внутри слота `docker` обычно нет.

Запускай напрямую:

```bash
python3 tools/…/check.py …
pip install …
bash scripts/…
```

`bash tools/sandbox/run.sh …` внутри слота тоже сработает (fallback `exec "$@"`),
но это лишний слой — не требуй его.

Признак слота: `AGENT_SLOT=true` в ENV. Канон правил — AGENTS.md потребителя
(секция Agent-slot).

## Почему так на хосте (не «удобство», а требование)

На **Agent-slot** этот раздел не действует — см. § Agent-slot выше.

| Причина | Что происходит без `run.sh` на хосте |
| --- | --- |
| **Allowlist Cursor** | `.cursor/cli.json`: разрешён `Bash(bash tools/sandbox/run.sh:*)`. Прямой `python`/`pip` → approve на каждый скрипт. |
| **Окружение хоста** | На WSL/Windows часто нет Python или пакетов. Команда падает; агент «чинит» хост вместо задачи. |
| **Единая среда** | Контейнер: фиксированный Python/Java, `/workspace` = корень репо. |
| **Договорённость** | Не обходить песочницу — не тратить время на ручные approve. |

**Самопроверка перед Bash (хост):** `python`/`pip` без
`bash tools/sandbox/run.sh` — **стоп**, перепиши.
**В слоте** (`AGENT_SLOT=true`) — прямой `python3`/`pip` **норм**.

### Не цепляй `run.sh` в цепочку на хосте

Allowlist матчит **целую** строку команды на
`Bash(bash tools/sandbox/run.sh:*)`. Любая склейка через `&&` / `;` / `|` с
другой командой или вторым `run.sh` — строка **не** автоподтверждается → снова
ручной approve.

**Запрещено** (хост):

```bash
bash tools/sandbox/run.sh python tools/a.py && bash tools/sandbox/run.sh pip install lxml
rtk git status && bash tools/sandbox/run.sh python tools/a.py
```

**Правильно:** отдельные вызовы Shell — каждый начинается с
`bash tools/sandbox/run.sh …` и больше ничего на хосте.

Нужна последовательность **внутри** контейнера — одна обёртка + `bash -c`:

```bash
bash tools/sandbox/run.sh bash -c 'python tools/a.py && python tools/b.py'
```

См. также ловушку `cd … &&` в
[agent-command-allowlist.md](agent-command-allowlist.md).

## Python и pip

```bash
bash tools/sandbox/run.sh python …
bash tools/sandbox/run.sh pip install …
```

**Неправильно (хост):**

```bash
python3 tools/…/script.py
pip install lxml
```

**Правильно:**

```bash
bash tools/sandbox/run.sh python tools/…/script.py
bash tools/sandbox/run.sh pip install lxml
```

## Bash-скрипты проекта

По умолчанию — тоже через песочницу (тот же allowlist, тот же Linux в контейнере):

```bash
bash tools/sandbox/run.sh bash scripts/…
```

**Исключение:** если задача **принципиально** требует хоста (платформа 1С
`1cv8.exe`, загрузка конфигурации в ИБ, `docker` с хостовым сокетом вне обёртки) —
запуск на хосте **после** неудачи в sandbox или по документу навыка; ожидай
ручное подтверждение allowlist.

## Что запускать через `run.sh` (типовой инвентарь)

| Область | Примеры |
| --- | --- |
| Линтер BSL | `tools/bsl-check/check-bsl.py` (если есть) |
| Навыки cc-1c-skills | `.cursor/skills/*/scripts/*.py` (как в SKILL.md) |
| XML well-formed | `tools/xml-wellformed/check.py` и прочие `tools/*.py` |
| Произвольные `scripts/*.sh` | `bash tools/sandbox/run.sh bash scripts/…` |
| RTK | `bash tools/sandbox/run.sh rtk grep …` (если `rtk` в образе) |

**Не через sandbox:** сборка/запуск 1С на Windows-хосте, `git`/`rtk git`
(отдельные правила allowlist; `git` в образ **не** входит).

## Ограничения контейнера

- В **`agent-sandbox` нет `git`** (намеренно; `rtk git` только на хосте).
- Платформа 1С (`1cv8.exe`) на **хосте**, не в Linux-контейнере — навыки `db-*`,
  `epf-build` и т.п. не заменяются sandbox.
- **MCP на `127.0.0.1`:** из контейнера хост часто = `host.docker.internal`
  (`run.sh` может добавлять `--add-host`).

## Запуск команд

```bash
bash tools/sandbox/run.sh <команда и аргументы>
```

Корень проекта в контейнере: `/workspace`.

## Зависимости Python

Список по умолчанию: `tools/sandbox/requirements.txt` (если есть).

| Пакет | Зачем |
| --- | --- |
| `lxml` | XML-навыки: `cfe-validate`, `meta-*`, `form-*`, … |
| `psutil` | web-publish/stop (если есть) |

В **новом** образе пакеты ставятся при `docker build` (см. `tools/sandbox/Dockerfile`).

## Ручная установка пакетов (для агентов)

**Когда:** после `ModuleNotFoundError` при запуске через `run.sh`.

```bash
bash tools/sandbox/run.sh pip install <имя_пакета>
bash tools/sandbox/run.sh pip install -r tools/sandbox/requirements.txt
```

Повторить исходную команду.

### Важно

- Установка **сохраняется** в `agent-sandbox` до удаления или пересборки контейнера.
- **Не** вызывай `docker exec` напрямую — только `run.sh`.
- Не ставь пакеты на хост Windows/WSL в системный Python, если скрипт идёт через sandbox.

## Пересборка образа

```bash
docker rm -f agent-sandbox
docker build -t agent-sandbox-image tools/sandbox
bash tools/sandbox/run.sh pip install -r tools/sandbox/requirements.txt
```

## Диагностика

| Симптом | Причина | Действие |
| --- | --- | --- |
| Запрос разрешения на `python`/`pip` | Обход allowlist | `bash tools/sandbox/run.sh …` |
| Approve на `run.sh … && …` | Цепочка ломает матч allowlist | Отдельные Shell-вызовы или один `run.sh bash -c '…'` |
| `No module named 'lxml'` | Нет пакета | `pip install -r tools/sandbox/requirements.txt` |
| `run.sh: docker: command not found` | Docker выключен | Сообщить пользователю |
| `bsl-check.py` not found | Win junction → `/mnt/host` в sandbox | `harness/tools/bsl-check/check-bsl.py` |
| Нет `1cv8.exe` | Платформа на хосте | db-* / epf-build — не sandbox |

## Связанные документы

- [agent-command-allowlist.md](agent-command-allowlist.md) — шаблон `run.sh` в allowlist
- [shell-safety-playbook.md](shell-safety-playbook.md) — протокол shell
