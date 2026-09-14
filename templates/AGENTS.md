# Агенты

Общие правила и tools — submodule [harness/](harness/README.md).
Документация: [docs-layout.md](harness/docs/ai/docs-layout.md).

Специфика этого проекта (префикс, ИБ, платформа) — ниже.

## Поиск (qmd)

Канон kit: [qmd-search.md](harness/docs/ai/qmd-search.md).
Ключи `.env`: `QMD_CLIENT` (`off`/`cli`/`mcp`), `QMD_MCP_URL`.
Шаблон: [env-qmd.example](harness/templates/env-qmd.example).

## Проект

- `PROJECT_PREFIX`: (заполнить)
- Layout: vanessa (`src/cf`) или legacy (`conf/` + symlink)
- Платформа: (ключ `.env`, не дублировать 8.x.x.x в доке)

## Запрещено

Коммитить файлы kit как обычные файлы проекта. Promote — skill
`harness-promote`.
