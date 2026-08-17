# 1c-agent-kit

Общая инфраструктура агентов для доработки конфигураций 1С.
Потребители подключают этот репозиторий как **git submodule** в `harness/`.

Канон решений — отдельный пилот-репозиторий (не этот kit). Срез общих
`docs/ai` — [docs/ai/README.md](docs/ai/README.md). Остальное пока в пилоте.

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
