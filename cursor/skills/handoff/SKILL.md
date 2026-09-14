---
name: handoff
description: >-
  Сжать текущую сессию в handoff-документ для продолжения в новом чате или на
  другой машине. Ссылается на openspec/, memory/, коммиты — не дублирует их.
  Триггеры: handoff, /handoff, «передай контекст», «сохрани для продолжения».
argument-hint: "Фокус следующей сессии или путь к .md (опционально)"
---

# handoff — передача сессии следующему агенту

Адаптация [mattpocock/skills — handoff](https://github.com/mattpocock/skills/blob/main/skills/productivity/handoff/SKILL.md) (MIT) под стек 1С-проекта потребителя.

**Принцип:** ссылаться на устойчивые артефакты, не копировать их. Handoff — снимок сессии, не замена OpenSpec и не долговременная память.

**Не для ревью.** Двусторонний протокол ревью — отдельные скиллы по ролям: заявку исполнителя пишет [review-request](../review-request/SKILL.md), вердикт ревьювера — [review](../review/SKILL.md); канал — **шина задач**, `kind=review`. Handoff — generic-снимок для продолжения, без ролей.

## Когда вызывать

- «handoff», «/handoff», «compact session»
- «передай контекст», «сохрани для продолжения», «brief the next session»

## Аргумент

- Путь (`.md` или существующая папка) → **целевой файл**.
- Иначе → **фокус** следующей сессии (в шапку документа).
- Оба: первый токен — путь, остальное — фокус.
- Без аргумента — спросить фокус одной строкой, затем путь по умолчанию.

## Куда писать

Канон — **ящик шины**, не `handoffs/`. Корень: слот `/work/mailbox`, хост
`AGENTS_MAILBOX` (см. [mailbox](../mailbox/SKILL.md) / [paths.py](../../../tools/mailbox/paths.py)).

1. UUID задачи. `kind=handoff`, `to: operator` (если пользователь не назвал другой `to`).
2. Текст снимка — `tasks/<id>/artifacts/handoff.md` (шаблон ниже, смысл не менять).
3. `task.json` + пустой токен `inbox/operator/<id>` (или `inbox/<to>/<id>`).
4. **Перед записью** Read целевого `handoff.md`. Нет файла — норма.
5. Каталог `handoffs/` **не создавать** как канон. Явный путь пользователя под
   `handoffs/` — вежливо перенаправить в ящик, не писать туда «по привычке».
6. Сообщить id задачи и путь артефакта, не путь `handoffs/*.md`.

## Структура документа

Писать **нормальным русским**, не в стиле caveman — следующий агент должен однозначно понять контекст.

Ссылки на файлы — [docs/ai/project-file-links.md](../../../docs/ai/project-file-links.md)
(кратко: [.cursor/rules/project-file-links.mdc](../../rules/project-file-links.mdc);
markdown `[text](path)` / `[text](path#Ln)` или code citation; без wikilinks —
`openspec/config.yaml` → `rules.proposal`).

```markdown
# Handoff: <цель сессии одной строкой>

**Когда**: YYYY-MM-DD HH:MM (локальное)
**Ветка / коммит**: <ветка>, <короткий SHA> — <subject> (если есть git)
**Фокус следующей сессии**: <из аргумента, если был>

## Текущее состояние

1–3 предложения: что сделано в конце, что не доделано, что заблокировано.

## Открытые вопросы

Список нерешённых вопросов (архитектура, ожидание пользователя, неясный контракт). Если пусто — раздел опустить.

## Изменённые файлы в этой сессии

- `path/to/file` — что и зачем менялось.

Только diff этой сессии. Если правок не было — раздел опустить.
Группируй по маркеру `№%<change>`, не по файлу: один файл может нести несколько
changes — указывай это явно (см. [git-workflow.md](../../../docs/ai/git-workflow.md)).

## Проверки

- **BSL**: `check-bsl.py` / [bsl-check](../../../.cursor/skills/bsl-check/SKILL.md) — пройдено / ошибки / не запускалось.
- **XML** (Form, Template, СКД, Rights, Configuration): [xml-wellformed](../../../.cursor/skills/xml-wellformed/SKILL.md) — пройдено / не применимо.
- **OpenSpec**: активное изменение `openspec/changes/<id>/` — статус задач (кратко).

## Следующие шаги

1–5 императивных пункта с проверяемым результатом.

## Что подгрузить в следующей сессии

- **Навыки**: перечислить релевантные из `.cursor/skills/` (например `openspec-apply-change`, `form-edit`, `bsl-check`, `explore`, `code-analysis-orchestrator`).
- **Документация**: `docs/ai/...` по теме задачи.
- **Память**: `qmd query` / `qmd search` с `--path "memory/"` по ключевым терминам; при необходимости [memory.md](../../../memory.md).
- **MCP** (если нужны факты из ИБ, не из `conf/`): [docs/ai/mcp-config.md](../../../docs/ai/mcp-config.md) — конфиг `.mcp.json`, CLI `tools/mcp-call/` (`dev_dt` / `prod_dt`, `metadata_get`, `query_post`, …).
- **Поиск по коду**: сначала `qmd query`, затем узкий `grep` / [1c-configdump-fast-search](../../../.cursor/skills/1c-configdump-fast-search/SKILL.md); массовое чтение — `rlm-tools-bsl` ([docs/ai/rlm-tools-bsl.md](../../../docs/ai/rlm-tools-bsl.md)).

## Ссылки (содержимое не копировать)

- [proposal.md](openspec/changes/<id>/proposal.md), [design.md](...), [tasks.md](...)
- [implementation-notes.md](openspec/changes/<id>/implementation-notes.md) — если есть (не копировать текст; перед archive файл удаляют)
- Записи в `memory/<имя>.md`
- Коммиты / PR (URL или SHA)
- `research/`, `git-commit-summary/` — если оттуда брали решения
```

## Чего не писать в handoff

- Полный текст proposal/design/tasks, implementation-notes, ADR, исследований, описания PR/коммита — только ссылки.
- Полный код модулей — путь и краткое описание изменения.
- Секреты, токены, пароли, содержимое `.env`, строки подключения к ИБ.
- Длинные дампы MCP/qmd — итог и параметры запроса, чтобы можно было повторить проверку.

## После записи

1. Сообщить id задачи, путь `tasks/<id>/artifacts/handoff.md` и объём (строки).
   Канон не `handoffs/*.md`.
2. Если в сессии появились **кандидаты в долговременную память** — перечислить отдельно:
   - глобальное и стабильное → возможно [memory.md](../../../memory.md);
   - рабочий факт / грабли / договорённость → новый или обновлённый файл в `memory/`.
   Не сохранять в `memory/` автоматически без запроса пользователя.
3. Подсказать навыки для следующей сессии (как в mattpocock: «suggest skills»).

## Границы

- Handoff не конфигурация и не код; **не** гонять по нему `check-bsl.py` / xml-wellformed.
- Handoff **не заменяет** OpenSpec: если нужен change, а proposal нет — предложить [openspec-propose](../openspec-propose/SKILL.md) и сослаться на будущий `openspec/changes/<id>/`.
- Handoff **не дублирует** `memory/` и `memory.md` — другой канал (сессия vs долгая память).
- **Коммит в git** — только по явному запросу пользователя (см. AGENTS.md).

## Связанные скиллы

- [review-request](../review-request/SKILL.md) / [review](../review/SKILL.md) — двусторонний протокол ревью (заявка исполнителя / вердикт ревьювера), не путать со снимком сессии.
- [close-chat](../close-chat/SKILL.md) — закрытие сессии; полезное вне скоупа оформляет через handoff.
