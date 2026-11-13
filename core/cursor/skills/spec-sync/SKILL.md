---
name: spec-sync
description: Merge delta specs from a change into the specs/ library. Use when archiving a change with deltas, or when the user asks to sync capability specs.
---

Merge delta-спек `specs/changes/<name>/specs/<cap>/spec.md` в библиотеку
`specs/<cap>/spec.md`. Проза, не автоматика — scope слияния контролирует
агент. Обычно вызывается из `spec-archive` (шаг sync), можно и напрямую.

Инструмент: `python harness/tools/kit-spec/kit_spec.py` (далее `kit_spec`).
Формат дельт: `harness/core/docs/ai/spec-workflow.md`.

**Input**: имя change (обязательно) + опционально capability. Неоднозначность
→ `kit_spec.py status <name> --json` (список `deltas`) + AskUserQuestion.

**Steps**

1. **Собрать дельты**
   ```bash
   python harness/tools/kit-spec/kit_spec.py status "<name>" --json
   ```
   Поле `deltas` — capability с дельтами. Пусто → «нет дельт», стоп.

2. **По каждой capability**

   **render-маркер**: если дельта содержит `<!-- code-as-spec: render -->` —
   **пропустить**: эта capability рендерится из анкеров кода (см. компаньон
   `spec-archive-<s>` / `stacks/<s>/docs/ai/code-as-spec-<s>.md`), не merge
   прозой. Нет компаньона → предупредить и пропустить.

   **prose merge**: сравнить дельту с `specs/<cap>/spec.md`:

   - `## ADDED Requirements` → добавить требования целиком
     (`#### Requirement:` + SHALL + `##### Scenario:`) в конец спеки.
   - `## MODIFIED Requirements` → найти требование по имени в библиотеке,
     заменить тело (и сценарии) на дельтовое. Нет в библиотеке → WARN +
     добавить как новое (пометить пользователю).
   - `## REMOVED Requirements` → удалить требование по имени. Нет → WARN.
   - `## RENAMED Requirements` → переименовать `#### Requirement: <old>` в
     `<new>` (дельта несёт `old → new`), тело при MODIFIED-части.
   - Если `specs/<cap>/spec.md` не существует — создать: заголовок
     `# <cap> Specification`, секция `## Purpose` (кратко из proposal),
     затем секции Requirements из дельты.

3. **Показать сводку до записи**

   ```
   ## Spec sync: <name>
   <cap>: +2 ADDED, ~1 MODIFIED, -1 REMOVED  → specs/<cap>/spec.md
   <cap2>: render-маркер — пропуск (spec-lint render на archive)
   ```
   Подтверждение пользователя → запись. Правки — правкой файла библиотеки
   (не дельты).

4. **После merge**
   ```bash
   python harness/tools/kit-spec/kit_spec.py validate "<name>"
   ```
   Дельты остаются в папке change (уходят в архив вместе с ним) — в
   библиотеке теперь слитое состояние.

**Guardrails**
- Сводку показывать **до** записи в библиотеку — merge это контракт, не
  черновик.
- Render-маркированные capability никогда не мерджить прозой.
- Конфликт (требование изменилось и в библиотеке, и в дельте по-разному) —
  показать оба, спросить; не угадывать.
- Не трогать `specs/changes/archive/**`.
