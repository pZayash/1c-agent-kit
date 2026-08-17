---
name: harness-promote
description: >-
  Обратный перенос правок общей части из проекта в 1c-agent-kit (submodule
  harness/). Не коммитить файлы kit как blob проекта.
---

# harness-promote

Когда агент меняет общее (дока `docs/ai` kit, tools, skills шаблоны):

1. Рабочий каталог правок — `harness/` (submodule), не копия в корне проекта.
2. `git -C harness status` / commit / push — **в репо kit**.
3. В репо проекта: `git add harness` (только gitlink SHA). Сообщение:
   `chore(harness): bump kit to <short-sha>`.
4. Не делать `git add harness/README.md` и не копировать файлы kit в
   `docs/ai/` проекта.
5. Не bump'ать другие проекты-потребители автоматически.

Скрипт: `harness/scripts/promote.sh <consumer-root>`.

Хук `pre-commit-harness` блокирует blob под `harness/` в индексе проекта.
