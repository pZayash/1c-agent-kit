# Spec-workflow kit (spec-propose → spec-apply → spec-archive)

Легковесный флоу спек изменений: Markdown-конвенция `specs/` + инструмент
`tools/kit-spec/kit_spec.py` (stdlib, внутри harness — без host-deps).
Заменяет openspec CLI: ценность — конвенция и дисциплина; переплата
(npm-пакет, init-ловушка, artifact-graph) — убрана.

## Каталог

```
specs/
├── .kit-spec.json                 # маркер {"spec_format": 1}
├── <cap>/spec.md                  # библиотека слитых спек (capability dirs)
└── changes/
    ├── <id>/                      # активный change (kebab-case)
    │   ├── proposal.md  design.md  tasks.md
    │   ├── operator-checklist.md  # опц.: ручные проверки оператора
    │   ├── implementation-notes.md# опц.: журнал отклонений (не архивируется)
    │   ├── executor-task.md       # опц.: контракт для слабой модели
    │   └── specs/<cap>/spec.md    # дельты (зеркалит путь библиотеки)
    └── archive/YYYY-MM-DD-<id>/   # завершённые
```

Зарезервированные дети `specs/`: `changes`, `README.md`. Дети `.*` — service.
Легаси-корень `openspec/` — read-only (list/status/validate), миграция:
`kit_spec.py migrate-root --apply` (переносит в `specs/` и оставляет
junction-shim: `openspec/changes` → `specs/changes` и точечные
`openspec/specs/<cap>` → `specs/<cap>` для мигрированных capability — старые
ссылки продолжают работать;
shim в `.gitignore`).

## Инструмент

```bash
python harness/tools/kit-spec/kit_spec.py init            # scaffold specs/
python harness/tools/kit-spec/kit_spec.py new <id>        # scaffold change
python harness/tools/kit-spec/kit_spec.py instructions tasks --change <id>  # правила+шаблон (JSON)
python harness/tools/kit-spec/kit_spec.py list            # активные + прогресс
python harness/tools/kit-spec/kit_spec.py status <id>     # артефакты/задачи/блокеры
python harness/tools/kit-spec/kit_spec.py validate <id>   # структура (--all, --archive)
python harness/tools/kit-spec/kit_spec.py archive <id>    # гейты + move
python harness/tools/kit-spec/kit_spec.py migrate-root    # openspec/ -> specs/
```

`instructions <artifact>` — единственный канал выдачи правил артефакту
(источник: `tools/kit-spec/templates/rules.json`; этот документ — канон-
пересказ для человека).

## Флоу

1. **propose** (скилл `spec-propose`): `kit_spec.py new <id>` → артефакты в
   порядке proposal → design → tasks → (дельты). Правила каждого — через
   `instructions`.
2. **apply** (скилл `spec-apply`): реализация по чекбоксам `tasks.md`,
   прогресс — `status`. Дрифт требований по ходу — фиксировать (см. скилл).
3. **sync** (скилл `spec-sync`, проза): merge дельт в `specs/<cap>/`.
   Автоматизации нет — scope контролирует агент.
4. **archive** (скилл `spec-archive` → `kit_spec.py archive`): гейты →
   move в `changes/archive/YYYY-MM-DD-<id>`.

Доктрина **dissolve**: содержимое change по мере реализации максимально
переносится в кодовую базу (анкеры code-as-spec, комментарии, ADR, docs/).
Архив — bookkeeping, ценность уже в коде; для docs-only репо библиотека и
архив остаются основным носителем.

## Правила артефактов

### proposal.md

- Секция **«Артефакты»** обязательна: оглавление со ссылками на `design.md`,
  `tasks.md` и каждый `specs/<cap>/spec.md`; относительные пути
  (Obsidian-совместимые). Если proposal писался раньше остальных — обновить
  секцию перед финальным статусом.
- Проблема — факты и контекст. Цель — проверяемое состояние «после».
- Ссылки на смежные changes/ADR/docs — только ссылки.

### design.md

- Секция **«Логирование»** обязательна при логируемых границах (интеграции,
  фоновые задания, обработка ошибок, многошаговые сценарии) — таблица
  событие/уровень/поля/точка по [ldd.md](ldd.md), стеко-нейтрально.
  Нет границ — секцию не добавлять. Triage gate (прочтение логов прогона) —
  чекбокс в `operator-checklist.md`.
- Решения — с причиной («почему так, а не иначе»).

### tasks.md

- Конкретика **ЧТО/ГДЕ/КАК**: какие файлы/методы менять — исполнитель может
  быть слабой моделью. Каждый шаг — проверяемый чекбокс `- [ ]`.
- **Без git-шагов**: коммит, staging, push, ветка, PR — не задачи change.
- **Только агентские задачи.** Ручное тестирование, проверки в целевом
  runtime, задачи оператора — в `operator-checklist.md` (заголовок
  `# Оператор: ручная проверка`, чекбоксы `- [ ]`). Не входит в прогресс
  tasks.md, но незакрытые пункты блокируют archive.
- code-as-spec: если change затрагивает код продукта — шаги на анкеры
  REQUIREMENT/MODULE_CONTRACT/VERIFIED-BY (см. [code-as-spec.md](code-as-spec.md)
  и binding стека).

### Дельты (`changes/<id>/specs/<cap>/spec.md`)

- Секции строго `## ADDED / MODIFIED / REMOVED / RENAMED Requirements`.
- Требование: `#### Requirement: <name>` + SHALL-тело + `##### Scenario:`
  (GIVEN/WHEN/THEN). REMOVED — без Scenario.
- Дельта — только изменения, не полная спека. Merge в библиотеку — на
  archive через `spec-sync` (проза, не автоматика).
- `<!-- code-as-spec: render -->` — capability рендерится из анкеров кода
  на archive (binding стека), а не мерджится прозой.

## Гейты archive

| Условие | Результат |
| --- | --- |
| `implementation-notes.md` существует | жёсткий отказ (review + delete; `--force` не обходит) |
| незакрытые `- [ ]` в `tasks.md` | отказ, `--force` обходит |
| незакрытый `operator-checklist.md` | отказ, `--force` обходит |
| `validate` FAIL | отказ, `--force` обходит |
| цель `archive/YYYY-MM-DD-<id>` есть | отказ |
| дельта без `specs/<cap>/` в библиотеке | WARN «sync?» (не блок) |

## См. также

| Документ | Что |
| --- | --- |
| [code-as-spec.md](code-as-spec.md) | анкеры требований в коде (рамка) |
| [ldd.md](ldd.md) | проектирование логов в design.md |
| `tools/kit-spec/templates/` | шаблоны + `rules.json` (источник `instructions`) |
| `specs/README.md` у потребителя | указатель сюда |
