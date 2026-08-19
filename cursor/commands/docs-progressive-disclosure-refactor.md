I want you to refactor my .cursor/SKILLS and AGENTS.md and README.md file to follow progressive disclosure principles.

Follow these steps:

1. **Find contradictions**: Identify any instructions that conflict with each other. For each contradiction, ask me which version I want to keep.

2. **Identify the essentials**: Extract only what belongs in the root AGENTS.md:
   - One-sentence project description
   - Non-standard build/typecheck commands
   - Anything truly relevant to every single task

3. **Group the rest**: Organize remaining instructions into logical categories (e.g., conventions, testing patterns, API design, Git workflow). For each group, create a separate markdown file.

4. **Create the file structure**: Output:
   - A minimal root AGENTS.md with markdown links to the separate files
   - Each separate file with its relevant instructions
   - A suggested docs/ folder structure

5. **Flag for deletion**: Identify any instructions that are:
   - Redundant (the agent already knows this)
   - Too vague to be actionable
   - Overly obvious (like "write clean code")

6. В README.md выноси то, что не относиться к ИИ, а предназначено для кожаных людей