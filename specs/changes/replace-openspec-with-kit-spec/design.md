# Design: kit-spec — замена openspec

## 1. Инструмент: отдельный `tools/kit-spec/kit_spec.py`

**Решение: отдельный инструмент, не подкоманды kit-agent.**

- `kit_agent.py` — ядро session-хуков с контрактом «read-only, offline, fast;
  exit 2 = no-op». spec-команды мутируют ФС (`init`, `new`, `archive`), другой
  домен, другой вызывающий (скиллы, не хуки).
- Паттерн kit: один инструмент — одна папка `tools/<name>/` с со-колокацией
  тестов и данных (kit-layout, kit-agent, kit-lint, section-patch,
  skill-frontmatter). У kit-spec есть со-колокированные `templates/` — отдельная
  папка напрашивается.
- Kit-internal размещение (не `core/tools/`): как kit-layout/kit-agent, вызов
  через `python harness/tools/kit-spec/kit_spec.py`. Доступен агенту всегда —
  без host-PATH и без npm. Это и есть ответ на «init-ловушку»: нечему ломать.
- Stdlib only; стиль как `kit_agent.py`: argparse-подкоманды, `--root`,
  UTF-8 reconfigure stdout/stderr для Windows, exit-коды 0/1/2;
  `test_kit_spec.py` рядом (tempfile-деревья, паттерн `test_kit_agent.py`).

## 2. Layout: канон `specs/`, легаси `openspec/`

### 2.1 Новый канон

```
specs/
├── .kit-spec.json                   # маркер {"spec_format": 1} (ось версий,
│                                    #  как layout_version; >supported → ERROR
│                                    #  с sha kit)
├── README.md                        # указатель на spec-workflow.md
├── <cap>/spec.md                    # библиотека слитых спек (capability dirs)
└── changes/
    ├── <id>/                        # активный change
    │   ├── proposal.md  design.md  tasks.md
    │   ├── operator-checklist.md    # опц., ручные проверки оператора
    │   ├── implementation-notes.md  # опц., журнал отклонений
    │   ├── executor-task.md         # опц., контракт для слабой модели
    │   └── specs/<cap>/spec.md      # дельты (зеркалит путь библиотеки)
    └── archive/YYYY-MM-DD-<id>/     # завершённые
```

Отличия от openspec-layout: корень `specs/` вместо `openspec/`; библиотека
поднята на уровень (`specs/<cap>/`, не `specs/specs/<cap>/`); `archive/`
остаётся вложенным в `changes/` (как было — минимум концептуальных отличий).
Зарезервированные имена детей `specs/`: `changes`, `README.md` — validate их
не считает capability; capability-каталог обязан содержать `spec.md` (иначе
WARN). Дети `.*` — service names по конвенции kit-layout, игнорируются всегда.

### 2.2 Резолв корня и маркер

Порядок: флаг `--spec-root` → `specs/` → `openspec/` (легаси, WARN
«legacy root: `kit_spec.py migrate-root`») → иначе ошибка «run init».

`specs/` без маркера: есть `changes/` → self-heal (принять за ours, WARN
«no marker — run init to stamp»); нет `changes/` → foreign (пропуск).
Одна внутренняя layout-модель (§2.1): легаси `openspec/` поддерживается
только как указатель на миграцию — команды на нём предлагают `migrate-root`,
кроме `list`/`status`/`validate`, которые читают легаси-layout read-only
(`openspec/specs/<cap>`, `openspec/changes/archive/`). Так unmigrated-
потребитель продолжает работать, а код не раздваивается.

### 2.3 `migrate-root`

Одна команда, идемпотентная, печатает план перед мутацией:

1. `openspec/specs/<cap>` → `specs/<cap>`; `openspec/changes/<id>` →
   `specs/changes/<id>`; `openspec/changes/archive/*` → `specs/changes/archive/*`
   (просто move — вложенность archive совпадает).
2. Свободные файлы корня `openspec/` (`README.md`, `project.md`, …) → `specs/`
   с сохранением имени; при коллизии с генерируемым (`README.md`) приоритет
   перенесённому, init его не перезаписывает.
3. Создаёт shim `openspec/`: real dir `openspec/specs/` с точечными
   junction `openspec/specs/<cap> -> specs/<cap>` на каждую мигрированную
   capability + junction `openspec/changes -> specs/changes`.
   Не junction `openspec/specs -> specs/` целиком: он выставлял бы
   `specs/changes` и `.kit-spec.json` под `openspec/specs/`, а git на
   Windows (`core.symlinks=false`) ходит внутрь junction и может
   задублировать дерево в индекс.
   Старые ссылки `openspec/specs/<cap>` (мигрированные caps) и
   `openspec/changes/...` продолжают резолвиться; capability, созданные
   после миграции, в shim не попадают (точечный shim, это документировано).
4. Дописывает `openspec/` в `.gitignore` (junction-содержимое не должно
   трекаться — та же проблема, что у kit-layout на Windows) и пишет маркер
   `specs/.kit-spec.json`.
5. Печатает: «проверь `git status`, сделай commit» — git-операции не
   выполняет (переименования отловит rename detection).

Windows: `mklink /J` (админ не нужен — примитив из kit_layout). POSIX: symlink.
Целевой `specs/` непустой без маркера → FAIL (коллизия). `openspec/`
содержит нестандартное — FAIL со списком (ручной разбор).

## 3. Контракт команд

Все команды: `--root <consumer>` (default cwd). `--json` там, где вывод ест скилл.

| Команда | Поведение | Заменяет |
| --- | --- | --- |
| `init` | Создаёт `specs/{changes,changes/archive}` + `specs/README.md` (указатель на spec-workflow.md) + маркер `.kit-spec.json`. Только внутрь `specs/` — физически не может тронуть `.cursor/.claude/.pi`. Идемпотентно; непустой `specs/` без маркера → отказ (`--force`: структура поверх + WARN по чужим детям). | `openspec init` + ручной scaffold |
| `migrate-root` | §2.3. | — |
| `new <name>` | kebab-case проверка; отказ при существующем; создаёт `specs/changes/<id>/` с `proposal.md`, `design.md`, `tasks.md` из шаблонов. `--with-delta <cap>` — stub `specs/<cap>/spec.md` внутри change. Маркерных файлов нет. | `openspec new change` |
| `instructions <proposal\|design\|tasks\|delta> --change <id>` | JSON `{rules, template, outputPath}` — правила артефакта + тело шаблона + куда писать. Единственный канал, которым скилл получает правила (замена `openspec instructions` и висячего `config.yaml`). | `openspec instructions` |
| `list` | Активные changes с прогрессом `done/total` чекбоксов tasks.md; `--json`. | `openspec list --json` |
| `status <id>` | Наличие артефактов (фиксированный набор, без artifact-graph), прогресс задач, список дельт, наличие и незакрытые чекбоксы `operator-checklist.md`/`implementation-notes.md`. `--json`. | `openspec status` |
| `validate <id>\|--all` | Структурные проверки §4. FAIL → exit 1; WARN не ломает. | `openspec validate` (частично) |
| `validate --archive` | Редуцированный прогон по `changes/archive/*`: открытые `- [ ]` в `tasks.md`/`operator-checklist.md` → WARN; никогда FAIL. Для doctor. | — |
| `archive <id>` | Гейты §3.1 → move в `specs/changes/archive/YYYY-MM-DD-<id>` → сводка. Delta-merge НЕ делает. | шаг 6 archive-скилла |

### 3.1 Гейты archive

- незакрытые `- [ ]` в `tasks.md` → отказ; `--force` обходит;
- `operator-checklist.md` с незакрытыми → отказ; `--force` обходит;
- `implementation-notes.md` существует → **жёсткий отказ** (не обходится
  `--force`; контракт «не архивировать» сохраняем — удаление решает оператор);
- цель `archive/YYYY-MM-DD-<id>` существует → отказ;
- `validate` с FAIL → отказ; `--force` обходит;
- дельты есть, а `specs/<cap>/` для них нет → WARN «sync?» (не блок).

Единый `--force` (не раздельные флаги): обход — осознанное действие оператора,
сводка в любом случае перечисляет предупреждения.

### 3.2 Упрощения против openspec

Нет schema-registry (`schemaName`, `applyRequires`, artifact-graph): один
фиксированный флоу, propose-цикл скилла линеен
«proposal → design → tasks → (дельты)». Меньше кода — меньше дрейфа.

## 4. Validate: правила

| Уровень | Проверка |
| --- | --- |
| FAIL | имя change не kebab-case; нет `proposal.md`/`design.md`/`tasks.md`; `tasks.md` без чекбоксов |
| FAIL | дельта `specs/<cap>/spec.md`: нет заголовков `## ADDED/MODIFIED/REMOVED Requirements`, `#### Requirement:` без SHALL-тела, `##### Scenario:` отсутствует |
| WARN | в `proposal.md` нет секции «Артефакты»; capability-имя совпадает с зарезервированным; посторонние файлы в change (кроме known optional); `.openspec.yaml` легаси-маркер |
| WARN | `specs/` содержит non-capability ребёнка |

## 5. Шаблоны и правила (замена `openspec/config.yaml`)

Размещение: `tools/kit-spec/templates/` — kit-internal (монтирование не нужно:
читает `kit_spec.py`; агент может читать по `harness/`-пути). Файлы:
`proposal.md`, `design.md`, `tasks.md`, `delta-spec.md`, `rules.json`,
`operator-checklist.md` (справочный — создаётся по триггеру, не scaffold'ом).
`project.md` нет (решение оператора — описание проекта живёт в его документации).

Источник правил — `templates/rules.json`: per-artifact `rules` + `instruction`,
из него собирается ответ `instructions`. Канон для человека —
`core/docs/ai/spec-workflow.md` (флоу, контракт артефактов, формат дельт,
правила proposal/tasks — пересказ `rules.json` прозой). Впитанные правила:

- `rules.proposal`: секция «Артефакты» — оглавление со ссылками на
  `design.md`, `tasks.md`, каждый `specs/**/spec.md`; относительные пути
  (Obsidian-совместимые); если proposal писался раньше остальных — обновить
  секцию перед финальным статусом.
- `rules.tasks`: конкретика ЧТО/ГДЕ/КАК (какие методы/файлы менять — исполнитель
  слабая модель); каждый шаг — проверяемый чекбокс; без git/commit/staging/
  push/PR-чекбоксов; только агентские задачи — ручные проверки и задачи
  оператора в `operator-checklist.md` (`# Оператор: ручная проверка` + `- [ ]`,
  не парсится, не входит в прогресс, блокирует archive).
- `rules.design`: секция «Логирование» по `core/docs/ai/ldd.md` — обязательна
  при логируемых границах (интеграции, фоновые задания, обработка ошибок,
  многошаговые сценарии); нет границ — секцию не добавлять; triage gate —
  чекбокс в `operator-checklist.md`.
- дельты: формат `## ADDED/MODIFIED/REMOVED/RENAMED Requirements`,
  `#### Requirement: <name>` + SHALL + `##### Scenario:`.

Висячие ссылки на `openspec/config.yaml` в `openspec-propose`, `explore`,
`handoff` заменяются на `kit_spec.py instructions` / `spec-workflow.md`.

## 6. Скиллы

### 6.1 Переименование и состав

`core/cursor/skills/`: `openspec-propose` → `spec-propose`,
`openspec-apply-change` → `spec-apply`, `openspec-archive-change` →
`spec-archive`, + новый `spec-sync` (проза delta-merge — чинит висячую ссылку
`openspec-sync-specs`, которую archive-скилл звал через Task).

Frontmatter — kit-стандарт `name` + `description`; убрать `license`,
`generatedBy`, `compatibility`, `author: openspec`. Из THIRD_PARTY_LICENSES
убрать секцию 6 (контент перестаёт быть «adapted OpenSpec»).

### 6.2 Контракт сохраняется

Вход (имя или вывод из контекста; неоднозначность → `list --json` +
AskUserQuestion), артефакты, чекбоксы, форматы вывода (`## Implementing:`,
`## Archive Complete`), pause-семантика, `implementation-notes.md` /
`operator-checklist.md` / `executor-task.md`. Замена команд: `openspec new
change` → `kit_spec.py new`; `openspec status --change --json` →
`kit_spec.py status --json`; `openspec instructions` →
`kit_spec.py instructions`; `openspec list --json` → `kit_spec.py list --json`;
mkdir+mv → `kit_spec.py archive`.

### 6.3 Компаньоны (стеко-вариативные шаги)

Core-скиллы получают generic-указатель компаньонов по конвенции README
§Stack authoring. В `stacks/1c/cursor/skills/`:

- `spec-apply-1c`: code-as-spec конкретика 1С (метод-носитель по
  `Функция/Процедура`, `PROJECT_PREFIX`, `is_ours()`, `spec-lint check`),
  OWNER-режим правки;
- `spec-archive-1c`: ветка `code-as-spec: render` (`spec-lint render`,
  seed-библиотеки, бюджет процесса, fallback на stub).

`spec-propose-1c` — не нужен: rules.tasks про REQUIREMENT-чекбоксы агент
получит через `instructions` (rules.json может расширяться binding-доком — см. §7).

### 6.4 Референты (~10 файлов)

review, review-request, handoff, close-chat, explore, architect-apply, retro —
точечная правка имён `openspec-*` → `spec-*`, путей `openspec/` → `specs/`,
вызовов CLI → `kit_spec.py`.

## 7. code-as-spec — стеко-нейтральная рамка

code-as-spec — единый механизм (основное привнесение в SDD): требования
переносятся из prose в анкеры над носителем в коде; библиотека спек может
рендериться из кода (`<!-- code-as-spec: render -->`). Документы:

- `core/docs/ai/code-as-spec.md` — рамка: анкер-блок (REQUIREMENT /
  MODULE_CONTRACT / VERIFIED-BY), маркер render, владелец кода
  (OWNER: agent|human|vendor — agent black-box, human копилот, vendor
  read-only), семантика «prose источник ↔ код источник», запрет молчаливого
  дрифта. Стеко-нейтрально: синтаксис комментария и точка вставки — в binding.
- `stacks/<s>/docs/ai/code-as-spec-<s>.md` — binding: синтаксис комментария
  стека, определение метода-носителя, инструменты (`spec-lint` для 1С).
  `code-as-spec-1c.md` — контент из текущих openspec-скиллов. py/node —
  заглушки позже (вне scope этого change).
- `spec-apply`/`spec-archive` (core) держат стеко-нейтральную прозу + указатель
  «binding: `stacks/<s>/docs/ai/code-as-spec-<s>.md`, компаньон
  `spec-<skill>-<s>`».

## 8. Архивная доктрина: dissolve-into-code

Архивация не отменяется (docs-only репо без кодовой базы существуют), но
доктрина меняется:

- `spec-propose`/`design.md` планирует «кудa растворится» каждый артефакт:
  требования → анкеры в коде (code-as-spec) или библиотека спек (docs-cap);
  решения → ADR/`docs/`/комментарии модуля; контекст — не архивный груз.
- `spec-apply` при code-as-spec миграции переносит prose в анкеры по ходу
  реализации (как сейчас), render-капы при archive пересобираются из кода.
- `spec-sync` (проза): merge дельт в `specs/<cap>/` для prose-капов;
  render-капы — через binding-инструмент. Цель библиотеки — минимум prose
  там, где код уже несёт требование.
- `spec-archive` = bookkeeping-move с гейтами. Для code-поглощённого change
  архив — краткая история (proposal+tasks), ценность уже в коде.

Варианты, которые рассматривались и отвергнуты: (а) убрать archive совсем —
нет, docs-only репо; (б) авто-merge дельт инструментом — нет, scope-контроль;
(в) `spec-close` как отдельная команда — нет, один вход `archive`.

## 9. Guards (tools/kit-agent/guards.json)

- `openspec-init` (block): message → «openspec CLI не используется. Scaffold:
  `python harness/tools/kit-spec/kit_spec.py init`. Changes — скилл
  `spec-propose`.»
- `openspec-cli` (warn, новое): `\bopenspec\s+(new|list|status|instructions|
  show|diff|validate|archive|update|init)\b` → указатель на kit_spec. Матч по
  глаголу — `cat openspec/...`/`mv openspec/...` не ловит.
- `spec-manual-archive` (warn, новое): `\b(mv|move|Move-Item)\b[^|;&\n]*
  (specs|openspec)[/\\]changes[/\\][^a]` → «архивация через
  `kit_spec.py archive` — там гейты». `[^a]` отсекает `changes/archive/` как
  источник.
- pi-адаптер читает guards.json динамически — правок не требует.

## 10. Миграция (по файлам)

| Файл | Правка |
| --- | --- |
| `core/core.json` | убрать `openspec`; добавить `python` (dep_python → FAIL) |
| `scripts/init-kit-deps.{sh,ps1}` | удалить `dep_openspec`, `OPENSPEC_PKG`, openspec из re-check; consumer-check каталога — принимать `specs/` ИЛИ `openspec/` |
| `manifest.yaml` | убрать опцию `openspec` |
| `core/tools/sandbox/Dockerfile` | убрать `@fission-ai/openspec@1.2.0` |
| `openspec/` (kit repo) | `kit_spec migrate-root` на самом kit (dogfood); `specs/README.md` переписать («changes самого kit, инструмент kit_spec») |
| `core/docs/ai/kit-host-deps.md` | openspec из PATH-таблицы убрать; «NEVER openspec init» → «CLI не нужен; scaffold — kit_spec init»; python → обязательный |
| `core/docs/ai/rtk-token-optimized-cmd.md` | openspec-примеры убрать |
| `README.md` | строки 28, 148, 428–432, 465 (kit-spec в tools, `spec-*` в срезе A, specs/) |
| `docs-layout.md`, `project-file-links.md`, `agent-orchestration.md`, `templates/sections/kit-agent-loop.md`, `cc-1c-skills-sync/sync.py` | терминология |
| `THIRD_PARTY_LICENSES.md` | убрать секцию 6 |
| потребитель | bump harness → `bootstrap-kit` → `kit_spec.py migrate-root` → commit; удалить глобальный npm-пакет опционально |

## 11. kit-doctor

Новая секция spec-flow: наличие `specs/` или легаси `openspec/` (WARN если
легаси → подсказка migrate-root); `kit_spec.py validate --all` по активным
changes; `kit_spec.py validate --archive` — WARN на открытые чекбоксы в
архиве (история, нефиксабельно, но показательно). Уровень WARN — doctor
не гейт.

## 12. Трудоёмкость

| Пункт | Оценка |
| --- | --- |
| `kit_spec.py` + `templates/` + `rules.json` + `test_kit_spec.py` | ~1.5–2 дня (вкл. migrate-root с junctions) |
| `spec-workflow.md` + `code-as-spec.md` (core-рамка) + `code-as-spec-1c.md` | ~1 день |
| 4 core-скилла (propose/apply/archive/sync) + 2 компаньона 1c | ~1 день |
| Референты ~10 файлов, guards, core.json, init-kit-deps ×2, Dockerfile, manifest, README, docs, kit-doctor | ~1 день |
| **Итого** | **~4.5–5 дней** |

## 13. Открытые вопросы — решено

1. Дельты внутри change — `specs/<cap>/` (зеркало пути библиотеки).
2. Чужой `specs/` — маркер `specs/.kit-spec.json` (`spec_format`), §2.2/§3:
   непустой без маркера → отказ init; foreign → пропуск резолва.
3. Архив в doctor — `validate --archive` (WARN-only, открытые чекбоксы);
   полного validate архива нет (нефиксабельная история).
4. Свободные файлы корня `openspec/` — migrate переносит в `specs/` с
   сохранением имени; `specs/README.md` kit переписывается в этом change.
