# Формат CONTEXT

`CONTEXT.md` (корень потребителя) фиксирует словарь предметной области и связи
терминов. Канон тегов записей `memory/` — отдельно в `TAGS.md`
(не смешивать с `## Language`).

## Когда создавать

- Создавать лениво: только когда появился первый согласованный термин.
- Для single-context проекта: один `CONTEXT.md` в корне.
- Для multi-context проекта: если есть `CONTEXT-MAP.md`, хранить
  `CONTEXT.md` в соответствующем контексте.

## Шаблон

```md
# {Context Name}

{One or two sentence description of what this context is and why it exists.}

## Language

**Order**:
{A concise description of the term}
_Avoid_: Purchase, transaction

**Invoice**:
A request for payment sent to a customer after delivery.
_Avoid_: Bill, payment request

**Customer**:
A person or organization that places orders.
_Avoid_: Client, buyer, account

## Relationships

- An **Order** produces one or more **Invoices**
- An **Invoice** belongs to exactly one **Customer**

## Example dialogue

> **Dev:** "When a **Customer** places an **Order**,
> do we create the **Invoice** immediately?"
> **Domain expert:** "No - an **Invoice** is only generated
> once a **Fulfillment** is confirmed."

## Flagged ambiguities

- "account" was used to mean both **Customer** and **User** -
  resolved: these are distinct concepts.
```

## Правила

- Выбирать один каноничный термин на понятие.
- Явно фиксировать конфликты терминов в `Flagged ambiguities`.
- Держать определения короткими: одно предложение, "что это", не "что делает".
- Показывать связи между терминами и кардинальность, если она очевидна.
- Включать только доменные понятия, а не общие технические термины.
- Добавлять `Example dialogue`, чтобы проверить естественное употребление.

## Multi-context карта

Если контекстов несколько, добавить `CONTEXT-MAP.md` с перечислением
контекстов и связей между ними.

## Копирайт

Адаптировано из
[mattpocock/skills — CONTEXT-FORMAT.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/grill-with-docs/CONTEXT-FORMAT.md)
(MIT). Навык: [/explore](../../cursor/skills/explore/SKILL.md).
Раскладка: [docs-layout.md](docs-layout.md).
