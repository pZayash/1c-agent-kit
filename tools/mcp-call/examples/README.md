# Примеры аргументов (`mcp-call`)

Готовые наборы args-json в kit **не поставляются**: они специфичны для
конфигурации и MCP-инструментов потребителя. Держи их в репо потребителя
(например, `tools/mcp-call-examples/`) и передавай через `@file`.

## Формат аргументов

Аргументы tool — JSON-объект. Способы передачи:

```bash
# inline (короткий JSON)
bash tools/mcp-call/mcp-call.sh query_post '{"query": "ВЫБРАТЬ 1"}'

# из файла (@path; UTF-8, без $(cat) в bash)
bash tools/mcp-call/mcp-call.sh execute_code_safe_transaction @args.json
```

`@file` предпочтителен для больших payload и кириллицы — `mcp-call.sh`
передаёт файл через `jq --slurpfile`, минуя лимит argv и проблемы
экранирования Git Bash на Windows.

## BSL: шаблон проверки

Итог клади в переменную **`Результат`**. Для проверок без записи в БД
используй `execute_code_safe_transaction` (транзакция откатывается):

```json
{
  "code": "Результат = 1 + 1;"
}
```

```bash
bash tools/mcp-call/mcp-call.sh execute_code_safe_transaction @verify-args.json
```

## Где хранить наборы

Для своих сценариев предложи потребителю каталог `tools/mcp-call-examples/`
в корне его репо. Скрипты потребителя могут резолвить каталог примеров в
порядке: `MCP_CALL_EXAMPLES` (env) → `examples/` → `tools/mcp-call-examples/`.

Описание CLI и конфига — [../README.md](../README.md),
канон `.mcp.json` — [docs/ai/mcp-config.md](../../../docs/ai/mcp-config.md).
