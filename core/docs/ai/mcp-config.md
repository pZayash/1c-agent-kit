# Конфиг MCP-серверов (.mcp.json)

## Канон

Единый каталог MCP/HTTP-сервисов проекта — **`.mcp.json` в корне**
(схема Claude Code: `mcpServers.<ключ>.{type,url,headers}`). Де-факто
общий знаменатель: Cursor и VS Code используют ту же схему (своими
файлами), pi читает конфиг через `tools/mcp-call/mcp-call.sh`.

- `.mcp.json` — **коммитится**, содержит только плейсхолдеры
  `${VAR}` / `${VAR:-default}` (URL, токены).
- Значения — в `.env` (gitignored) или окружении. Подстановку `${VAR}`
  делают IDE-клиенты; **`mcp-call.sh` её не делает** — ему нужен literal-конфиг
  (`.cursor/mcp.json`), см. `tools/mcp-call` (стек `1c`).
- `.cursor/mcp.json` — legacy fallback (literal-токены, в `.gitignore`);
  читается с warning, пока Cursor не выведен из эксплуатации.

## Discovery в tools kit

1. `.mcp.json` → 2. `.cursor/mcp.json` (warning).
Сервер по умолчанию: `--server` > `MCP_DEFAULT_SERVER` > первый ключ.

## Правила

- Секреты и токены — только `.env`; в `.mcp.json` — имена переменных.
- Новый сервис: запись в `.mcp.json` + ключи в `.env.example`
  (схема-источник) + строка в `WORKSPACE.md` потребителя (файл локальный, в kit
  шаблона нет).
- Ротация токенов — скриптом потребителя (пример потребителя:
  `scripts/update_mcp_tokens.py` пишет `MCP_JWT_TOKEN_*` в `.env`).
- Внутренние URL в kit не тащить (см. [commit-hygiene.md](commit-hygiene.md));
  `.mcp.json` живёт у потребителя.

## Tools kit

- `tools/mcp-call/mcp-call.sh` — JSON-RPC CLI (`--list`, `--schema`,
  `<tool> '<args>'`, `--url` ad-hoc). README — в каталоге tool.
- `tools/mcp-call/test-connected-mcp.py` — проверка всех `mcpServers`
  из конфига (1С: `tools/list` + `version_get`; qmd: `health`,
  `initialize` + `tools/list`).
- `tools/mcp-call/extension-load-cfe.sh` — загрузка CFE через MCP-tool
  расширения (`extension_load_post`).

Smoke-набор и «боевые» args-json — у потребителя (его каталог примеров и
собственные скрипты); в kit не входят.

## Аргументы инструментов: файлом, не inline-JSON

Inline-JSON в шелле рвётся на кавычках и кириллице (живой случай —
`execute_code_safe_transaction` с BSL-кодом: три падения подряд). Правило:
**аргументы собирает скрипт в файл, в команду идёт путь**.

- `mcp-call.sh` принимает `@path/to/args.json` (UTF-8) вместо inline-объекта:
  файл читается `jq -c .` в отдельный temp и уходит в payload `--slurpfile` —
  ни argv, ни ARG_MAX (крупный `.cfe` base64). Проверено по коду обёртки.
- JSON генерируй генератором (python-скрипт пишет `.tmp/args.json`), а не
  экранированием в bash; BSL-код и JSON в одну shell-строку не склеивать.
- При падении смотреть, **что реально ушло**: обёртка говорит, что не так с
  файлом (`Файл аргументов не найден`, `Аргументы инструмента должны быть
  JSON-объектом`, `Невалидный JSON в аргументах`), а `jq -c . .tmp/args.json`
  показывает нормализованное тело запроса.
- **Нативные MCP-тулы** (`mcp__dev_dt__*`) синтаксиса `@path` не имеют: им
  аргументы передаёт клиент структурой. `@path` — только у CLI-обёртки.

## Диагностика

- **404 на `/hs/mcp` при живой публикации** — у потребителей, где HTTP-сервис
  MCP поднят расширением конфигурации, означает отсутствие расширения в ИБ.
  Проверить наличие расширений в базе.
- Восстановление расширения — **отдельная задача**, не в рамках фикса; в
  отчёте фиксировать как внешний дефект окружения.
