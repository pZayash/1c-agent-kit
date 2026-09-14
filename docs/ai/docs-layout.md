# Документация потребителя kit: папки, оглавления, правила

Канон раскладки `docs/` и того, **куда агент пишет**. Специфика проекта
(префикс, ИБ, печать) — в addendum потребителя, не здесь.

Формат markdown: [markdown-formatting.md](markdown-formatting.md).
Ссылки на файлы: [project-file-links.md](project-file-links.md).

## Progressive disclosure

1. **`AGENTS.md` (корень)** — только то, что нужно **каждой** задаче + ссылки.
   Не энциклопедия.
2. **`docs/ai/`** — инструкции агентам (как делать).
3. **`docs/human/`** — для людей (setup, процесс). Не дублировать `docs/ai/`.
4. **Навык / command** — детальный рецепт одной операции.

Команда рефакторинга: [docs-progressive-disclosure-refactor](../../cursor/commands/docs-progressive-disclosure-refactor.md).

## Дерево (лениво)

Каталог появляется при **первом** файле. Не создавать пустые папки «на будущее».

```text
.
├── AGENTS.md                 # минимум + ссылки (часто CLAUDE.md → этот файл)
├── README.md                 # вход для людей
├── CONTEXT.md                # словарь домена (лениво)
├── ROLES.md                  # бизнес-роли (лениво)
├── TAGS.md                   # канон тегов memory/ (лениво)
├── memory.md                 # только стабильные глобальные правила
├── memory/                   # рабочие факты, одна запись = один .md
├── docs/
│   ├── README.md             # оглавление docs/ этого репо
│   ├── ai/                   # агенты
│   ├── human/                # люди
│   ├── adr/                  # ADR, индекс README.md
│   └── analytics/            # оргструктура / люди / теневая автоматизация
├── harness/                  # submodule kit; канон общих docs/ai — здесь
└── openspec/                 # только если потребитель ведёт OpenSpec
```

Дамп 1С (`src/cf` или `conf/`) — **не** документация. Имена объектов 1С —
кириллица платформы; правило «новые файлы латиницей» на дамп не действует.

## Где канон файла

| Что | Где править |
| --- | --- |
| Общее (markdown, git, запросы, СКД, раскладка docs) | `harness/docs/ai/…` → Promote |
| Специфика потребителя | `docs/ai/<имя>-<проект>.md` addendum **или** полный файл, если нет в kit |
| Старый путь пилота | заглушка `docs/ai/<имя>.md` → `harness/docs/ai/<имя>.md` |

Не копировать тело kit в `docs/ai/` потребителя. Не `git add harness/README.md`
как blob проекта.

Шаблон оглавления: [templates/docs/README.md](../../templates/docs/README.md).

## Оглавление

Каждый каталог с **несколькими** `.md` держит `README.md` — индекс, не эссе.

- `docs/README.md` — карта `ai` / `human` / `adr` / `analytics`.
- `docs/adr/README.md` — таблица ID / файл / status / кратко.
- `docs/analytics/README.md` — три реестра + граница с `ROLES.md` / `CONTEXT.md`.
- `docs/ai/README.md` у потребителя — **не** обязателен: канон срезов kit уже
  в [README.md](README.md). Имеет смысл, если много addenda.

Правило: **новый** `.md` в каталоге с README → строка в этот README в том же
коммите (или сразу после, до ревью). Устаревшие ссылки в индексе — удалить,
не копить.

Якорь в тексте: `§ «Имя секции»` + markdown-ссылка на файл, не голый path.

## Куда писать (агент)

| Ситуация | Куда |
| --- | --- |
| Повторяемое правило агентам | `docs/ai/` (или kit, если общее) |
| Setup / процесс для человека | `docs/human/` |
| Необратимый trade-off | `docs/adr/` — [ADR-FORMAT.md](ADR-FORMAT.md) |
| Термин домена | `CONTEXT.md` — [CONTEXT-FORMAT.md](CONTEXT-FORMAT.md) |
| Бизнес-роль человека | `ROLES.md` — [ROLES-FORMAT.md](ROLES-FORMAT.md) |
| Должность / персоналия / эксель вне 1С | `docs/analytics/` — [ANALYTICS-FORMAT.md](ANALYTICS-FORMAT.md) |
| Факт сессии, ещё не правило | `memory/` — [memory-format.md](memory-format.md) |
| Стабильное глобальное правило | `memory.md`, не раздувать `AGENTS.md` |
| Урок XML/UI, который агент **сам** решил | сразу `memory/`, перенос в docs — по оператору: [agent-session-lessons.md](agent-session-lessons.md) |

Не класть одно и то же в `AGENTS.md` и в `docs/ai/`. В корне — ссылка.

Язык тела — русский (если потребитель не задал иное). Имена **новых** файлов —
латиница ([markdown-formatting.md](markdown-formatting.md) § имена).
Объём — `/caveman` (skill). Секреты в документацию не писать.

После правки `.md`: `npx markdownlint путь/к/файлу.md` (без `rtk`).

## Addendum потребителя

Паттерн имени: `<канон-kit>-<slug>.md`, например `git-workflow-org.md`.
В каноне kit — одна строка «пилот: addendum … (не в kit)».
Заглушка на старом пути указывает на kit, не на addendum; addendum — отдельная
ссылка.
