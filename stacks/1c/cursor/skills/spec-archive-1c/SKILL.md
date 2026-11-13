---
name: spec-archive-1c
description: >-
  1C-дополнение к spec-archive: ветка code-as-spec render — seed библиотеки
  из дельты + spec-lint render вместо prose-merge, бюджет процесса и
  fallback. Вызывается из spec-archive, напрямую не вызывать.
---

# spec-archive-1c — 1C-дополнение к spec-archive

Читается из `spec-archive` до шага 1, когда у
потребителя выбран стек `1c`. Конкретизирует шаг sync для render-
маркированных capability; остальные шаги и гейты — по core-версии.
Binding-канон: [code-as-spec-1c](../../../docs/ai/code-as-spec-1c.md).

## Ветка `code-as-spec: render` (вместо prose-merge)

Если дельта `specs/changes/<name>/specs/<cap>/spec.md` несёт маркер
`<!-- code-as-spec: render -->` — prose source of truth это анкеры кода,
финальный `specs/<cap>/spec.md` получается `spec-lint render`, не merge.

Сначала **seed** библиотеки из дельты (чтобы render сохранил `Purpose` и
маркер при первом archive, когда `specs/<cap>/spec.md` ещё нет), затем render:

```bash
mkdir -p specs/<cap>
cp specs/changes/<name>/specs/<cap>/spec.md specs/<cap>/spec.md
bash tools/sandbox/run.sh python tools/spec-lint/spec_lint.py render <cap>
```

`render` пересобирает индекс Requirements из анкеров кода и **отказывает
(rc≠0, без записи) при 0 REQUIREMENT-анкеров** — маркер на prose-only
capability ошибочен: снять маркер и синкать прозой как обычно (spec-sync).

**Бюджет `render`:** один вызов за раз; early stdout ожидаем сразу
(`discovery…`). Нет stdout ~90 с → диагностика, **не** второй параллельный
render. Тишина ~3–5 мин → стоп, fallback: ручной stub из анкеров + пометка
в summary. Нужен `rg` в sandbox (rebuild образа). Hybrid capability
(prose + anchors) — **не** ставить маркер render без переноса prose в
анкеры; см. [tools/spec-lint/README.md](../../../tools/spec-lint/README.md).

Остальные (не маркированные) capability синкаются прозой как обычно —
шаг 3 core-скилла.
