# Агенты

Общие правила и tools — submodule [harness/](harness/README.md).

Специфика этого проекта (префикс, ИБ, платформа) — ниже.

## Проект

- `PROJECT_PREFIX`: (заполнить)
- Layout: vanessa (`src/cf`) или legacy (`conf/` + symlink)
- Платформа: (ключ `.env`, не дублировать 8.x.x.x в доке)

## Запрещено

Коммитить файлы kit как обычные файлы проекта. Promote — skill
`harness-promote`.
