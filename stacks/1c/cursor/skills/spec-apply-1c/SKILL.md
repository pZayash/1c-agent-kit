---
name: spec-apply-1c
description: >-
  1C-дополнение к spec-apply: code-as-spec миграция в BSL (носитель
  Функция/Процедура, анкер //, PROJECT_PREFIX), spec-lint check, владелец
  кода по is_ours(). Вызывается из spec-apply, напрямую не вызывать.
---

# spec-apply-1c — 1C-дополнение к spec-apply

Читается из `spec-apply` до шага 1, когда у
потребителя выбран стек `1c`. Конкретизирует code-as-spec и владельца кода;
пайплайн и гейты — по core-версии. Binding-канон:
[code-as-spec-1c](../../../docs/ai/code-as-spec-1c.md).

## Code-as-spec миграция при apply (prose → код)

Если change затрагивает код продукта в корне исходников (по префиксу
потребителя, напр. `PROJECT_PREFIX` из `.env`):

1. Прочитать связанные `specs/<cap>/spec.md` (по capability/модулю).
   Если `<!-- code-as-spec: render -->` уже есть — требования живут в коде,
   миграция не нужна.

2. Для каждого prose Requirement найти метод-носитель:
   - Requirement с SHALL → функция по ключевым словам в tasks/design (propose
     обычно указывает имя метода).
   - 1 модуль → 1 capability: все Requirement ложатся в этот модуль (типичный
     случай).
   - Не сопоставляется → fallback: tasks.md явно указывает REQ-ID → метод.

3. Вставить REQUIREMENT-блок над сигнатурой метода (после док-коммента, перед
   `Функция/Процедура`):
   ```bsl
   // СПЕЦИФИКАЦИЯ
   // REQUIREMENT: REQ-NNN — <краткое имя>
   //
   // <полный prose из spec.md>
   //
   // VERIFIED-BY: <имя теста или (no-test)>
   ```

4. Добавить `<!-- code-as-spec: render -->` маркер в
   `specs/<cap>/spec.md` (после заголовка, перед Purpose).
   Если spec.md не существует — создать stub с маркером и Purpose.

5. Prose из spec.md НЕ удалять при первой миграции — render на archive
   пересоберёт.

`spec-lint check` не зелёный после миграции → предупредить, не блокировать apply.

## Владелец кода (OWNER) — 1С

Маркер `OWNER:` (приоритет: метод > регион > модуль) или дефолт по
префиксу (`is_ours()` spec-lint): наш код → `agent`, чужой/вендорский →
`vendor`; `human` — только явным маркером. `vendor` — read-only: доработка
через `PROJECT_PREFIX`-инъекции/CFE. Канон режимов — code-as-spec.md §5.
