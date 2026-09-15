# mcp-call — CLI для MCP-сервера 1С

Прямой JSON-RPC клиент к MCP-серверу 1С. Минует кэш списка инструментов в Claude Code (VSCode), позволяет агентам вызывать новые/обновлённые инструменты без перезапуска сессии и работает по единому правилу allowlist.

**Точка входа:** `bash tools/mcp-call/mcp-call.sh` (зависимости: `curl`, `jq`).

`mcp-call.py` — тонкий делегат в `.sh` для старых команд и скриптов.

Канон конфига MCP-серверов — [docs/ai/mcp-config.md](../../docs/ai/mcp-config.md).

## Когда использовать

Используй эту обёртку **вместо** прямых curl/python скриптов когда:

- В MCP-сервере появился новый инструмент, а Claude Code его не видит (`mcp__dev_dt__*` не в списке).
- Нужно вызвать обновлённый инструмент из субагента без перезапуска IDE.
- Хочется одно правило allowlist `Bash(bash tools/mcp-call/mcp-call.sh:*)` вместо разрешений на разные curl-сценарии.

Если инструмент уже доступен через нативные MCP-схемы (`mcp__dev_dt__*` и тулы видны) — используй их напрямую, обёртка не нужна.

## Использование

```bash
# Список инструментов
bash tools/mcp-call/mcp-call.sh --list

# Схема параметров инструмента
bash tools/mcp-call/mcp-call.sh --schema version_get

# Вызов без аргументов
bash tools/mcp-call/mcp-call.sh version_get

# Вызов с аргументами (JSON-объект)
bash tools/mcp-call/mcp-call.sh query_post '{"query": "ВЫБРАТЬ 1"}'

# Другой сервер из конфига
bash tools/mcp-call/mcp-call.sh --server prod_dt version_get

# Прямой URL (минует конфиг MCP; заголовки JWT не подставляются)
bash tools/mcp-call/mcp-call.sh --url http://127.0.0.1/demo.dt/hs/mcp version_get

# BSL во фрагменте (аргументы из файла — UTF-8, без $(cat) в bash)
bash tools/mcp-call/mcp-call.sh execute_code_safe_transaction @path/to/args.json
```

**Песочница:** в Docker (`/.dockerenv`) `127.0.0.1` → `host.docker.internal`.
Старый вызов `python tools/mcp-call/mcp-call.py …` по-прежнему работает (делегат).

## Конфигурация

Файл конфигурации ищется **в корне репозитория** (текущая рабочая директория), в порядке:

1. `.mcp.json` — канон;
2. `.cursor/mcp.json` — legacy fallback (как в Cursor IDE, часто в `.gitignore`).

Из записи `mcpServers.<ключ>` читаются:

- `url` — базовый URL HTTP-сервиса MCP (к нему добавляется `/rpc`, если суффикса ещё нет);
- `headers` — дополнительные HTTP-заголовки, в т.ч. **`Authorization: Bearer <JWT>`**.

Заголовки из конфига передаются во **все** запросы (`tools/list`, `tools/call`). Без Bearer
сервер с JWT в vrd отвечает **HTTP 401** (тело может быть пустым) — это не «сломанный MCP»,
а отсутствие или просроченный токен. Ротацию токена выполняет скрипт потребителя
(в kit его нет); схема конфига — [docs/ai/mcp-config.md](../../docs/ai/mcp-config.md).

По умолчанию используется сервер `dev_dt`.

Опции переопределения:

- `--server <key>` — другой ключ из `mcpServers` (например, `prod_dt`).
- `--url <full_url>` — адрес напрямую; **заголовки из mcp.json не читаются**.
  JWT: `--bearer TOKEN` или `--header "Authorization: Bearer …"`.
- `--header "Name: value"` — доп. заголовок (можно несколько; работает и с `--server`).
- `--bearer <jwt>` — сокращение для Authorization Bearer.
- `--config <path>` — явный путь к JSON с `mcpServers`.
- `--timeout <seconds>` — таймаут запроса (по умолчанию 60 с).
- `--id <int>` — id JSON-RPC запроса (по умолчанию 1).

## Коды возврата

| Код | Значение |
| --- | --- |
| 0 | Успех: `isError=false` и (если тело — JSON) нет `success: false` |
| 1 | Ошибка инструмента: `isError=true` **или** в JSON-теле tool `success: false` |
| 2 | Ошибка JSON-RPC (`error` в ответе сервера) |
| 3 | Сетевая ошибка / некорректный ответ |
| 4 | Ошибка аргументов / конфигурации |

По умолчанию CLI завершается с кодом **1**, если разобранный JSON ответа tool содержит
`"success": false`, даже при `isError: false` в обёртке MCP (например
`[command_not_found]`, `[client_only]`). Это нужно shell и агентам, которые проверяют
только exit code.

Флаг **`--no-fail-on-success-false`** отключает проверку `success` в теле (legacy:
exit 0 при `isError: false`).

## Формат вывода

- Для `--list`: по одной строке на инструмент `<имя>\t<первая строка описания>`.
- Для `--schema`: красиво отформатированный JSON `inputSchema`.
- Для вызова: содержимое `result.content[0].text`. Если оно валидный JSON — печатается как форматированный JSON; иначе — как plain-text.
- Кириллица на вход и выход — через UTF-8, без экранирования (`ensure_ascii=False`).

## Крупный payload (`extension_load_post`)

`.cfe` в base64 — мегабайты. Не передавать args inline в argv `jq`.

```bash
# Рекомендуется
bash tools/mcp-call/extension-load-cfe.sh \
  --server dev_db_privileged \
  --cfe .tmp/MyExtension.cfe

# Или вручную: JSON-файл → @path (mcp-call пишет через jq --slurpfile)
bash tools/mcp-call/mcp-call.sh --server dev_db_privileged \
  --timeout 600 extension_load_post @.tmp/extension-load.json
```

## StreamableHTTP-серверы (`/mcp` без `/hs/`)

Серверы вида `http://host:port/mcp` (например, Answer42, qmd) отличаются от
HTTP-сервисов 1С:

- endpoint используется **как есть** (суффикс `/rpc` не добавляется);
- запрос идёт с `Accept: application/json, text/event-stream` — без
  `text/event-stream` такой сервер отвечает `406`;
- ответ приходит SSE-потоком (`event: message` + `data: {…}`) — CLI достаёт
  сообщение с нужным `id`.

Определение — по форме URL (та же эвристика, что в
[`test-connected-mcp.py`](test-connected-mcp.py)): путь содержит `/hs/` → 1С
JSON-RPC, иначе оканчивается на `/mcp` → streamable.

## Подстановка `${VAR}` не выполняется

`mcp-call.sh` читает `url` и `headers` из конфига **буквально**: `${VAR}` из
`.env` он не раскрывает. Для IDE-клиентов (Cursor, VS Code, Claude Code)
канон — [`.mcp.json`](../../.mcp.json) с плейсхолдерами, для CLI тот же сервер
нужно продублировать literal-значениями в `.cursor/mcp.json` (файл локальный,
в `.gitignore`).

## JWT и диагностика 401

| Симптом | Что проверить |
| --- | --- |
| `HTTP 401` в stderr | В `.mcp.json` / `.cursor/mcp.json` у сервера есть `headers.Authorization` |
| Пустой ответ, код 3 | Тот же 401; не путать с недоступным Apache/публикацией |
| Работает в Cursor, не из CLI | Cursor подставляет headers; CLI читает тот же файл — путь `--config` и cwd = корень репо |
| `--url` без заголовков | Для JWT нужен конфиг или свой `curl` с `-H` |

Проверка **всех** серверов из `.mcp.json` / `.cursor/mcp.json` (1С + qmd):

```bash
python tools/mcp-call/test-connected-mcp.py
```

Скрипт читает все ключи `mcpServers`, для 1С — `tools/list` + `version_get`, для qmd
(streamable HTTP) — `health`, `initialize` + `tools/list`.

Секреты (JWT) — только в `.env` (gitignored), в `.mcp.json` — имена переменных.

## BSL: `execute_code` и `execute_code_safe_transaction`

Для проверок и smoke-тестов предпочтителен
**`execute_code_safe_transaction`**: транзакция откатывается, запись в БД не остаётся.

Формат аргументов — JSON-объект в argv или `@file.json` (UTF-8):

```json
{
  "code": "Док = Документы.ЗаказПокупателя.НайтиПоНомеру(\"000001\", Дата(2025, 8, 30));\nРезультат = Док.Организация;"
}
```

**Не** подставляйте JSON через `$(cat file.json)` в Git Bash на Windows — ломается
кодировка и экранирование. Вызывайте `mcp-call.sh` с `@file` или
передайте JSON как один аргумент из скрипта на Python.

Примеры аргументов (args-json) в kit не поставляются — они специфичны для
конфигурации потребителя; формат и шаблоны — в
[examples/README.md](examples/README.md).

## Промпт для субагентов

> Используй `bash tools/mcp-call/mcp-call.sh` для прямых вызовов MCP 1С. Список: `--list`.
> Схема: `--schema <tool_name>`. Вызов: `<tool_name> '<json_args>'` или `@args.json`.
> Конфиг: `.mcp.json`, иначе `.cursor/mcp.json`; сервер по умолчанию `dev_dt`;
> JWT из `headers` конфига. При 401 — обновить Bearer. Кириллица: UTF-8.
> Коды выхода: 0 успех, 1 ошибка инструмента (в т.ч. `success: false` в JSON-теле),
> 2 JSON-RPC, 3 сеть, 4 аргументы. Legacy: `--no-fail-on-success-false`.
