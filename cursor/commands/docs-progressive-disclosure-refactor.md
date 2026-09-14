I want you to refactor my .cursor/SKILLS and AGENTS.md and README.md file
to follow progressive disclosure principles.

Канон раскладки `docs/` и оглавлений:
[docs-layout.md](../../harness/docs/ai/docs-layout.md).

Шаблон `docs/README.md`:
[templates/docs/README.md](../../harness/templates/docs/README.md).

Follow these steps:

1. **Find contradictions**: Identify any instructions that conflict with each
   other. For each contradiction, ask me which version I want to keep.

2. **Identify the essentials**: Extract only what belongs in the root AGENTS.md:
   - One-sentence project description
   - Non-standard build/typecheck commands
   - Anything truly relevant to every single task

3. **Group the rest**: Organize remaining instructions into logical categories
   (conventions, testing, API, Git). For each group, a separate markdown file.

4. **Create the file structure**: Output:
   - A minimal root AGENTS.md with markdown links to the separate files
   - Each separate file with its relevant instructions
   - A suggested docs/ folder structure
     (канон: [docs-layout.md](../../harness/docs/ai/docs-layout.md))

5. **Flag for deletion**: Identify any instructions that are:
   - Redundant (the agent already knows this)
   - Too vague to be actionable
   - Overly obvious (like "write clean code")

6. В README.md выноси то, что не относится к ИИ, а предназначено для людей.
