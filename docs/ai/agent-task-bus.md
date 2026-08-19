# Шина задач (agent-task-bus)

Протокол передачи работы между агентами и слотами. Не папка. Не `/handoff`.
Не «inbox слотов». GUI, HTTP A2A, демон — вне scope kit.

Термины потребителя — в его `CONTEXT.md`. ADR межмашинной раскладки — в
`docs/adr/` потребителя (kit не дублирует).

## Слои

| Имя | Что |
| --- | --- |
| **Шина задач** | протокол (статусы, kind, apply) |
| **Ящик шины** | корень на диске |
| **Входящие** | `inbox/<to>/<id>` — claim-токен |
| **Задача** | `tasks/<id>/task.json` + `artifacts/` |

## Пути

Резолв: [tools/mailbox/paths.py](../../tools/mailbox/paths.py).

- **Agent-slot:** `/work/mailbox` (symlink → `/mnt/mailbox`)
- **Хост:** `AGENTS_MAILBOX` в `.env` или `docker/agent-container/.env`

Схема: [tools/mailbox/task.schema.json](../../tools/mailbox/task.schema.json).
Скилл drain: `/mailbox` (`.cursor/skills/mailbox/SKILL.md`).

## kind

| kind | Назначение |
| --- | --- |
| `slot-transfer` | merge SHA в worktree слота + load |
| `review` | заявка/вердикт ревью ([review-request](../.cursor/skills/review-request/SKILL.md) / [review](../.cursor/skills/review/SKILL.md)) |
| `handoff` | снимок сессии ([handoff](../.cursor/skills/handoff/SKILL.md)) |

`to`: `slot-1` | `slot-2` | `slot-3` | `host` | `operator` | `reviewer`.

## Apply

Docker-слот (если есть compose у потребителя):

```bash
bash docker/agent-container/mailbox-apply.sh <slot-num> <uuid>
```

Хост без Docker:

```bash
export MAILBOX_WORK=/path/to/worktree
export AGENTS_MAILBOX=/path/to/mailbox
bash tools/mailbox/apply-host.sh <slot-num> <uuid>
```

Внутри: claim → merge `git.theirs` → `./load-changed-files.sh -U`.

## Несколько сред

Межмашинный канон ящика и web-test — **на shared agent host** потребителя,
не на ноутбуке разработчика. Детали — ADR и `docker/agent-container/` у
потребителя.

## Скиллы

| Скилл | Роль |
| --- | --- |
| `/mailbox` | list/show/stub-transfer |
| `/handoff` | `kind=handoff` → ящик |
| `/review-request` | заявка исполнителя |
| `/review` | вердикт ревьювера |

Каталог `handoffs/` — **не** канон; legacy только по явному пути пользователя.

## Promote

Правки протокола/tools — commit в **kit** (`harness/`), bump gitlink у потребителей.
