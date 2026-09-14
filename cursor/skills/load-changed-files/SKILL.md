---
name: load-changed-files
description: >-
  Загрузка conf/cfe.xml в dev-ИБ: предпочтительно из git; --no-extensions если агент не
  трогал cfe.xml (иначе чужие правки расширений блокируют загрузку); --list-file — фолбэк.
  Partial load, -U после правок метаданных.
argument-hint: "[-C] [-U] [-u] [--no-close] [--no-extensions] [--reset-marker] [--verbose] [--list-file PATH]"
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /load-changed-files — Загрузка изменений conf в dev-ИБ

**Единственный канон** загрузки XML-исходников (`conf/`, `cfe.xml/`)
в рабочую dev-базу проекта.

## Запрещено (путаница с cc-1c-skills)

**Не вызывать** и **не предлагать** навыки upstream, исключённые из sync проекта:

- `/db-load-git`, `/db-load-xml`, `/db-load-cf`, `/db-update`

Они дублируют часть сценария, но **не** покрывают `.env`, `cfe.xml`, preflight поддержки,
`--auto-unsupport`. Подробнее: [docs/ai/load-config-to-dev.md](../../docs/ai/load-config-to-dev.md).

## Когда использовать

- После правок в `conf/` или `cfe.xml/` — `./load-changed-files.sh` [`-U`]: git-изменения
  (working-tree + committed с маркера, см. ниже). **Предпочтительный режим.**
- После merge другой ветки (например `agents/2` → текущая) — `./load-changed-files.sh -U`
  (committed-изменения с маркера подхватятся автоматически).
- Только `conf/`, без `cfe.xml/` — `./load-changed-files.sh -U --no-extensions`.
- Перед проверкой в dev-ИБ (форма, MCP, e2e) — обычно с `-U`.
- После правок `cfe.xml/MCP_Сервер/` — `./load-changed-files.sh -U` или `./update-mcp-server.sh`.

## Когда `--list-file` (фолбэк)

Только если нужных файлов **нет** среди git-изменений:

- dirty worktree — залить только свои файлы, не весь `git status`;
- resync в dev без актуального git diff;
- изоляция перечня агента от чужих правок в worktree.

Не использовать `--list-file`, если правки уже в `git status`
для `conf/` / `cfe.xml/`.

## Когда `--no-extensions` (обязательно для агента без правок cfe.xml)

Git-режим подхватывает **все** изменения в `cfe.xml/` из worktree (staged/unstaged/untracked),
в том числе чужие — от другого агента, ветки или незакоммиченной сессии.

Если агент **не менял расширения** (только `conf/`), всегда добавляй `--no-extensions`:

```bash
./load-changed-files.sh -U --no-extensions
```

Иначе скрипт попытается загрузить чужое расширение целиком и упадёт на ошибке
валидации/синтаксиса в `cfe.xml/`, хотя твои правки в `conf/` корректны.
Типичный сценарий: параллельные агенты, один сломал расширение — второй
блокируется при обычном `./load-changed-files.sh -U`.

Без флага `--no-extensions` — только если агент **сам** правил `cfe.xml/` и готов
чинить ошибки расширения при загрузке.

## Merge из других веток (слоты agents/N, хост)

Git-режим учитывает не только working-tree, но и **committed**-изменения с маркера
последней успешной загрузки: `git diff <marker>..HEAD` (включая merge).

Маркер: `.tmp/load-cache/loaded-head-<имя_ИБ>.sha` — SHA-1 `HEAD` на момент успешной
загрузки committed-изменений. Per ИБ; в слоте `/work` — свой маркер (изолирован от хоста).

**Обновляется**, если загрузка успешна, были committed-изменения, без `--list-file`
и без `--no-extensions`.

**Не обновляется**, если грузилось только из working-tree или через `--list-file` /
`--no-extensions` — следующий запуск снова увидит committed-diff.

**Первый запуск** без маркера — только working-tree (как раньше). Перед первым merge
запиши маркер вручную или выполни успешную полную загрузку после merge:

```bash
git rev-parse HEAD > .tmp/load-cache/loaded-head-<имя_ИБ>.sha
```

**Сброс** (rebase, reset, force-push, принудительный resync):

```bash
./load-changed-files.sh --reset-marker -U
```

Env: `RESET_LOAD_MARKER=true`.

## Когда НЕ использовать

- Сборка EPF из conf → [`build-epf-from-conf.sh`](../../build-epf-from-conf.sh)
  на ИБ целевой конфигурации (`IB_CONNECTION` / `EPF_IB_CONNECTION`).
- Полная замена конфигурации в ИБ — вне workflow проекта.
- Выгрузка из ИБ в XML → `db-dump-xml` / `db-dump-cf`.

- **Ложный дифф форм** (Behavior Авто↔Обычное после загрузки с `Configuration.xml`
  формата 8.5) → не этот скилл на 8.5; см.
  [`docs/ai/phantom-form-diff.md`](../../docs/ai/phantom-form-diff.md) и
  `./tools/phantom-form-diff/load.sh --list-file …`.

## Предусловия

1. `cp .env.example .env` и настроены `IB_CONNECTION`, `DESIGNER_PATH`, `CONFIG_PATH`.
2. По желанию: `xml-wellformed` по изменённым `*.xml` перед загрузкой.
   После **`meta-edit`** — [metadata-xml-load-pitfalls.md](../../docs/ai/metadata-xml-load-pitfalls.md)
   (`rg` по `d5p1:`, `Number(N)` в Type, `&#13;`).
3. Имя слота в стартере 1С может отличаться от каталога ИБ — резолв из `ibases.v8i`.

## Команда

Из корня репозитория (без `cd`):

```bash
./load-changed-files.sh
```

### Частые варианты

```bash
# Быстрый ручной тест: залить, обновить БД, открыть тонкий клиент (1cv8c.exe)
./load-changed-files.sh -C

# Загрузить + обновить конфигурацию БД (типично после правок)
./load-changed-files.sh -U

# Объекты на поддержке — снять и загрузить
./load-changed-files.sh -u
./load-changed-files.sh -U -u
./load-changed-files.sh -C -u

# Не закрывать конфигуратор (MCP, ручная работа в конфигураторе)
./load-changed-files.sh -U --no-close

# MCP_Сервер: загрузка + переподключение Cursor MCP
./update-mcp-server.sh

# Фолбэк: явный список, если нужных файлов нет в git-изменениях
./load-changed-files.sh -U --list-file .tmp/agent-load.txt

# Только основная конфигурация, без расширений
./load-changed-files.sh -U --no-extensions

# После merge: сброс маркера + полная перезаливка committed-изменений
./load-changed-files.sh --reset-marker -U
```

### Явный список (`--list-file`, фолбэк)

**Фолбэк**, когда git-режим не подходит. **Заменяет** git-discovery (не union).
Один путь на строку; `#` — комментарий.
Каталог `.tmp/` уже в `.gitignore`.

```text
CommonModules/яя_/Ext/Module.bsl
Documents/ЗаказПокупателя/Forms/ФормаЗаказНаряда/Ext/Form/Module.bsl
cfe.xml/MCP_Сервер/…/Module.bsl
```

Допустимы префиксы `conf/…`, `cfe.xml/<Расширение>/…` или путь относительно `conf/`.
Путь к расширению → загрузка **всего** каталога расширения (как в git-режиме).
`PATH=-` — читать список из stdin.

**Запрещено:** править `changed_files.txt` вручную — только `--list-file`.

### Флаги

| Флаг | Назначение |
| --- | --- |
| `-C`, `--open-client` | `-U`, закрыть 1С, открыть `1cv8c.exe ENTERPRISE` |
| `-U`, `--update-db` | `/UpdateDBCfg` после загрузки |
| `-u`, `--auto-unsupport` | Снять с поддержки объекты из списка preflight |
| `-n`, `--no-close` | Не закрывать конфигуратор (с `-C` клиент закроется) |
| `-H`, `--human-mode` | Закрыть и переоткрыть конфигуратор (без `-U`) |
| `-c`, `--config-path` | Каталог conf (default: `conf`) |
| `-e`, `--extensions-path` | Каталог расширений (default: `cfe.xml`) |
| `-i`, `--ib-connection` | Строка ИБ (иначе `IB_CONNECTION` из `.env`) |
| `-d`, `--designer-path` | Путь к `1cv8.exe` |
| `--force-configuration` | Всегда грузить `Configuration.xml` (остальные файлы — по кэшу) |
| `--list-file PATH` | Фолбэк: явный список (заменяет git); `PATH=-` для stdin |
| `--no-extensions` | Только `conf/`; обязателен, если агент не трогал `cfe.xml/` (env: `SKIP_EXTENSIONS=true`) |
| `--reset-marker` | Сбросить маркер HEAD последней загрузки committed-изменений (env: `RESET_LOAD_MARKER=true`) |
| `--verbose` | Полный лог (список файлов, тайминги, команды 1С). По умолчанию — краткий вывод для агентов; `-H`/`-C` включают подробный |
| `-h`, `--help` | Справка |

Лог: `.tmp/load-changed-files.log`. В stdout по умолчанию — кратко (план, WARN/ERROR, SUCCESS, итог по времени); `--verbose` или `-H`/`-C` — прежний подробный вывод.

Кэш: `.tmp/load-cache/files-<ИБ>-<conf>.manifest` (путь<TAB>SHA-256) — файлы из git/listfile,
чей хеш совпадает с последней успешной загрузкой, не попадают в listfile (быстрее).
Старый `configuration-<ИБ>-<conf>.sha256` мигрируется автоматически.
Сброс: удалить manifest или каталог `.tmp/load-cache/`; `--force-configuration` — только для `Configuration.xml`.
`SKIP_CONFIGURATION_CACHE=true` в `.env` — отключить кэш для всех файлов conf.

Маркер merge: `.tmp/load-cache/loaded-head-<ИБ>.sha` — см. раздел «Merge из других веток».

## Алгоритм (кратко)

1. Список: git (working-tree + committed с маркера) **или** `--list-file` (фолбэк).
2. **Rewrite:** `…/Forms/…/Ext/Form/Module.bsl` (и `CommonForms/…`) → родительский
   `Forms/Имя.xml` / `CommonForms/Имя.xml` — баг платформы partial listFile
   (`…Form.…Ext`). Родитель forced против кэша. См. memory
   `partial-load-form-module-bsl`.
3. Файлы conf из списка с неизменённым SHA-256 (кэш manifest) — убрать из listfile.
4. Partial `LoadConfigFromFiles` + listfile для основной конфигурации.
5. Изменённые расширения — загрузка каталога расширения целиком (пропуск при `--no-extensions`).
6. При `-U` — `/UpdateDBCfg`; после успешной загрузки conf — обновить кэш хешей.
7. При успешной загрузке committed-изменений (без `--list-file` / `--no-extensions`) —
   обновить маркер HEAD.

Если нечего грузить — шаги 3–4 пропускаются; при `-U`/`-C` всё равно выполняется `/UpdateDBCfg` основной конфигурации (даже если все файлы отфильтрованы кэшем). Без `-U`/`-C` — `exit 0`. При `-H`/`-C` дополнительно закрывается/открывается конфигуратор или клиент.

## Связанные материалы

- [docs/ai/load-config-to-dev.md](../../docs/ai/load-config-to-dev.md) —
  маршрутизация для агентов.
- [docs/human/development-setup.md](../../docs/human/development-setup.md) —
  настройка `.env`.
- [docs/ai/mcp-server.md](../../docs/ai/mcp-server.md) — MCP после `-U`.
- `xml-wellformed` — проверка XML до загрузки.
