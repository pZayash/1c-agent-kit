---
name: mailbox
description: >-
  Drain ящика шины задач: список входящих, показ task.json, черновик
  slot-transfer. Триггеры: /mailbox, «drain ящика», «входящие задачи»,
  «передача на слот». Не /inbox.
argument-hint: "list | show <id> | stub-transfer [to] [sha]"
---

# mailbox — drain ящика шины

Протокол — **шина задач**. Корень на диске — **ящик шины**. Подпапка
`inbox/` — **входящие** (claim-токены). Не путать с `/handoff` (снимок сессии)
и не называть скилл `/inbox`.

Канон: [docs/ai/agent-task-bus.md](../../../docs/ai/agent-task-bus.md),
термины [CONTEXT.md](../../../CONTEXT.md).

## Когда вызывать

- `/mailbox`, «drain ящика», «входящие задачи», «что в ящике»
- «передача на слот», «slot-transfer», «отправь на слот N»
- Начало сессии в слоте — список входящих для этого `to`

Не вызывать как замену `/review-request` / `/handoff`: те скиллы сами пишут
задачу нужного `kind`. Этот — list/show/stub `slot-transfer` и apply.

## Корень ящика

Как [tools/mailbox/paths.py](../../../tools/mailbox/paths.py):

- слот (`AGENT_SLOT=true`): `/work/mailbox` (symlink → `/mnt/mailbox`)
- хост: `AGENTS_MAILBOX` или `docker/agent-container/.env`

```bash
# слот
python3 /opt/agent-repo/tools/mailbox/paths.py root
python3 /opt/agent-repo/tools/mailbox/paths.py inbox slot-1

# хост (sandbox ящик не видит — python на хосте / Git Bash, не tools/sandbox/run.sh)
python tools/mailbox/paths.py root
```

Межмашинно канон ящика — **shared agent host** потребителя (не ноутбук).
`git.theirs` должен быть на `origin`. Apply и `/web-test` — на хосте теста.
См. [agent-task-bus.md](../../../docs/ai/agent-task-bus.md) § «Несколько сред»;
ADR межмашинной раскладки — у потребителя (`docs/adr/`).

`to`: `slot-1` | `slot-2` | `slot-3` | `host` | `operator` | `reviewer`.

Хост: смотреть **и** `inbox/host`, **и** `inbox/operator`. Слот N — только
`inbox/slot-N` (плюс `reviewer`, если эта сессия ревьювер).

## Команды

### list

1. Резолв корня.
2. Текущий `to`: слот → `slot-N` из `SLOT_NUM` / спросить; хост → `host` +
   `operator`.
3. Для каждого токена в `inbox/<to>/<id>` прочитать
   `tasks/<id>/task.json`: `id`, `kind`, `from`, `status`, `updatedAt`.
4. Выдать таблицу. Пусто — одна строка «входящих нет».

Не claim. Не apply без явной просьбы.

### show `<id>`

Прочитать `tasks/<id>/task.json` целиком + список `tasks/<id>/artifacts/`.
Статус и `statusHistory` — как есть. XML из артефактов в чат не вклеивать.

### stub-transfer

Черновик `kind=slot-transfer`. Спросить, если нет:

- `to` (слот-приёмник)
- `git.theirs` (полный SHA коммита на общем `.git`)

`from`: слот → `slot-N`; хост → `host`. `data.mode` по умолчанию `none`.
`data.reset` / `data.mode=slot|dev_dt` — только если пользователь сказал.

Шаги:

1. UUID: `python3 -c "import uuid; print(uuid.uuid4())"`
2. Каталог `tasks/<id>/artifacts/`
3. Записать `task.json` (схема [task.schema.json](../../../tools/mailbox/task.schema.json))
4. Пустой claim-токен `inbox/<to>/<id>` (`touch`)
5. Сообщить id и команду apply

```json
{
  "schemaVersion": 1,
  "id": "<uuid>",
  "kind": "slot-transfer",
  "from": "slot-1",
  "to": "slot-3",
  "status": "submitted",
  "createdAt": "<ISO8601 UTC>",
  "updatedAt": "<ISO8601 UTC>",
  "statusHistory": [{"at": "<ISO8601 UTC>", "status": "submitted"}],
  "artifacts": [],
  "git": {"theirs": "<sha>"},
  "data": {"mode": "none"}
}
```

Apply **с хоста** (не sandbox):

```bash
# Docker-слот ноутбука
bash docker/agent-container/mailbox-apply.sh 3 <uuid>

# Хост 42 без Docker (локальный NTFS, не UNC)
export MAILBOX_WORK=D:/dev/proj/slot-3
export AGENTS_MAILBOX=/path/to/agents/mailbox
bash tools/mailbox/apply-host.sh 3 <uuid>
```

В слоте-приёмнике apply сам не гонять без обёртки, если нужен
`data.mode!=none` (export на хосте / Docker). Чистый `none`: можно
`python3 …/apply.py --slot N --id UUID` при тех же env.

Playwright / `/web-test` apply **не** стартует. После `completed` агент
приёмника гоняет тест сам, если артефакт теста есть.

Конфликт merge (`exit 2`, `input-required`, `artifacts/conflicts.txt`): агент
приёмника чинит merge в worktree, пишет `git:<merge_sha>` в artifacts, не
`--abort` молча. Источник потом `git merge <merge_sha>`.

Cron на 42 — только list (`paths.py inbox slot-3`), не apply в живую ИБ.

## Чего не делать

- Скилл `/inbox` — нет такого.
- Писать задачи в `handoffs/` или в git репо.
- Кладть XML в поле `uri` JSON.
- Merge сразу в `main`/`master` — только `agents/TO` (политика потребителя).
- Демон / inotify.

## Связанные скиллы

- [handoff](../handoff/SKILL.md) — `kind=handoff`, `to: operator`
- [review-request](../review-request/SKILL.md) / [review](../review/SKILL.md) —
  `kind=review`
- [close-chat](../close-chat/SKILL.md) — открытые `kind=review` в ящике
