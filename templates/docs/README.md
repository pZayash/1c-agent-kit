# Документация проекта

Правила папок, оглавлений и куда писать:
[harness/core/docs/ai/docs-layout.md](../harness/core/docs/ai/docs-layout.md).

Проект использует progressive disclosure: `AGENTS.md` — минимум,
детали — по ссылкам.

## docs/ai — агенты

Общее — в kit (`harness/core/docs/ai/` + `harness/stacks/*/docs/ai/`). Здесь — addenda потребителя и заглушки
на старые пути. Срез kit: [harness/core/docs/ai/README.md](../harness/core/docs/ai/README.md).

Дополнить список своих файлов (печать, MCP, …):

- (пример) `[print-forms.md](ai/print-forms.md)` — если ведёте ПФ в этом репо

## docs/human — люди

- **[development-setup.md](human/development-setup.md)** — среда (создать при bootstrap)

## docs/adr

Лениво. Формат: [ADR-FORMAT.md](../harness/core/docs/ai/ADR-FORMAT.md).
Индекс: [adr/README.md](adr/README.md).

## docs/analytics

Лениво. Формат: [ANALYTICS-FORMAT.md](../harness/core/docs/ai/ANALYTICS-FORMAT.md).

## Корень

- **[AGENTS.md](../AGENTS.md)** — правила агентов
- **[README.md](../README.md)** — вход для людей
- `CONTEXT.md` / `ROLES.md` / `memory/` — см. docs-layout
