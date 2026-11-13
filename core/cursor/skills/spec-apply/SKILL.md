---
name: spec-apply
description: Implement tasks from a spec change. Use when the user wants to start implementing, continue implementation, or work through tasks of a change in specs/changes/.
---

Implement tasks from a spec change (`specs/changes/<name>/`).

**Компаньоны**: если для стека `<s>` из `.kit.json stacks[]` существует
`.cursor/skills/spec-apply-<s>/SKILL.md` — прочти все такие компаньоны
до шага 1, в порядке `stacks:[]`.

Инструмент: `python harness/tools/kit-spec/kit_spec.py` (далее `kit_spec`).
Канон: `harness/core/docs/ai/spec-workflow.md`.

**Input**: Optionally specify a change name. If omitted, check if it can be inferred
from conversation context. If vague or ambiguous you MUST prompt for available changes.

**Steps**

1. **Select the change**

   If a name is provided, use it. Otherwise:
   - Infer from conversation context if the user mentioned a change
   - Auto-select if only one active change exists
   - If ambiguous, run `python harness/tools/kit-spec/kit_spec.py list --json`
     and use the **AskUserQuestion tool** to let the user select

   Always announce: "Using change: <name>" and how to override (e.g., another change
   name in the request or skill `spec-apply <name>`).

2. **Check status**
   ```bash
   python harness/tools/kit-spec/kit_spec.py status "<name>" --json
   ```
   - Missing artifacts (proposal/design/tasks = false) → предложи завершить
     через `spec-propose` или ручные правки, затем retry
   - `tasks.total == 0` → дефект артефакта (validate FAIL «без чекбоксов»):
     не импровизировать задачи — предложи дописать tasks.md через
     `spec-propose`/вручную, затем retry
   - `tasks.total > 0` и `done == total` → congratulate, suggest `spec-archive`
   - Otherwise: proceed

3. **Read context files**

   Read `proposal.md`, `design.md`, `tasks.md` and relevant `specs/<cap>/spec.md`
   deltas of the change. If `operator-checklist.md` / `implementation-notes.md`
   exist — read them too.

4. **Show current progress**

   Display:
   - Progress: "N/M tasks complete"
   - Remaining tasks overview

5. **Implement tasks (loop until done or blocked)**

   For each pending task:
   - Show which task is being worked on
   - Make the code changes required
   - Keep changes minimal and focused
   - Mark task complete in the tasks file: `- [ ]` → `- [x]`
   - Continue to next task

   **Implementation notes (optional, Markdown only)**

   Path: `specs/changes/<name>/implementation-notes.md`. Idea © Thariq (@trq212):
   [post](https://x.com/trq212/status/2056415973125796184).

   Create or append **only when needed** — not on every apply. Triggers: decision outside
   spec/design; deviation from `tasks.md`; tradeoff; reviewer must-know; user asked.

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
        сам дописывает delta в `specs/changes/<name>/specs/<cap>/spec.md`
        (MODIFIED Requirement),
        зеркаля структуру. Перед записью — readback: «записываю в спеку как: …»
        → подтверждение пользователя. Delta включает изменённый Scenario явно.
      - *Структурный/сквозной* (новое поведение, влияет на `design.md`, задевает
        >1 Requirement или другие changes): СТОП, не импровизировать спеку —
        предложить `spec-propose` / запрос архитектору.
   3. **Никогда** не оставлять изменение требования только в коде (молчаливый
      drift). Код без обновлённой спеки — расхождение для ревью.

   При сомнении «малый/структурный» — один вопрос пользователю.

   **code-as-spec при apply (prose → код)**

   Если change затрагивает код продукта — миграция требований в анкеры:
   рамка [code-as-spec.md](../../../docs/ai/code-as-spec.md) §3, конкретика
   носителя/инструментов — binding `stacks/<s>/docs/ai/code-as-spec-<s>.md`
   и компаньон `spec-apply-<s>`.

   Guard: если change затрагивает код продукта, проверить что tasks включает
   шаги с REQUIREMENT/MODULE_CONTRACT/VERIFIED-BY (см. `kit_spec.py
   instructions tasks`). Если нет — предупредить пользователя (не блокировать).

   **Владелец кода (OWNER) — режим правки**

   Перед правкой метода/модуля определить владельца: `agent` — black box,
   `human` — копилот (минимальный diff), `vendor` — read-only. Канон:
   [code-as-spec.md](../../../docs/ai/code-as-spec.md) §5; дефолт и точки
   расширения — в binding стека. Спор о владельце — пауза и вопрос оператору.

   **Pause if:**
   - Задача неоднозначна — уточни у оператора до имплементации
   - Реализация расходится с design/proposal — стоп, предложи правку
     артефактов (drift-правило выше)
   - Ошибка, блокер, недоступная зависимость — не гадай, покажи issue
   - Спор о владельце кода (OWNER) — вопрос оператору
   - Изменение требования больше «малого» порога — стоп, `spec-propose`

6. **On completion or pause, show status**
   ```bash
   python harness/tools/kit-spec/kit_spec.py status "<name>"
   ```

   Display:
   - Tasks completed this session
   - Overall progress: "N/M tasks complete"
   - If `implementation-notes.md` exists: path and one-line hint (review before archive; file is not archived)
   - If `operator-checklist.md` exists: вывести его содержимое в чат и явно спросить
     оператора по незакрытым пунктам (файл не входит в прогресс tasks.md, но блокирует
     archive — см. `spec-archive`)
   - If all done: suggest archive (но только если operator-checklist тоже закрыт)
   - If paused: explain why and wait for guidance

**Output During Implementation**

```
## Implementing: <change-name>

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
**Progress:** 7/7 tasks complete ✓

### Completed This Session
- [x] Task 1
- [x] Task 2
...

All tasks complete! Invoke skill `spec-archive` to archive this change.
If `operator-checklist.md` exists with unchecked items — operator must complete
manual verification first (smoke tests, stack checks). Archive is blocked until then.
```

**Output On Pause (Issue Encountered)**

```
## Implementation Paused

**Change:** <change-name>
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
- Always read context files before starting
- If task is ambiguous, pause and ask before implementing
- If implementation reveals issues, pause and suggest artifact updates
- Keep code changes minimal and scoped to each task
- Update task checkbox immediately after completing each task
- Pause on errors, blockers, or unclear requirements - don't guess
- `implementation-notes.md` is optional; never create empty file «for checklist»

**Fluid Workflow Integration**

This skill supports the "actions on a change" model:

- **Can be invoked anytime**: Before all artifacts are done (if tasks exist), after
  partial implementation, interleaved with other actions
- **Allows artifact updates**: If implementation reveals design issues, suggest
  updating artifacts - not phase-locked, work fluidly
