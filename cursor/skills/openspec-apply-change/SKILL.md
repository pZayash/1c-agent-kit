---
name: openspec-apply-change
description: Implement tasks from an OpenSpec change. Use when the user wants to start implementing, continue implementation, or work through tasks.
license: MIT
compatibility: Requires openspec CLI.
metadata:
  author: openspec
  version: "1.0"
  generatedBy: "1.2.0"
---

Implement tasks from an OpenSpec change.

**Input**: Optionally specify a change name. If omitted, check if it can be inferred from conversation context. If vague or ambiguous you MUST prompt for available changes.

**Steps**

1. **Select the change**

   If a name is provided, use it. Otherwise:
   - Infer from conversation context if the user mentioned a change
   - Auto-select if only one active change exists
   - If ambiguous, run `openspec list --json` to get available changes and use the **AskUserQuestion tool** to let the user select

   Always announce: "Using change: <name>" and how to override (e.g., another change name in the request or skill `openspec-apply-change <name>`).

2. **Check status to understand the schema**
   ```bash
   openspec status --change "<name>" --json
   ```
   Parse the JSON to understand:
   - `schemaName`: The workflow being used (e.g., "spec-driven")
   - Which artifact contains the tasks (typically "tasks" for spec-driven, check status for others)

3. **Get apply instructions**

   ```bash
   openspec instructions apply --change "<name>" --json
   ```

   This returns:
   - Context file paths (varies by schema - could be proposal/specs/design/tasks or spec/tests/implementation/docs)
   - Progress (total, complete, remaining)
   - Task list with status
   - Dynamic instruction based on current state

   **Handle states:**
   - If `state: "blocked"` (missing artifacts): show message; suggest completing missing artifacts via `openspec-propose` or manual artifact edits, then retry
   - If `state: "all_done"`: congratulate, suggest skill `openspec-archive-change`
   - Otherwise: proceed to implementation

4. **Read context files**

   Read the files listed in `contextFiles` from the apply instructions output.
   The files depend on the schema being used:
   - **spec-driven**: proposal, specs, design, tasks
   - Other schemas: follow the contextFiles from CLI output

5. **Show current progress**

   Display:
   - Schema being used
   - Progress: "N/M tasks complete"
   - Remaining tasks overview
   - Dynamic instruction from CLI

6. **Implement tasks (loop until done or blocked)**

   For each pending task:
   - Show which task is being worked on
   - Make the code changes required
   - Keep changes minimal and focused
   - Mark task complete in the tasks file: `- [ ]` → `- [x]`
   - Continue to next task

   **Implementation notes (optional, Markdown only)**

   Path: `openspec/changes/<name>/implementation-notes.md`. Idea © Thariq (@trq212):
   [post](https://x.com/trq212/status/2056415973125796184). Details:
   [docs/ai/openspec-implementation-notes.md](../../../docs/ai/openspec-implementation-notes.md).

   Create or append **only when needed** — not on every apply. Triggers: decision outside
   spec/design; deviation from `tasks.md`; tradeoff; reviewer must-know; user asked.

   - First need: create file from template in the doc above (include © line in header).
   - Each trigger: short bullet under the matching section.
   - If nothing to record: do not create the file.
   - Do not use HTML. Do not duplicate `design.md` without new facts.

   **Дрифт требований на лету**

   Если пользователь по ходу apply меняет/добавляет требование устно — нельзя
   оставлять его только в чате (теряется при компакте). Порядок:

   1. **Захватить сразу** (любой моделью): дословная цитата + дата + «источник:
      указание пользователя» в `implementation-notes.md`.
   2. **Гейт по размеру**:
      - *Малый/локальный* (порог, константа, один Scenario, имя, фильтр): агент
        сам дописывает delta в `specs/**/spec.md` (MODIFIED Requirement), зеркаля
        структуру. Перед записью — readback: «записываю в спеку как: …» →
        подтверждение пользователя. Delta включает изменённый Scenario явно.
      - *Структурный/сквозной* (новое поведение, влияет на `design.md`, задевает
        >1 Requirement или другие changes): СТОП, не импровизировать спеку —
        предложить `openspec-propose` / запрос архитектору.
   3. **Никогда** не оставлять изменение требования только в коде (молчаливый
      drift). Код без обновлённой спеки — расхождение для ревью.

   При сомнении «малый/структурный» — один вопрос пользователю.

   **Code-as-spec миграция при apply (prose → код)**

   Если change затрагивает `яя_`-код в `conf/` (по `PROJECT_PREFIX`):

   1. Прочитать связанные `openspec/specs/<cap>/spec.md` (по capability/модулю).
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
      ```
      // СПЕЦИФИКАЦИЯ
      // REQUIREMENT: REQ-NNN — <краткое имя>
      //
      // <полный prose из spec.md>
      //
      // VERIFIED-BY: <имя теста или (no-test)>
      ```

   4. Добавить `<!-- code-as-spec: render -->` маркер в
      `openspec/specs/<cap>/spec.md` (после заголовка, перед Purpose).
      Если spec.md не существует — создать stub с маркером и Purpose.

   5. Prose из spec.md НЕ удалять при первой миграции — render на archive
      пересоберёт.

   `spec-lint check` не зелёный после миграции → предупредить, не блокировать apply.

   **Code-as-spec guard:** если change затрагивает `яя_`-код в `conf/` (добавляет/меняет
   значимые методы по `PROJECT_PREFIX`), проверить что tasks включает шаги с
   REQUIREMENT/MODULE_CONTRACT/VERIFIED-BY (см. `rules.tasks` в `openspec/config.yaml`).
   Если нет — предупредить пользователя (не блокировать, но явно сказать).

   **Pause if:**

7. **On completion or pause, show status**

   Display:
   - Tasks completed this session
   - Overall progress: "N/M tasks complete"
   - If `implementation-notes.md` exists: path and one-line hint (review before archive; file is not archived)
   - If `operator-checklist.md` exists: вывести его содержимое в чат и явно спросить оператора по незакрытым пунктам (файл не входит в прогресс tasks.md, но блокирует archive — см. `openspec-archive-change` шаг 3)
   - If all done: suggest archive (но только если operator-checklist тоже закрыт)
   - If paused: explain why and wait for guidance

**Output During Implementation**

```
## Implementing: <change-name> (schema: <schema-name>)

Working on task 3/7: <task description>
[...implementation happening...]
✓ Task complete

Working on task 4/7: <task description>
[...implementation happening...]
✓ Task complete
```

**Output On Completion**

```
## Implementation Complete

**Change:** <change-name>
**Schema:** <schema-name>
**Progress:** 7/7 tasks complete ✓

### Completed This Session
- [x] Task 1
- [x] Task 2
...

All tasks complete! Invoke skill `openspec-archive-change` to archive this change.
If `operator-checklist.md` exists with unchecked items — operator must complete
manual verification first (smoke tests, 1C checks). Archive is blocked until then.
```

**Output On Pause (Issue Encountered)**

```
## Implementation Paused

**Change:** <change-name>
**Schema:** <schema-name>
**Progress:** 4/7 tasks complete

### Issue Encountered
<description of the issue>

**Options:**
1. <option 1>
2. <option 2>
3. Other approach

What would you like to do?
```

**Guardrails**
- Keep going through tasks until done or blocked
- Always read context files before starting (from the apply instructions output)
- If task is ambiguous, pause and ask before implementing
- If implementation reveals issues, pause and suggest artifact updates
- Keep code changes minimal and scoped to each task
- Update task checkbox immediately after completing each task
- Pause on errors, blockers, or unclear requirements - don't guess
- Use contextFiles from CLI output, don't assume specific file names
- `implementation-notes.md` is optional; never create empty file «for checklist»

**Fluid Workflow Integration**

This skill supports the "actions on a change" model:

- **Can be invoked anytime**: Before all artifacts are done (if tasks exist), after partial implementation, interleaved with other actions
- **Allows artifact updates**: If implementation reveals design issues, suggest updating artifacts - not phase-locked, work fluidly
