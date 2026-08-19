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

## Подключение в проект (ещё не делать на пилоте автоматически)

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
