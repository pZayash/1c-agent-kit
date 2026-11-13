---
name: spec-propose
description: Propose a new change with all artifacts generated in one step. Use when the user wants to describe what to build and get a complete proposal with design, specs, and tasks ready for implementation.
---

Propose a new change — создать change и все артефакты за один шаг.

**Компаньоны**: если для стека `<s>` из `.kit.json stacks[]` существует
`.cursor/skills/spec-propose-<s>/SKILL.md` — прочти все такие компаньоны
до шага 1, в порядке `stacks:[]`.

Инструмент: `python harness/tools/kit-spec/kit_spec.py` (далее `kit_spec`).
Канон артефактов и правил: `harness/core/docs/ai/spec-workflow.md`.

Артефакты change `specs/changes/<name>/`:
- proposal.md (что и зачем)
- design.md (как)
- tasks.md (шаги реализации)
- specs/<cap>/spec.md (дельты, опционально; путь внутри change)

When ready to implement, invoke skill `spec-apply` or ask to implement tasks.

---

**Input**: The user's request should include a change name (kebab-case) OR a description of what they want to build.

**Steps**

1. **If no clear input provided, ask what they want to build**

   Use the **AskUserQuestion tool** (open-ended, no preset options) to ask:
   > "What change do you want to work on? Describe what you want to build or fix."

   From their description, derive a kebab-case name (e.g., "add user authentication" → `add-user-auth`).

   **IMPORTANT**: Do NOT proceed without understanding what the user wants to build.

2. **Ensure spec root and create the change**
   ```bash
   python harness/tools/kit-spec/kit_spec.py init        # идемпотентно; создаёт specs/
   python harness/tools/kit-spec/kit_spec.py new "<name>"
   ```
   Если `init` отвечает «легаси openspec/ с содержимым» (или `new` —
   «легаси-корень read-only») — предложи `kit_spec.py migrate-root --apply`
   (переносит в `specs/`, оставляет рабочий shim для старых ссылок) и
   продолжи после миграции.
   Если change с таким именем уже существует — спроси: продолжить его или
   создать новый.

3. **Create artifacts in order: proposal → design → tasks → (deltas)**

   Use the **TodoWrite tool** to track progress through the artifacts.

   For each artifact, get rules + template:
   ```bash
   python harness/tools/kit-spec/kit_spec.py instructions <artifact> --change "<name>" --json
   ```
   (artifact: `proposal` | `design` | `tasks` | `delta`; для `delta` добавь
   `--cap <capability>`).

   The instructions JSON includes:
   - `rules`: artifact-specific rules (constraints for you - do NOT copy into output)
   - `instruction`: schema-specific guidance
   - `template`: the structure to use for your output file
   - `outputPath`: where to write the artifact

   a. Read already-created artifacts for context before writing the next one
   b. Create the artifact file using `template` as the structure
   c. Apply `rules` as constraints - but do NOT copy them into the file
   d. Show brief progress: "Created <artifact>"

   **If an artifact requires user input** (unclear context):
   - Use **AskUserQuestion tool** to clarify, then continue

4. **Validate**
   ```bash
   python harness/tools/kit-spec/kit_spec.py validate "<name>"
   ```
   FAIL — исправить и повторить. WARN — показать пользователю.

5. **Show final status**
   ```bash
   python harness/tools/kit-spec/kit_spec.py status "<name>"
   ```

**Output**

After completing all artifacts, summarize:
- Change name and location (`specs/changes/<name>/`)
- List of artifacts created with brief descriptions
- What's ready: "All artifacts created! Ready for implementation."
- Prompt: "Invoke `spec-apply` or ask me to implement to start working on the tasks."

**Artifact Creation Guidelines**

- Follow `rules` from `kit_spec instructions` for each artifact; canon:
  `harness/core/docs/ai/spec-workflow.md`
- **tasks.md** — конкретные пошаговые шаги реализации (ЧТО, ГДЕ, КАК: какие
  файлы/методы менять), а не только границы. Исполнитель — слабая модель.
  Каждый шаг — проверяемый чекбокс.
- **proposal.md** — обязательна секция **«Артефакты»** (оглавление со
  ссылками на `design.md`, `tasks.md` и каждый `specs/**/spec.md`;
  относительные пути для Obsidian). Если proposal создан раньше остальных —
  обновить секцию перед шагом 5.
- **tasks.md**: без чекбоксов про коммит/staging/push/ветку/PR.
- **tasks.md — только агентские задачи**. Ручное тестирование, проверки в
  целевом runtime, задачи оператора — в отдельный `operator-checklist.md`
  в папке change (заголовок `# Оператор: ручная проверка` + чекбоксы `- [ ]`).
  Не входит в прогресс, но незакрытые пункты блокируют archive.
  Если ручных задач нет — не создавать.
- **design.md**: при логируемых границах (интеграции, фоновые задания,
  обработка ошибок, многошаговые сценарии) — секция «Логирование» по
  [ldd.md](../../../docs/ai/ldd.md): таблица событие/уровень/поля/точка,
  стеко-нейтрально. Нет границ — секцию не добавлять.
  Triage gate — чекбокс в `operator-checklist.md`.
- **code-as-spec**: если change затрагивает код продукта, в `tasks.md`
  должны быть шаги на анкеры REQUIREMENT/MODULE_CONTRACT/VERIFIED-BY —
  рамка [code-as-spec.md](../../../docs/ai/code-as-spec.md), binding стека
  `stacks/<s>/docs/ai/code-as-spec-<s>.md` / компаньон.
- **IMPORTANT**: `rules` are constraints for YOU, not content for the file
- Read dependency artifacts for context before creating new ones

**Guardrails**
- Create ALL artifacts needed for implementation (proposal, design, tasks; deltas — если меняются спеки)
- Always read dependency artifacts before creating a new one
- If context is critically unclear, ask the user - but prefer making reasonable decisions to keep momentum
- Verify each artifact file exists after writing before proceeding to next
- After all artifacts — обнови секцию «Артефакты» в proposal.md
