---
name: handoff-1c
description: >-
  1C-дополнение к handoff: стековые проверки (BSL/XML), MCP-источники фактов
  из ИБ, 1С-навыки для подгрузки. Вызывается из handoff,
  напрямую не вызывать.
---

# handoff-1c — 1C-дополнение к handoff

Читается из `handoff` до начала работы, когда у
потребителя выбран стек `1c`. Дополняет core-пайплайн 1С-конкретикой;
порядок остальной — по core-версии.

## Проверки (блок «Проверки» handoff-документа)

- **BSL**: `check-bsl.py` / [bsl-check](../bsl-check/SKILL.md) — пройдено /
  ошибки / не запускалось.
- **XML** (Form, Template, СКД, Rights, Configuration):
  [xml-wellformed](../xml-wellformed/SKILL.md) — пройдено / не применимо.

## Что подгрузить в следующей сессии (1С-часть)

- **Навыки**: релевантные 1С-скиллы из `.cursor/skills/` (например
  `form-edit`, `bsl-check`, `code-analysis-orchestrator`,
  `load-changed-files`).
- **MCP** (если нужны факты из ИБ, не из `conf/`):
  [docs/ai/mcp-config.md](../../../docs/ai/mcp-config.md) — конфиг
  `.mcp.json`, CLI `tools/mcp-call/` (`dev_dt` / `prod_dt`, `metadata_get`,
  `query_post`, …).
- **Поиск по коду**: [1c-configdump-fast-search](../1c-configdump-fast-search/SKILL.md);
  массовое чтение — `rlm-tools-bsl`
  ([docs/ai/rlm-tools-bsl.md](../../../docs/ai/rlm-tools-bsl.md)).

## Границы (1С-часть)

- Не писать в handoff строки подключения к ИБ — это секреты.
- Handoff не конфигурация и не код; **не** гонять по нему `check-bsl.py` /
  xml-wellformed.
