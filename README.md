# 1c-agent-kit

Общая инфраструктура агентов для доработки конфигураций 1С.
Потребители подключают этот репозиторий как **git submodule** в `harness/`.

Канон решений — отдельный пилот-репозиторий (не этот kit). Срез общих
`docs/ai` — [docs/ai/README.md](docs/ai/README.md). Навыки cc-1c —
[skills/cc-1c/](skills/cc-1c/) + sync [tools/cc-1c-skills-sync/](tools/cc-1c-skills-sync/).

## cc-1c-skills (vendor + junction)

Upstream [cc-1c-skills](https://github.com/Nikolay-Shirokov/cc-1c-skills) vendored
в `skills/cc-1c/`. Promote = sync в **этом** репо → commit → bump gitlink у
потребителей.

**Потребитель** после bump:

```bash
DRY_RUN=1 bash harness/scripts/link-cc-1c-skills.sh . tools/cc-1c-skills-sync/local-skills.txt
bash harness/scripts/link-cc-1c-skills.sh . tools/cc-1c-skills-sync/local-skills.txt
```

- LOCAL manifest: `tools/cc-1c-skills-sync/local-skills.txt` (шаблон
  [templates/local-skills.txt](templates/local-skills.txt)).
- Windows: только `mklink /J`, не Git Bash `ln -s`.
- Срез 1: без `web-test` в kit (форк потребителя остаётся LOCAL).
- meta-* XML-патчи: `tools/cc-1c-skills-sync/overlays/` + `apply-meta-xml-patches.py`.

## Cursor overlay (срез A + B)

Универсальные rules/commands/skills (не cc-1c) — [cursor/](cursor/).
Канон `harness-promote`: [cursor/skills/harness-promote/](cursor/skills/harness-promote/).

**Срез A:** caveman, openspec-*, explore, xlsx, …  
**Срез B (workflow):** handoff, close-chat, load-changed-files, bsl-check,
architect-apply, mailbox, review, review-request.

**Потребитель** после cc-1c link:

```bash
DRY_RUN=1 bash harness/scripts/link-cursor-overlay.sh . tools/cc-1c-skills-sync/local-overlay.txt
bash harness/scripts/link-cursor-overlay.sh . tools/cc-1c-skills-sync/local-overlay.txt
```

- Skills: `mklink /J`. Rules/commands: **file** `mklink` (Windows Developer Mode).
- `sandbox` skill, `web-test` — LOCAL у потребителя.

## Workflow tools (срез B)

`tools/mailbox`, `tools/bsl-check`, `tools/sandbox`, `tools/load-changed-files`,
`tools/git-partial-stage.py` — в [tools/](tools/). Load engine:
`tools/load-changed-files/load-changed-files.sh`; корень потребителя — wrapper.

**Потребитель** после overlay link:

```bash
DRY_RUN=1 bash harness/scripts/link-kit-tools.sh . tools/cc-1c-skills-sync/local-tools.txt
bash harness/scripts/link-kit-tools.sh . tools/cc-1c-skills-sync/local-tools.txt
```

- BSLLS binary не в git: `bash tools/bsl-check/update-bsl-language-server.sh` после clone.
- Env-шаблон: [templates/env.example](templates/env.example).
- Доки: [docs/ai/agent-task-bus.md](docs/ai/agent-task-bus.md),
  [docs/ai/load-config-to-dev.md](docs/ai/load-config-to-dev.md).

Порядок bootstrap второго ПК: `git submodule update --init` → `link-cc-1c-skills`
→ `link-cursor-overlay` → `link-kit-tools` → BSLLS download → Reload Window.

## Подключение в проект

```bash
git submodule add <url-этого-репо> harness
git submodule update --init
```

Черновик `.gitmodules` — [templates/gitmodules](templates/gitmodules).

## Layout исходников 1С в потребителе

- Канон: Vanessa Bootstrap — `src/cf/`, `src/cfe/`
- Compat: `conf/` + `cfe.xml/` + symlink `src/cf` → `conf`

См. [manifest.yaml](manifest.yaml).

## Защита

[hooks/pre-commit-harness](hooks/pre-commit-harness) — в проекте reject, если
под `harness/` в индекс попали обычные файлы (не gitlink `160000`).

## Promote

Правка общего → commit **в этом** репо → в потребителе только bump SHA.
Skill: [skills/harness-promote/SKILL.md](skills/harness-promote/SKILL.md).
