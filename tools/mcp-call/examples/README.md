# Примеры вызовов MCP (`mcp-call`)

Готовые JSON-аргументы для
[`mcp-call.py`](../mcp-call.py). Полный гайд hybrid E2E:
`docs/ai/e2e-hybrid-testing.md`.

Запуск из **корня репозитория** (JWT в `.cursor/mcp.json`):

```bash
python tools/mcp-call/mcp-call.py execute_code_safe_transaction @tools/mcp-call/examples/<файл>.json
```

## `audit-verify-args.json`

Проверка аудита `tools/call` после загрузки CFE с `mcp-tool-call-audit`:

```bash
python tools/mcp-call/mcp-call.py version_get
python tools/mcp-call/mcp-call.py eventlog_post @tools/mcp-call/examples/audit-verify-args.json
```

Ожидание: в ЖР события `MCP.tools_call` с `phase=executed`; в РС
`mcp_ЖурналВызовов` — строка с `ИмяИнструмента=version_get`.
См. `docs/ai/mcp-server.md` раздел «Аудит вызовов».

## `audit-metadata-usages-get-rs.json`

Проверка РС `mcp_ЖурналВызовов` после вызовов `metadata_usages_get` (задача 4.2):

```bash
bash tools/sandbox/run.sh python3 tools/mcp-call/mcp-call.py query_post @tools/mcp-call/examples/audit-metadata-usages-get-rs.json
```

Перед этим — `eventlog_post` с `event=MCP.tools_call` (см. `audit-verify-args.json`).

## `enable-metadata-usages-get-args.json`

Включить opt-in tool `metadata_usages_get` (запись в РС `mcp_ДоступностьИнструментов`).

> **Только через privileged-канал или GUI.** `*_safe_transaction` оборачивает
> код в откатываемую транзакцию — `УстановитьДоступностьИнструмента` из safe-tx
> **не персистит** (запись откатывается вместе с tx). Подробно:
> `research/2026-06-11-mcp-safe-transaction-rollback-side-effects.md`.

```bash
bash tools/sandbox/run.sh python tools/mcp-call/mcp-call.py execute_code_privileged @tools/mcp-call/examples/enable-metadata-usages-get-args.json
```

Альтернатива без MCP — GUI «MCP: Управление сервером» (форма константы).

Аналог: `enable-navigation-url-get-args.json`.

## Привилегированный канал (`/mcp-privileged`)

Требуются: роль `mcp_РольПривилегированного`, «Разрешить здесь» в форме константы,
включённые tools в GUI. URL — `…/hs/mcp-privileged` (см. `mcp-server.md`).

| Файл | Tool |
| --- | --- |
| `privileged-ib-user-upsert-args.json` | `ib_user_upsert` |
| `privileged-ib-user-upsert-os-only-args.json` | `ib_user_upsert` без стандартной аутентификации (перед ОС-входом) |
| `privileged-execute-code-os-auth-args.json` | `execute_code_privileged`: `АутентификацияОС` + `ПользовательОС` |
| `privileged-access-group-create-args.json` | `access_group_create` |
| `privileged-access-group-upsert-member-args.json` | `access_group_upsert_member` |
| `privileged-access-keys-refresh-args.json` | `access_keys_refresh` |
| `privileged-execute-code-args.json` | `execute_code_privileged` |

Плейбук: `ib-users-os-auth-playbook.md`.

## `locale-probe-args.json`

Probe **регионального формата даты** в dev-ИБ (сеанс MCP).

Ожидаемый ответ (пример): `RU|30.08.2025` или `US|08/30/2025`.

| Префикс | Строка для `fillFields` (дата `2025-08-30`) |
| --- | --- |
| `RU\|` | `30.08.2025` |
| `US\|` | `08/30/2025` |
| `UNKNOWN\|` | стоп, уточнить у пользователя |

Не используй `Дата(1, 1, 1)` — представление пустое или неоднозначное.

## Свой сценарий verify

1. Скопируй `locale-probe-args.json` → `my-verify-args.json`.
2. Замени поле `code`: итог в переменной **`Результат`**, транзакция откатывается
   (`execute_code_safe_transaction`).
3. Для сценария «UI записал документ → проверка на сервере» см. образец в
   `openspec/changes/example-change/scripts/`
   (не переносить в `tools/` без второго похожего кейса).

Шаблон verify (подставь метаданные и номер из UI):

```1c
Номер = "000001";
Ссылка = Документы.ЗаказПокупателя.НайтиПоНомеру(Номер, Дата(2025, 8, 30));
// … ПолучитьОбъект(), вызов метода, Результат = …
```

Дату в `НайтиПоНомеру` согласуй с probe локали и с датой в web-test.

## Печать с факсимиле (`signatureAndStamp`)

Шаблоны для `print_form_execute_post` после `./update-mcp-server.sh` и opt-in tools.
Подставь реальный `objectRef` из `query_post` / `print_forms_list_get`.

| Файл | Назначение |
| --- | --- |
| `print-execute-clean-args.json` | `signatureAndStamp: false` — регресс, чистый PDF |
| `print-execute-fax-args.json` | `signatureAndStamp: true` — факсимиле по БСП |

```bash
bash tools/mcp-call/mcp-call.sh dev_dt print_form_execute_post @tools/mcp-call/examples/print-execute-fax-args.json
```

Ожидание при `true`: `signatureAndStampApplied: true`, PDF с печатью. См.
`docs/ai/mcp-tool-print-forms-list-execute.md`.

## Чего здесь пока нет

- Skill `/hybrid-e2e`, оркестратор `tools/hybrid-e2e/` — после **второго**
  похожего change (P1, 2026-05-19; см. `e2e-hybrid-testing.md`).
- Универсальный `run-bsl-template.py` — не нужен, пока хватает `@file.json`.
