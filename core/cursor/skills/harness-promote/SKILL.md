---
name: harness-promote
description: >-
  Обратный перенос правок общей части из проекта в 1c-agent-kit (submodule
  harness/). Не коммитить файлы kit как blob проекта.
---

# harness-promote

Когда агент меняет общее (дока `docs/ai` kit, tools, skills шаблоны, **stacks/<s>/skills** — vendored скиллы стека):

1. Рабочий каталог правок — `harness/` (submodule), не копия в корне проекта.
2. `git -C harness status` / commit / push — **в репо kit**.
   Перед commit — OPSEC self-check: kit публичный, не течёт внутренняя
   инфра (IP/хосты/пути/кодовые имена/секреты). Канон:
   [commit-hygiene.md](../../../docs/ai/commit-hygiene.md).
   Перед commit skills — frontmatter lint:
   `python tools/skill-frontmatter/skill-frontmatter.py lint core/cursor/skills stacks/*/cursor/skills stacks/*/skills`
   (fixable-проблемы: `... fix <те же каталоги>`).
3. В репо проекта: `git add harness` (только gitlink SHA). Сообщение:
   `chore(harness): bump kit to <short-sha>`.
4. Не делать `git add harness/README.md` и не копировать файлы kit в
   `docs/ai/` проекта.
5. Не bump'ать другие проекты-потребители автоматически.

Перед любым выравниванием harness по `origin/master` (`checkout origin/master`,
submodule update, bump) проверь расхождение:
`git -C harness merge-base --is-ancestor HEAD origin/master` (и обратно).
HEAD не предок — это **diverged**, а не behind: `checkout origin/master`
запрещён (потеряет локальные коммиты), сначала cherry-pick локальных коммитов
на `origin/master` + push, потом bump gitlink. Локальный коммит kit, живущий
только в gitlink, — потеря при любом выравнивании и риск `git gc`.

**После bump kit у потребителя:**

```bash
bash harness/scripts/bootstrap-kit.sh .   # engine: print-config → sparse → apply → verify
```

Legacy link-скрипты (без движка): `link-*-skills.sh`,
`link-cursor-overlay.sh`, `link-kit-tools.sh` — local-манифесты по
умолчанию `.kit/local-{skills,overlay,tools}.txt` (legacy-путь
`tools/*-skills-sync/` читается при отсутствии новых).

**Promote vendored skills upstream (maintainer kit):**

```bash
cd harness && python tools/*-skills-sync/sync.py
```

Скрипт: `harness/scripts/promote.sh <consumer-root>`.

Хук `pre-commit-harness` блокирует blob под `harness/` в индексе проекта.
