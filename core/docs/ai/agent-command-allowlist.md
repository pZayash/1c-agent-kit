# Allowlist команд агента (Cursor / Claude Code)

## Зачем

Агент запускает shell через инструмент терминала. В режиме **allowlist** каждая
новая команда требует подтверждения, пока не попадёт в список разрешённых шаблонов.
Проектные правила в allowlist снижают ручные клики и делают поведение предсказуемым
для всей команды.

См. также: [безопасный протокол shell](shell-safety-playbook.md),
[песочница Docker](sandbox.md) (если есть у потребителя).

**Agent-slot:** allowlist/`run.sh` — про **хост**. В изолированном слоте агент
может запускать `python3`/`pip` напрямую, без обёртки песочницы.
См. [sandbox.md § Agent-slot](sandbox.md).

## Где лежит конфиг

| Инструмент | Файл | В git | Назначение |
| --- | --- | --- | --- |
| **Cursor Agent** (IDE, CLI) | `.cursor/cli.json` потребителя | обычно да | Проектный allowlist |
| **Claude Code** | `.claude/settings.json` | нет | Локально: allowlist, MCP |
| **Cursor глобально** | `~/.cursor/cli-config.json` | нет | Личные разрешения |

Cursor и Claude Code читают `.claude/settings.json` в открытом проекте (хуки,
часть настроек агента). Для **общих** правил команды, которые должны попасть в
репозиторий, правьте **`.cursor/cli.json`** потребителя.

При клонировании репозитория:

1. Соберите `.claude/settings.json` по доке init потребителя (MCP, таймауты,
   личный allowlist).
2. Проектный allowlist из git уже в `.cursor/cli.json`.

## Синтаксис правил

Строка в массиве `permissions.allow` — шаблон с префиксом типа инструмента.

### Shell / Bash

Для команд терминала используйте **`Bash(...)`** или **`Shell(...)`** — в Cursor
они эквивалентны (`Bash` нормализуется в `Shell`).

| Шаблон | Смысл |
| --- | --- |
| `Bash(git:*)` | любая подкоманда `git` |
| `Bash(rtk git:*)` | `rtk git …` (если `rtk` в проекте) |
| `Bash(bash tools/sandbox/run.sh:*)` | обёртка песочницы с любыми аргументами |
| `Bash(npx markdownlint:*)` | проверка markdown без `rtk` |

**Двоеточие `:*`** — суффикс «с любыми аргументами после префикса».
**Пробел `*`** — иногда используется для отдельных токенов (`Bash(find *)`).

Матчинг идёт по **полной строке команды**, которую агент отправляет в терминал.
Поэтому:

- `Bash(git:*)` **не** покроет `rtk git status` — нужно отдельное правило.
- Префикс должен совпадать с тем, как агент реально пишет команду (с `rtk` или без).

### Другие типы (кратко)

| Префикс | Пример |
| --- | --- |
| `Read(путь/**)` | чтение файлов |
| `Write(путь)` | запись |
| `WebFetch(домен)` | HTTP из агента |
| `mcp__<server>__*` | MCP-инструменты (в `.claude/settings.json`) |

`permissions.deny` имеет приоритет над `allow`.

## Как добавить разрешение

### 1. Через UI (быстро, только у себя)

В Cursor при запросе на запуск команды: **Allow** / **Always allow**.

Сейчас «Always allow» чаще пишет правило в **`~/.cursor/cli-config.json`**, а не
в проектный `.cursor/cli.json`. Для команды в репозиторий — правка файла вручную
(п. 2).

### 2. В репозиторий (для команды)

Отредактируйте `.cursor/cli.json` потребителя:

```json
{
  "permissions": {
    "allow": [
      "Bash(bash tools/sandbox/run.sh:*)",
      "Bash(rtk git:*)"
    ],
    "deny": []
  }
}
```

Закоммитьте `.cursor/cli.json`. После merge коллеги получат те же правила.

### 3. Локально в Claude Code

В `.claude/settings.json` в `permissions.allow` — тот же синтаксис `Bash(...)`,
плюс MCP, `Read`, `Skill`, таймауты в `env`. Файл **не коммитится**; при переносе
машины копируйте из старого проекта или из шаблона init потребителя.

Перезапуск: новый чат агента или перезагрузка окна Cursor — чтобы подтянулся
обновлённый allowlist.

## Примеры

### Песочница (Python/pip в Docker)

Если у потребителя есть `tools/sandbox/run.sh`:

```bash
bash tools/sandbox/run.sh python tools/…/script.py …
bash tools/sandbox/run.sh pip install -r tools/sandbox/requirements.txt
```

Allowlist:

```json
"Bash(bash tools/sandbox/run.sh:*)"
```

Подробнее: [sandbox.md](sandbox.md).

### BSLLS download (бинарь не в git)

На хосте, не через `run.sh` (нужны `unzip` + сеть GitHub). Пишет в **кэш
хоста**, не в worktree. `bootstrap-kit` скрипт не вызывает.

```bash
bash tools/bsl-check/update-bsl-language-server.sh
```

Allowlist:

```json
"Bash(bash tools/bsl-check/update-bsl-language-server.sh:*)"
```

Канон: потребитель `tools/bsl-check/README.md` (junction на kit).
Env `KIT_BSLLS_ROOT` — общий корень (42: `D:\tools\bslls`).

### Git / gh с `rtk`

```json
"Bash(rtk git:*)",
"Bash(rtk gh:*)"
```

## Ловушки

### `cd` и `git -C` ломают матч

Allowlist сравнивает **целую** строку команды. Префикс `cd "..." &&` меняет
строку — правило не сработает, снова запрос подтверждения.

```bash
# Неправильно для allowlist
cd "c:/repo" && git status

# Правильно (рабочая директория уже корень проекта)
rtk git status
```

См. [shell-safety-playbook.md](shell-safety-playbook.md).

### `run.sh` в цепочке (`&&` / `;`) тоже ломает матч

`Bash(bash tools/sandbox/run.sh:*)` не закрывает склейку с другими командами
(второй `run.sh`, `rtk git`, хост-скрипт). Итог — снова ручной approve.

```bash
# Неправильно
bash tools/sandbox/run.sh python tools/a.py && bash tools/sandbox/run.sh pip install lxml

# Правильно — два отдельных вызова Shell, либо одна оболочка в контейнере
bash tools/sandbox/run.sh bash -c 'python tools/a.py && pip install lxml'
```

Канон: [sandbox.md § Не цепляй run.sh](sandbox.md#не-цепляй-runsh-в-цепочку-на-хосте).

### Проектный `cli.json` и глобальный конфиг

Если в `.cursor/cli.json` есть секция `permissions` с **узким** `allow`, при merge
она может **перекрыть** глобальный `~/.cursor/cli-config.json`, и ранее разрешённые
глобально команды снова начнут спрашивать подтверждение.

**Обход:** дописать нужные шаблоны в проектный `allow` или временно
`cursor agent --disable-project-configs` (только CLI).

**Практика:** держать в `.cursor/cli.json` осознанный минимум общих
команд (sandbox, `rtk git`, …); редкие личные — в глобальном конфиге или в
`.claude/settings.json`.

### Дубли `Bash(bash:*)` и узкое правило

`Bash(bash:*)` разрешает любой `bash …` (широко). Узкое
`Bash(bash tools/sandbox/run.sh:*)` полезно, если позже сузите `bash:*` или для
явной документации в git.

### PowerShell

Скрипты навыков в проекте, если есть песочница, запускаются через
**`bash tools/sandbox/run.sh`**, не через `powershell.exe` — так проще один
шаблон allowlist и Docker-песочница.

**Python:** агенту не вызывать `python3` / `python` / `pip` на хосте — только
`bash tools/sandbox/run.sh python …` (см. [sandbox.md](sandbox.md)).

## Чеклист при добавлении правила

1. Зафиксировать **точную** строку команды из лога агента (с `rtk` / без).
2. Выбрать файл: общее для команды → `.cursor/cli.json`; только у себя →
   `.claude/settings.json` или `~/.cursor/cli-config.json`.
3. Добавить `Bash(префикс:*)` или точное совпадение.
4. Проверить в новом чате без подтверждения.
5. Не коммитить секреты и абсолютные пути с машины разработчика в общий allowlist.

## Связанные документы

- [sandbox.md](sandbox.md) — Docker-песочница и `run.sh` (если есть)
- [shell-safety-playbook.md](shell-safety-playbook.md) — как писать команды агенту
