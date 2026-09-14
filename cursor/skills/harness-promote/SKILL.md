---
name: harness-promote
description: >-
  Обратный перенос правок общей части из проекта в 1c-agent-kit (submodule
  harness/). Не коммитить файлы kit как blob проекта.
---

# harness-promote

Когда агент меняет общее (дока `docs/ai` kit, tools, skills шаблоны, **cc-1c-skills**):

1. Рабочий каталог правок — `harness/` (submodule), не копия в корне проекта.
2. `git -C harness status` / commit / push — **в репо kit**.
   Перед commit — OPSEC self-check: kit публичный, не течёт внутренняя
   инфра (IP/хосты/пути/кодовые имена/секреты). Канон:
   [commit-hygiene.md](../../../docs/ai/commit-hygiene.md).
3. В репо проекта: `git add harness` (только gitlink SHA). Сообщение:
   `chore(harness): bump kit to <short-sha>`.
4. Не делать `git add harness/README.md` и не копировать файлы kit в
   `docs/ai/` проекта.
5. Не bump'ать другие проекты-потребители автоматически.

**После bump cc-1c-skills у потребителя:**

```bash
bash harness/scripts/link-cc-1c-skills.sh . tools/cc-1c-skills-sync/local-skills.txt
bash harness/scripts/link-cursor-overlay.sh . tools/cc-1c-skills-sync/local-overlay.txt
bash harness/scripts/link-kit-tools.sh . tools/cc-1c-skills-sync/local-tools.txt
```

**Promote cc-1c upstream (maintainer kit):**

```bash
cd harness && python tools/cc-1c-skills-sync/sync.py
```

Скрипт: `harness/scripts/promote.sh <consumer-root>`.

Хук `pre-commit-harness` блокирует blob под `harness/` в индексе проекта.
