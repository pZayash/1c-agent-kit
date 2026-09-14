# Формат ADR

ADR фиксирует архитектурное решение и причину выбора.

## Где хранить

- Каталог: `docs/adr/` у **потребителя** (не в kit).
- Создавать каталог лениво: только при первом ADR.
- Индекс: `docs/adr/README.md` (таблица ID / файл / status / кратко).
  Шаблон: [templates/docs/adr/README.md](../../templates/docs/adr/README.md).

## Именование и ID

Ритм как у версии печатных форм `YYMMDD.XX` (если потребитель их ведёт), но для ADR:

- **ID (ссылка):** `ADR-YYMMDD-XX` — например `ADR-260616-01`
- **Файл:** `YYMMDD-XX-slug.md` — slug латиницей
- `YYMMDD` — дата **создания** решения (не дата каждой правки файла)
- `XX` — порядковый номер ADR за этот день, с `01` по `99`
- ID **стабилен**: правки текста номер не поднимают (иначе битые ссылки).
  Новое решение = новый ID (или `superseded by ADR-…`)

Следующий ID: строка в `docs/adr/README.md`. Если у потребителя есть
`tools/adr/next_id.py` — им.

В коде и OpenSpec ссылаться так: `ADR-260616-01` (не «ADR Имя YYMMDD»,
не `ADR-000N`).

## Минимальный шаблон

```md
# {Short title of the decision}

**ID:** ADR-YYMMDD-XX
**Status:** proposed | accepted | deprecated | superseded by ADR-YYMMDD-XX

{1-3 sentences: what's the context, what did we decide, and why.}
```

Этого достаточно: ADR может быть одним абзацем.

## Опциональные секции

Добавлять только если есть реальная ценность:

- `Considered options`
- `Consequences`

## Когда предлагать ADR

Только если одновременно выполнены все условия:

1. Решение дорого откатывать.
2. Без контекста решение будет неочевидным.
3. Был реальный trade-off и выбор из альтернатив.

Если хотя бы одно условие не выполнено, ADR не нужен.

## Статус и OpenSpec

- Пока change в работе — часто `proposed`.
- При archive change, который опирался на ADR, — поднять до `accepted`
  (или `superseded by …`), если решение принято.

## Проверка

Если у потребителя есть `tools/adr/check.py` — warning-only, не блок коммита
по умолчанию.

## Копирайт

Адаптировано из
[mattpocock/skills — ADR-FORMAT.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/grill-with-docs/ADR-FORMAT.md)
(MIT). Навык: [/explore](../../cursor/skills/explore/SKILL.md).
Раскладка папок: [docs-layout.md](docs-layout.md).
