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
  (`.cursor/mcp.json`), см. [tools/mcp-call/README.md](../tools/mcp-call/README.md).
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
