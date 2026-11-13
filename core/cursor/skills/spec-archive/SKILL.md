---
name: spec-archive
description: Archive a completed spec change. Use when the user wants to finalize and archive a change after implementation is complete.
---

Archive a completed change: sync дельт → гейты → move в
`specs/changes/archive/YYYY-MM-DD-<name>/`.

**Компаньоны**: если для стека `<s>` из `.kit.json stacks[]` существует
`.cursor/skills/spec-archive-<s>/SKILL.md` — прочти все такие компаньоны
до шага 1, в порядке `stacks:[]`.

Инструмент: `python harness/tools/kit-spec/kit_spec.py` (далее `kit_spec`).
Канон: `harness/core/docs/ai/spec-workflow.md` (гейты archive).

**Input**: Optionally specify a change name. If omitted, check if it can be inferred
from conversation context. If vague or ambiguous you MUST prompt for available changes.

**Steps**

1. **If no change name provided, prompt for selection**

   Run `python harness/tools/kit-spec/kit_spec.py list --json` to get available
   changes. Use the **AskUserQuestion tool** to let the user select.
   Show only active changes (not already archived).

   **IMPORTANT**: Do NOT guess or auto-select a change. Always let the user choose.

2. **Check status**
   ```bash
   python harness/tools/kit-spec/kit_spec.py status "<name>" --json
   ```

   **If artifacts are missing (proposal/design/tasks = false):**
   - Display warning listing missing artifacts
   - Use **AskUserQuestion tool** to confirm user wants to proceed

   **If incomplete tasks in `tasks.md` (`done < total`):**
   - Display warning showing count of incomplete tasks
   - Use **AskUserQuestion tool** to confirm user wants to proceed
     (`kit_spec.py archive` откажет без `--force`)

   **If `operator-checklist.md` exists with unchecked items:**
   - `operator-checklist.md` НЕ входит в прогресс — это ручные проверки
     оператора (smoke, стековые проверки), но блокирует archive.
   - Display the file contents in chat
   - Use **AskUserQuestion tool**: «Есть незакрытые ручные проверки (N пунктов).
     Архивировать как есть / отложить архивацию до проверки?»
   - «Как есть» → archive с `--force`

3. **Sync delta specs (default)**

   Check for delta specs at `specs/changes/<name>/specs/`. If none exist,
   proceed to step 4.

   **code-as-spec capability:** если дельта несёт маркер
   `<!-- code-as-spec: render -->` — источник истины анкеры кода, финальный
   `specs/<cap>/spec.md` производится render'ом binding-инструментом стека,
   а не merge прозы. Конкретика — в компаньоне `spec-archive-<s>` и
   `stacks/<s>/docs/ai/code-as-spec-<s>.md`. Общие capability синкаются
   прозой (ниже).

   **If delta specs exist (non render-marked):**
   - Compare each delta with `specs/<cap>/spec.md` в библиотеке
   - Determine what changes would be applied (adds, modifications, removals, renames)
   - Show a combined summary of planned sync

   **Default (project rule):** sync delta specs into `specs/<cap>/spec.md`,
   then archive. Do **not** ask «sync or skip» unless the user explicitly said
   «без sync» / «archive without syncing» in the **current** dialog.

   Сам merge — проза скилла `spec-sync` (агент контролирует scope; вызови
   его как skill или выполни по его инструкции в subagent).

4. **Implementation notes (if present — before archive)**

   Path: `specs/changes/<name>/implementation-notes.md` (Markdown only).
   `kit_spec.py archive` **откажет** пока файл существует — он не архивируется.

   **If the file does not exist:** proceed to step 5.

   **If the file exists:**

   - Tell the user the file must be reviewed and removed before archive.
   - Ask them to open and read it (show path; optional: short summary of sections).
   - Use **AskUserQuestion tool** — suggest options such as:
     1. Reviewed — delete the file now (ready to archive)
     2. Extract valuable points into `memory/` or spec artifacts, then delete the file
     3. Postpone archive until later
   - **Do not run step 5** until `implementation-notes.md` is deleted.
   - After deletion, continue to step 5.

5. **Perform the archive**
   ```bash
   python harness/tools/kit-spec/kit_spec.py archive "<name>"
   ```
   Гейты инструмента: незакрытые tasks/operator-checklist/validate-FAIL →
   отказ (обход — `--force` только после подтверждений шага 2);
   `implementation-notes.md` → жёсткий отказ; цель архива существует → отказ
   (suggest renaming existing archive or using different date).

6. **Display summary**

   Show archive completion summary including:
   - Change name
   - Archive location
   - Spec sync status (synced / sync skipped / no delta specs)
   - Note about any warnings (incomplete tasks, force overrides)
   - If implementation notes were removed this session: note that they were not archived

**Output On Success**

```
## Archive Complete

**Change:** <change-name>
**Archived to:** specs/changes/archive/YYYY-MM-DD-<name>/
**Specs:** ✓ Synced to library

All tasks complete.
```

**Output On Success With Warnings**

```
## Archive Complete (with warnings)

**Change:** <change-name>
**Archived to:** specs/changes/archive/YYYY-MM-DD-<name>/
**Specs:** Sync skipped (user chose to skip)

**Warnings:**
- Archived with 3 incomplete tasks
- Delta spec sync was skipped (user chose to skip)

Review the archive if this was not intentional.
```

**Guardrails**
- Always prompt for change selection if not provided
- Don't block archive on warnings - just inform and confirm
- Show clear summary of what happened
- If sync is requested, use skill `spec-sync` (agent-driven)
- If delta specs exist, always run the sync assessment and show the combined summary before syncing
- Never archive `implementation-notes.md` — delete after user review
