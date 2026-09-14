---
name: openspec-archive-change
description: Archive a completed change in the experimental workflow. Use when the user wants to finalize and archive a change after implementation is complete.
license: MIT
compatibility: Requires openspec CLI.
metadata:
  author: openspec
  version: "1.0"
  generatedBy: "1.2.0"
  projectRules:
    - docs/ai/openspec-implementation-notes.md
---

Archive a completed change in the experimental workflow.

**Input**: Optionally specify a change name. If omitted, check if it can be inferred from conversation context. If vague or ambiguous you MUST prompt for available changes.

**Steps**

1. **If no change name provided, prompt for selection**

   Run `openspec list --json` to get available changes. Use the **AskUserQuestion tool** to let the user select.

   Show only active changes (not already archived).
   Include the schema used for each change if available.

   **IMPORTANT**: Do NOT guess or auto-select a change. Always let the user choose.

2. **Check artifact completion status**

   Run `openspec status --change "<name>" --json` to check artifact completion.

   Parse the JSON to understand:
   - `schemaName`: The workflow being used
   - `artifacts`: List of artifacts with their status (`done` or other)

   **If any artifacts are not `done`:**
   - Display warning listing incomplete artifacts
   - Use **AskUserQuestion tool** to confirm user wants to proceed
   - Proceed if user confirms

3. **Check task completion status**

   Read the tasks file (typically `tasks.md`) to check for incomplete tasks.

   Count tasks marked with `- [ ]` (incomplete) vs `- [x]` (complete).

   **`operator-checklist.md` НЕ входит в подсчёт.** Это отдельный файл ручных
   задач оператора (smoke, проверки в 1С), не парсится openspec CLI. Но если файл
   существует и содержит незакрытые `- [ ]` — **блокер**: вывести содержимое в
   чат и спросить оператора. Архивация возможна только после подтверждения
   оператора (или явного «архивировать как есть»).

   **If incomplete tasks found (in tasks.md):**
   - Display warning showing count of incomplete tasks
   - Use **AskUserQuestion tool** to confirm user wants to proceed
   - Proceed if user confirms

   **If `operator-checklist.md` exists with unchecked items:**
   - Display the file contents in chat
   - Use **AskUserQuestion tool**: «Есть незакрытые ручные проверки (N пунктов).
     Архивировать как есть / отложить архивацию до проверки?»
   - Proceed only if user confirms «как есть»

   **If no tasks file exists:** Proceed without task-related warning.

4. **Sync delta specs (default)**

   Check for delta specs at `openspec/changes/<name>/specs/`. If none exist, proceed to step 5.

   **code-as-spec capability (D3):** if a delta `spec.md` carries the marker
   `<!-- code-as-spec: render -->`, the prose source of truth is the code anchors,
   not the delta. For such a capability the final `openspec/specs/<cap>/spec.md`
   MUST be produced by `spec-lint render`, not by merging delta prose.

   First **seed** the main spec from the delta (so `render` keeps `Purpose` and the
   marker on the first archive, when `openspec/specs/<cap>/spec.md` does not exist
   yet), then render:

   ```bash
   mkdir -p openspec/specs/<capability>
   cp openspec/changes/<name>/specs/<capability>/spec.md openspec/specs/<capability>/spec.md
   bash tools/sandbox/run.sh python tools/spec-lint/spec_lint.py render <capability>
   ```

   **Бюджет `render` (агент):** один вызов за раз; early stdout ожидаем сразу
   (`discovery…`). Нет stdout ~90 с → диагностика, **не** второй параллельный
   render. Тишина ~3–5 мин → стоп, fallback: ручной stub из анкеров + пометка
   в summary. Нужен `rg` в sandbox (rebuild образа). Hybrid capability (prose +
   anchors) — **не** ставить маркер render без переноса prose в анкеры; см.
   [tools/spec-lint/README.md](../../../tools/spec-lint/README.md).

   `render` regenerates the Requirements index from code anchors and **refuses
   (rc≠0, no write)** if the capability has 0 REQUIREMENT anchors — that guards a
   prose spec from being silently wiped by a mis-placed marker. If render fails this
   way, the marker is on the wrong capability (prose-only) — remove it and sync
   normally.

   Run this instead of the standard delta→specs merge for that capability; skip
   `openspec-sync-specs` for it. Other (non-marked) capabilities sync as usual
   (backward compatible). After render, continue to step 5.

   **If delta specs exist (non code-as-spec):**
   - Compare each delta spec with its corresponding main spec at `openspec/specs/<capability>/spec.md`
   - Determine what changes would be applied (adds, modifications, removals, renames)
   - Show a combined summary of planned sync

   **Default (project rule):** sync delta specs into `openspec/specs/<capability>/spec.md`, then archive.
   Do **not** ask «sync or skip» unless the user explicitly said «без sync» / «archive without syncing» in the **current** dialog.

   If sync is needed, use Task tool (subagent_type: "general-purpose", prompt: "Use Skill tool to invoke openspec-sync-specs for change '<name>'. Delta spec analysis: <include the analyzed delta spec summary>").

5. **Implementation notes (if present — before archive)**

   Path: `openspec/changes/<name>/implementation-notes.md` (Markdown only).

   **If the file does not exist:** proceed to step 6.

   **If the file exists:**

   - Tell the user the file is **not** moved into `openspec/changes/archive/`; it must be
     reviewed and removed before the change folder is archived.
   - Ask them to open and read it (show path; optional: short summary of sections).
   - Use **AskUserQuestion tool** — suggest options such as:
     1. Reviewed — delete the file now (ready to archive)
     2. Extract valuable points into `memory/` or OpenSpec artifacts, then delete the file
     3. Postpone archive until later
   - **Do not run step 6** until `implementation-notes.md` is deleted (or user explicitly
     confirms deletion in this dialog and you remove the file).
   - After deletion, continue to step 6.

   See [docs/ai/openspec-implementation-notes.md](../../../docs/ai/openspec-implementation-notes.md).

6. **Perform the archive**

   Create the archive directory if it doesn't exist:
   ```bash
   mkdir -p openspec/changes/archive
   ```

   Generate target name using current date: `YYYY-MM-DD-<change-name>`

   **Check if target already exists:**
   - If yes: Fail with error, suggest renaming existing archive or using different date
   - If no: Move the change directory to archive

   ```bash
   mv openspec/changes/<name> openspec/changes/archive/YYYY-MM-DD-<name>
   ```

7. **Display summary**

   Show archive completion summary including:
   - Change name
   - Schema that was used
   - Archive location
   - Spec sync status (synced / sync skipped / no delta specs)
   - Note about any warnings (incomplete artifacts/tasks)
   - If implementation notes were removed this session: note that they were not archived

**Output On Success**

```
## Archive Complete

**Change:** <change-name>
**Schema:** <schema-name>
**Archived to:** openspec/changes/archive/YYYY-MM-DD-<name>/
**Specs:** ✓ Synced to main specs

All artifacts complete. All tasks complete.
```

**Output On Success (No Delta Specs)**

```
## Archive Complete

**Change:** <change-name>
**Schema:** <schema-name>
**Archived to:** openspec/changes/archive/YYYY-MM-DD-<name>/
**Specs:** No delta specs

All artifacts complete. All tasks complete.
```

**Output On Success With Warnings**

```
## Archive Complete (with warnings)

**Change:** <change-name>
**Schema:** <schema-name>
**Archived to:** openspec/changes/archive/YYYY-MM-DD-<name>/
**Specs:** Sync skipped (user chose to skip)

**Warnings:**
- Archived with 2 incomplete artifacts
- Archived with 3 incomplete tasks
- Delta spec sync was skipped (user chose to skip)

Review the archive if this was not intentional.
```

**Output On Error (Archive Exists)**

```
## Archive Failed

**Change:** <change-name>
**Target:** openspec/changes/archive/YYYY-MM-DD-<name>/

Target archive directory already exists.

**Options:**
1. Rename the existing archive
2. Delete the existing archive if it's a duplicate
3. Wait until a different date to archive
```

**Guardrails**
- Always prompt for change selection if not provided
- Use artifact graph (openspec status --json) for completion checking
- Don't block archive on warnings - just inform and confirm
- Preserve .openspec.yaml when moving to archive (it moves with the directory)
- Show clear summary of what happened
- If sync is requested, use the Skill tool to invoke `openspec-sync-specs` (agent-driven)
- If delta specs exist, always run the sync assessment and show the combined summary before syncing
- Never archive `implementation-notes.md` into `openspec/changes/archive/` — delete after user review
