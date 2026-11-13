# 1c-agent-kit

Общая инфраструктура агентов для доработки конфигураций 1С.
Потребители подключают этот репозиторий как **git submodule** в `harness/`.

Канон решений — отдельный пилот-репозиторий (не этот kit). Срез общих
`docs/ai` — [core/docs/ai/README.md](core/docs/ai/README.md). Раскладка `docs/` у
потребителя — [core/docs/ai/docs-layout.md](core/docs/ai/docs-layout.md). Навыки cc-1c —
[stacks/1c/skills/](stacks/1c/skills/) + sync [tools/cc-1c-skills-sync/](tools/cc-1c-skills-sync/).

## Структура: core / stacks

Kit разделён на стеко-нейтральное ядро и стеки. Потребитель выбирает
стеки в `.kit.json`; без него раскладывается **только core** (core-only
дефолт).

| Слой | Путь | Содержимое | Куда монтируется |
| --- | --- | --- | --- |
| core | `core/cursor/{skills,rules,commands}` | стеко-нейтральные навыки, правила, команды | `.cursor/*` |
| core | `core/docs/ai` | общие каноны агентов | через заглушки `docs/ai/` потребителя |
| core | `core/tools` | `sandbox`, `docs-links`, `git-partial-stage.py` | `tools/` |
| stacks/1c | `stacks/1c/skills` | вендорные cc-1c skills | `.cursor/skills` |
| stacks/1c | `stacks/1c/cursor/{skills,rules,commands}` | 1С-скиллы + компаньоны `<name>-1c` к core-пайплайнам | `.cursor/*` |
| stacks/1c | `stacks/1c/docs/ai` | 1С-каноны (запросы, СКД, метаданные) | через заглушки `docs/ai/` |
| stacks/1c | `stacks/1c/tools` | `bsl-check`, `load-changed-files`, `mcp-call`, `answer42`, `rights-xml-lint` | `tools/` |
| stacks/py | `stacks/py/docs/ai` | Python-каноны (LDD-binding и др.) | через заглушки `docs/ai/` |
| stacks/node | `stacks/node/docs/ai` | Node (JS/TS)-каноны (LDD-binding и др.) | через заглушки `docs/ai/` |
| kit-internal | `pi/`, `hooks/`, `templates/`, `openspec/`, `scripts/`, `tools/{kit-layout,kit-agent,kit-lint,cc-1c-skills-sync,section-patch,skill-frontmatter,cc-1c-skills}` | механика kit, не монтируется | — |

Манифесты слоёв: `core/core.json`, `stacks/<id>/stack.json` — `id` +
host-deps (список id на check-функции `init-kit-deps`).

## `.kit.json` — выбор стеков у потребителя

Корень репозитория потребителя:

```json
{"version": 1, "stacks": ["1c"], "source_root": "conf/",
 "paths": {"cf": "conf/", "cfe": "cfe.xml/", "vendor": "vendor.xml/"},
 "sparse": false}
```

- `stacks` — выбранные стеки; `"*"` внутри файла запрещён.
  **Отсутствует `.kit.json` → core-only** (`stacks: []`) + WARN —
  раскладываются только core-ресурсы.
- `source_root` — корень исходников у потребителя; резолв:
  `.kit.json` → `.env CONFIG_PATH` → дефолт `conf/`.
- `paths` — именованные пути исходников потребителя (`cf`, `cfe`, `vendor`).
- `sparse: true` — bootstrap включает `git sparse-checkout` для
  `harness/`: `/*`, `!/stacks/*`, `/stacks/*/stack.json`,
  `/stacks/<выбранные>/` (stack.json всегда в checkout — валидация имён).
- `exclude_resources` — id ресурсов layout, которые потребитель не
  раскладывает вовсе (в отличие от `local-*.txt`, исключающих отдельных
  детей внутри ресурса). Юзкейс: потребитель сам владеет целевым
  каталогом алиаса (`.agents/skills`, `.claude/skills`) — без exclusion
  engine упрётся в `CONFLICT`. Старые kit-ссылки исключённого ресурса
  свипятся как orphans, как при снятии стека. Неизвестный id — WARN.
- `options` — reserved.
- `KIT_LEGACY=1` — force-override `stacks: ["*"]` (env > файл) + WARN;
  для окружений без `.kit.json` до миграции.

Единственный парсер `.kit.json` — `kit_layout.py print-config --json`
(валидация до мутаций); скрипты не читают файл сами. Нет python + есть
`.kit.json` → явный отказ.

### `.kit/` у потребителя

`apply` ведёт **fallback-манифест** `.kit/fallback.txt` (hardlink/copy +
sha256, gitignored) и lock `.kit/lock`. Локальные манифесты
`.kit/local-*.txt` (`local-skills`, `local-overlay`, `local-tools`) —
**tracked**, consumer-owned: имена детей, которые потребитель не линкует
из kit. В `.gitignore` — только `.kit/fallback.txt` и `.kit/lock`;
паттерн `.kit*` — **никогда** (съест `.kit.json`).

## Stack authoring

Новый стек = `stacks/<s>/` + `stack.json` + каноничные каталоги — **ноль
правок** `layout.json` и core-скиллов. `stack.json` (та же схема у
`core/core.json`):

```json
{"id": "<s>", "description": "…", "layout_version": 1, "deps": ["…"]}
```

**Каноничные каталоги** (engine синтезирует ресурсы `auto:*`; все
опциональны — отсутствие каталога это норма, не WARN):

| Каталог `stacks/<s>/` | Ресурс | kind → target |
| --- | --- | --- |
| `cursor/skills` | `auto:overlay-skills-<s>` | child-dirs → `.cursor/skills` |
| `cursor/rules` | `auto:overlay-rules-<s>` | child-files → `.cursor/rules` |
| `cursor/commands` | `auto:overlay-commands-<s>` | child-files → `.cursor/commands` |
| `tools` | `auto:kit-tools-<s>` | child-dirs → `tools` |

Прочие каталоги (`skills/` vendor-набор, `docs/ai`) — своими механизмами
(cc-1c sync, docs-заглушки). Служебные имена `.*` и `__pycache__` не
публикуются **никаким** ресурсом — явным или синтезированным.
Синтезированные несут полный контракт явных: `local_manifest`
(`.kit/local-overlay.txt` / `.kit/local-tools.txt`), `missing_source` при
«в HEAD есть, на диске нет», порядок `core → stacks → aliases`; явный
ресурс с тем же `kind+source+target` — duplicate ERROR.

**Компаньоны скиллов.** Стеко-вариативные шаги core-пайплайна живут в
`stacks/<s>/cursor/skills/<name>-<s>/`; core-скилл держит единый
generic-указатель до шага 1: «Если для стека `<s>` из `.kit.json
stacks[]` существует `.cursor/skills/<имя-этого-скилла>-<s>/SKILL.md` —
прочти все такие компаньоны до шага 1, в порядке `stacks:[]`»
(подстановка: `handoff` → `handoff-<s>`; multi-stack — читать **все**
существующие компаньоны в порядке `stacks:[]`). Description компаньона:
без триггеров core-скилла + «вызывается из `<name>`, напрямую не
вызывать». Указатель ставится только в скиллах со стеко-вариативным
пайплайном.

**Доки стека** `stacks/<s>/docs/ai/`: документ на общий межстековый
топик именуется `<topic>-<s>.md` (иначе два стека создадут одноимённые
файлы); индексный `README.md` каталога — исключение; уникальный для
стека топик MAY иметь собственное имя; при core-аналоге — ссылка на
него первым абзацем. Существующие `stacks/1c/docs/ai/*.md` без суффикса
— grandfathered, не переименовываются.

**deps-check хук.** `deps` из `stack.json`/`core.json` диспетчеризует
`init-kit-deps` структурно (ключ `deps` из `print-config --json`; оба
файла читаются `ConvertFrom-Json`/JSON-парсером — текстовый парсинг
запрещён): id с core-функцией `dep_<d>` выполняется один раз (дедуп
между стеками), остальные — `unhandled`. При непустом `unhandled`
вызывается `stacks/<s>/deps-check.{sh,ps1}` — **оба файла обязательны**
(на Windows `.sh` exec'ит `.ps1`; `.ps1` — ASCII-safe): env
`CONSUMER_ROOT`, `HARNESS_ROOT`, `INSTALL`, `STACK_DEPS` (id через
пробел), cwd — корень потребителя; stdout — статусные строки формата
`dep_*`; `exit 0` при OK и при WARN-only, `exit != 0` → fail в
`init-kit-deps`. Нет хука при непустом `unhandled` → WARN (правило в
kit-lint). Стек с `deps`, целиком покрытыми core `dep_*`, хук иметь не
обязан. `init-kit-deps.*` не содержит литералов конкретных stack-id —
только `stacks/$s/…`.

**`layout_version`** (optional, default 1, int ≥ 1) — в `.kit.json`,
`stack.json`, `core.json`: совместимость engine↔kit; значение выше
`SUPPORTED_LAYOUT_VERSION` — ERROR с sha kit (engine валидирует
effective-стеки, kit-lint — все). Три оси версий: `.kit.json "version"`
— схема файла потребителя; `layout_version` — механизм core/stacks;
`layout.json "version"` — схема манифеста ресурсов.

## Bootstrap (рекомендуемый вход)

После `git submodule update --init`:

```bash
# Linux / Docker slot
bash harness/scripts/bootstrap-kit.sh .

# Windows (PowerShell)
powershell -NoProfile -ExecutionPolicy Bypass -File harness/scripts/bootstrap-kit.ps1 -ConsumerRoot .

# Host PATH (node, openspec CLI, rtk) — NEVER openspec init
powershell -NoProfile -File harness/scripts/init-kit-deps.ps1 -ConsumerRoot . -Install
# Linux: INSTALL=1 bash harness/scripts/init-kit-deps.sh .

# Проверка раскладки (все ресурсы)
python harness/tools/kit-layout/kit_layout.py verify .

# Сводная диагностика (read-only): gitlink, gitdir, links,
# pending actions, host deps, ps1-ASCII
bash harness/scripts/kit-doctor.sh .
```

### Движок раскладки kit-layout

Декларативная таблица `tools/kit-layout/layout.json` + движок
`kit_layout.py` (idea: teamai ResourceHandler): один кроссплатформенный
код вместо пар sh/ps1, встроенные tombstones и идемпотентность (`OK` без
перелинковки). Ресурсы с полем `"stacks"` раскладываются только при
выбранном стеке в `.kit.json`; без поля — всегда (core).

```bash
# посмотреть план, ничего не меняя (по .kit.json)
python harness/tools/kit-layout/kit_layout.py plan .
# план по ВСЕМ стекам (игнорировать фильтр)
python harness/tools/kit-layout/kit_layout.py plan . --all-stacks
# раскладка через движок в bootstrap (дефолт; LEGACY_LINKS=1 — link-скрипты)
LAYOUT_ENGINE=1 bash harness/scripts/bootstrap-kit.sh .
# проверка (все ресурсы)
python harness/tools/kit-layout/kit_layout.py verify .
# kit-пути, всё ещё трекнутые в индексе потребителя (Windows/junction)
python harness/tools/kit-layout/kit_layout.py tracked .
# consumer-путь → kit source (promote copy-fallback)
python harness/tools/kit-layout/kit_layout.py resolve-source .cursor/skills/handoff --root .
# effective-конфиг: стеки, source_root, sparse, пути манифестов
python harness/tools/kit-layout/kit_layout.py print-config --json .
```

Паритет с link-скриптами проверен синтетикой (440 путей идентично) и на
живом потребителе (нулевой plan). Движок — **дефолт** bootstrap; откат на
legacy-скрипты: `LEGACY_LINKS=1` / `-LegacyLinks`.

`apply` ведёт **fallback-манифест** `.kit/fallback.txt`
(hardlink/copy + sha256) и регенерирует managed-блок `.gitignore`, чтобы
ссылки и фолбэки не попадали в `git status` потребителя. Если symlink-права
появились позже (Developer Mode) — `apply` апгрейдит in-sync hardlink/copy
до symlink, `apply --upgrade-fallbacks` (`KIT_UPGRADE_FALLBACKS=1`) догоняет
и записи старого манифеста, а `kit-doctor` показывает фактический режим
(`N link(s), M hardlink(s), K copy(ies)`) и подсказывает апгрейд.

**Orphan-sweep (stateless).** При `apply` ссылки-«сироты» (reparse point /
symlink, чей `readlink` указывает внутрь `harness/`, имя не в effective-наборе
и не в `local-*.txt`) снимаются (`removed N link(s)`) — снятие стека в
`.kit.json` чистит его ссылки само. Фолбэк с sha из старого манифеста —
удаляется; с правкой потребителя — `WARN` и сохраняется в манифесте
(иначе 2-й apply забудет). `plan` печатает `WOULD REMOVE`, `verify` — WARN.

**Consumer-owned пути — CONFLICT, не REPLACE.** Существующий не-link путь
по managed-пути (свой каталог `.agents/skills`, свой файл поверх имени
ребёнка kit) считается потребительским: `plan`/`apply` печатают
`FAIL CONFLICT ...` и **не трогают** его (никаких rmtree/перезаписей —
раньше `REPLACE COPY` мог снести реальный `.agents/skills`). Заменять
можно только пути из `.kit/fallback.txt`; byte-identical файл апгрейдится
до ссылки как in-sync fallback. Разрешение: удалить/переименовать путь
или исключить ресурс — `.kit.json "exclude_resources"`. `verify` по
конфликтному пути — `FAIL not link (copy?)`, пока не разрешить.
Legacy link-скрипты (`LEGACY_LINKS=1`) — та же политика: consumer-owned
путь → `SKIP consumer-owned ...`, перезапись только по явному opt-in
`-ReplaceCopies` (ps1) / `KIT_REPLACE_COPIES=1` (sh).

**Windows (junction).** Без symlink-привилегии каталоги линкуются через
`mklink /J`. Git при `core.symlinks=false` идёт **внутрь** junction и трекает
содержимое kit как обычные blob'ы потребителя — на свежем `git clone` вышли
бы устаревшие копии вместо ссылок. Поэтому `apply` делает `UNTRACK`
(index-only `git rm --cached`; рабочее дерево/junction не трогаются), а
`verify` предупреждает, `tracked` — exit 1 и список. Отключить:
`--no-untrack`.

**FOREIGN-NS — ловушка, а не «безопасность».** Если ссылки созданы в другом
OS/namespace (Windows-checkout, открытый из Linux-sandbox/WSL), их target
читается как `/mnt/host/...` и лежит вне consumer root. Раньше `plan`/`apply`
молча печатали `SKIP FOREIGN-NS` (0 pending), а `verify` был зелёным — агент
получал no-op и «всё ок». Теперь:

- `plan`/`apply` с foreign-ссылками завершаются **exit 2** до первой операции
  (`ERROR: ... foreign/sandbox namespace`), `plan --strict` — ещё и exit 1;
- `verify` печатает `WARN FOREIGN-NS` по каждой ссылке и, если **все** ссылки
  вне root, `FAIL` + подсказку «запускайте в namespace хоста»;
- `bootstrap-kit` ловит то же до link-шагов (exit 2); `kit-doctor` — `[FAIL]`;
- `kit-agent check-command` даёт WARN на `sandbox/run.sh … kit_layout.py|bootstrap-kit`.

Запускать раскладку/verify только на хосте, который её создал (Git Bash /
PowerShell), не через `tools/sandbox/run.sh`. Обхода нет намеренно: тихий
no-op и зелёный verify опаснее явной ошибки.
`plan --strict` — exit 1 при pending-действиях или foreign-ns (гейт паритета
для CI/валидации).

**Symlink-корень — не FOREIGN-NS.** Agent-slot отдаёт worktree как
`/work -> /srv/agent-worktrees/agent-N`: ссылки хранят написание `/work/...`,
а `bootstrap`/engine резолвят корень в `/srv/...`. Guard сравнивает **realpath
цели с realpath корня** (`_link-common.sh: kit_canonical_path`,
`kit_layout.py: is_within_resolved`), поэтому та же раскладка под другим
написанием корня не отвергается. Регресс-тесты: `tools/kit-layout/test_kit_layout.py`
(engine + scan/compare), `tools/kit-agent/test_kit_agent.py` (namespace-хинт
без git).

**Кросс-слойные ссылки** — `tools/kit-lint/check_cross_layer_links.py`:
резолвит каждую relative-ссылку в `core/**` и `stacks/**` по
смонтированному у потребителя пути; FAIL, если из `core/` резолв попадает
в `stacks/` или цель не существует. Рядом —
`check_core_purity.py` (бан 1С-лексики в `core/cursor/{skills,rules}` вне
секций `#### stack:`).

### kit-agent: хуки и guard-правила для агентов

Ядро `tools/kit-agent/kit_agent.py` (idea: teamai hooks, harness-агностично):

```bash
python harness/tools/kit-agent/kit_agent.py session-start       # подсказки (пусто = ок)
python harness/tools/kit-agent/kit_agent.py check-command "git add harness/x"  # guards
python harness/tools/kit-agent/kit_agent.py check-index         # harness gitlink vs blobs (exit 1 = refuse)
```

`check-index` — python-порт [hooks/pre-commit-harness](hooks/pre-commit-harness)
для сред без bash (sandbox, где msys не может создать `\BaseNamedObjects` —
`.githooks` там не стартуют вовсе). Перед `git commit --no-verify` прогони
`check-index`, иначе блокирующий guard «kit не коммитить blob» молча снимается.

Адаптеры (тонкие, логика — только в ядре; правила — `guards.json`):

- **pi** (TUI и RPC/ACP — bb, Zed): `pi/extensions/kit-hooks.ts` →
  `.pi/extensions`; session-start подсказки (notify + разовый инжект),
  block/warn на bash-команды по guards, команда `/kit`.
- **Универсальный**: managed-секция `kit-agent-loop` в AGENTS.md
  (инструкция прогнать session-start и сверяться с check-command) —
  для Zed direct, любых читателей AGENTS.md и headless-режимов.

Все срабатывания guards (block/warn) автоматически фиксируются
friction-сигналом в `memory/rule-friction/` (канон `memory-format.md`
§ Разлад; разбор — skill `evolve`), session-start напоминает про
неразобранные. Ручная запись:
`kit_agent.py record-friction --rule-id … --kind block --command …`.

Parent git: `fatal: not a git repository: harness/../.git/modules/harness` —
сначала `fix-harness-gitdir` (worktree file-gitdir):

```bash
bash harness/scripts/fix-harness-gitdir.sh .
```

```powershell
# gitdir ещё нет в этом worktree — скопировать с живого wt
powershell -NoProfile -File harness/scripts/fix-harness-gitdir.ps1 `
  -ConsumerRoot . `
  -CopyFrom D:\dev\proj\main\.git\worktrees\wt-a\modules\harness
```

`bootstrap-kit` через движок раскладывает effective-ресурсы `.kit.json`
(стеки → фильтр) → alias editor roots (`.agents/skills`,
`.claude/skills|commands`) → pi roots (`.pi/*`), при необходимости пишет
thin `load-changed-files.sh` (только при выбранном стеке `1c`), затем
`kit_layout.py verify`. Legacy-режим (`LEGACY_LINKS=1`): link cc-1c →
overlay → tools → editor roots → pi roots.

Link-скрипты заодно делают **prune** (tombstones): kit-ссылка, чей
skill/tool/rule удалён или переименован upstream, снимается (`PRUNE:`).
Локальные копии и чужие ссылки не трогаются; имена из `.kit/local-*.txt`
пропускаются. Dry-run: `DRY_RUN=1` / `-DryRun` → `WOULD PRUNE:`.

`bootstrap-kit` также патчит **managed-секции** `AGENTS.md` (idea: teamai
section-patcher): тела из `templates/sections/*.md` живут между якорями
`<!-- kit-section: <slug>, hash: ... -->` и обновляются при bootstrap.
Правки пользователя внутри секции не затираются — `SKIP (drift)`; аудит:
`python harness/tools/section-patch/section-patch.py check AGENTS.md`
(exit 1 при drift). Отключить шаг: `SKIP_SECTIONS=1` / `-SkipSections`.

Frontmatter skills (`name`/`description` в `SKILL.md`) —
`tools/skill-frontmatter/skill-frontmatter.py lint|fix` (idea: teamai
ensureSkillFrontmatter): fix инжектирует блок или дописывает поля перед
закрывающим `---`, не переформатируя YAML; `name` ≠ каталога — только
ручной fix. Входит WARN-чеком в `kit-doctor` и шагом в `harness-promote`.

- Linux: нативные `link-*.sh` (`ln -sfn`).
- Windows: `link-*.ps1` (`mklink /J`; file `mklink`, при отсутствии прав —
  **hardlink**, в крайнем случае copy). File-fallback'и пишутся в
  `.kit/fallback.txt`, поэтому prune и `kit-doctor`
  их видят (см. § Pitfalls «File symlink без прав»).
- Git Bash на Windows: `link-*.sh` делегируют в `.ps1`.

### Pitfalls

- **Skill «есть», но не из kit** — Win: `ReparsePoint` / `dir /AL`;
  Linux: `readlink` / `kit_layout.py verify`.
- **Сотни `D` в git после link** — сначала merge ветки, где skills
  **untrack**; потом bootstrap (иначе CONFLICT — потребительский путь
  не затирается).
  - Linux: kit-ссылка — symlink (mode `120000`), старые трекнутые копии
    дают `D` в `.cursor/skills/*` и `tools/*`.
  - Windows без symlink-привилегии: junction git не считает symlink'ом,
    поэтому kit-файлы не удаляются, а **перезаписываются** (`M`), а `D`
    приходят в основном от потребительских файлов внутри kit-каталогов
    (vendored BSLLS, примеры `mcp-call`). До `UNTRACK` (см. kit-layout)
    `git add -A` затянет содержимое kit как blob'ы потребителя.
- **`Remove-Item` / NullRef на junction** — канон `cmd /c rmdir` (уже в `.ps1`).
- **`git status` ломается на harness в worktree** — `harness/.git` →
  `<main>/.git/worktrees/<name>/modules/harness` (не относительный
  `../.git/modules/harness` при file-gitdir).
  Скрипт: `fix-harness-gitdir.sh` / `.ps1`. На Windows **весь** parent
  `git status` падает; в Linux Docker parent git часто ещё жив.
  Emergency: `rename harness harness.bak` — git снова работает.
  `worktrees/<name>/modules/` может **не существовать**, пока в этом
  worktree ни разу не делали `submodule update`. `-CopyFrom` с другого
  wt (пример: `wt-a`) или shared `<main>/.git/modules/harness` (WARN:
  общий HEAD).
- **Копия `harness/` vs gitlink** — untracked каталог блокирует merge
  (`would be overwritten by merge`). Снести копию **до** merge ветки
  с `160000 harness`. `git clean -fd` **не** удалит каталог с файлом
  `.git` (nested repo) — нужен `rm -rf harness`.
- **Нет GitHub creds / GCM** — на 42 `git fetch origin` по SSH без TTY
  падает (`wincredman`, `/dev/tty`). Канон offline: `git bundle` с
  машины, где ветка уже есть, + `git fetch <bundle>`.
- **Слот Docker: remote `org`, не `origin`** — `origin/dev` unknown;
  merge `upstream/dev`. Host `git worktree list` помечает
  `/srv/wt/agent-N` как **prunable** — **не** `prune`.
- **CRLF в `.sh` на Linux** — `sed -i 's/\r$//'` или `tr -d '\r'`.
  Корень: у потребителя `core.autocrlf=true` без `.gitattributes`.
  Kit шлёт `.gitattributes` (`*.sh text eol=lf`), но `git checkout -f <sha>`
  **не** перезаписывает уже существующие файлы. Один раз материализовать LF:

  ```bash
  git -C harness config core.autocrlf false
  git -C harness checkout -f <sha>
  git -C harness checkout-index -a -f   # переписать рабочее дерево по атрибутам
  ```

- **WSL-bash + Windows-проект (`/mnt/<drive>/...`)** — Linux-ветка
  создаёт symlink'и на `/mnt/...`, невидимые из Windows. `bootstrap-kit`
  и `kit-layout` отказываются работать (WSL_ALLOW=1 — осознанный обход).
  Правильно: Git Bash (`bash.exe`) или PowerShell (.ps1).
- **Новые alias-каталоги в `git status`** — `.pi/*` — junction'ы kit.
  Если у потребителя они не в `.gitignore` — добавить: `/.pi/*`.
- **Ручной список kit-путей в `.gitignore` дублирует managed-блок** — после
  появления managed-блока (`# >>> kit-managed: begin`) ручные строки
  `.cursor/skills/...`, `/.pi/*` и т.п. лишние: `verify`/`kit-doctor`
  предупреждают о пересечении. Удали свои строки (блок перегенерируется
  bootstrap), оставшийся untracked-мусор добирает managed-блок. На Linux
  ссылки kit — именно symlink'и: ручные шаблоны с завершающим `/`
  (`xlsx/`, `prompt-enhancer/`) матчат только каталоги и дают `??` в
  `git status`; managed-блок корня пишет `/.cursor/skills/xlsx` (без слэша)
  и покрывает их.
- **`bootstrap-kit`/`kit_layout.py` через `tools/sandbox/run.sh` над
  Windows-деревом** — target ссылок читается как `/mnt/host/...`
  (FOREIGN-NS): engine теперь `ERROR` exit 2, а не тихий no-op/зелёный
  verify. См. § kit-layout и [core/docs/ai/sandbox.md](core/docs/ai/sandbox.md).
- **`.ps1` только ASCII** — PS 5.1 читает BOM-less файл как ANSI
  (CP1251): байты `—`/кириллицы дают `”`, парсер рвёт строку →
  `ParserError TerminatorExpectedAtEndOfString`. Guard:
  `bash harness/scripts/check-ps1-ascii.sh` (в kit CI/pre-push).
- **Кириллица в выводе `.ps1` → cp866.** PS 5.1 пишет stdout в
  OEM-кодировке хоста, поэтому при перенаправлении (`> file`) лог приходит
  нечитаемым (агент видит кракозябры). Лечение в скрипте:
  `[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false`
  (или читать лог через `iconv -f cp866`).
- **`Invoke-WebRequest` в PS 5.1 виснет на неотвечающем SSE-эндпоинте** —
  `-TimeoutSec` не срабатывает, вызов блокируется. Готовность HTTP-сервиса
  проверять TCP-чеком или через [stacks/1c/tools/mcp-call](stacks/1c/tools/mcp-call/README.md),
  а не `Invoke-WebRequest`.
- **Downgrade сабмодуля + bootstrap = PRUNE более новых ссылок** —
  tombstones честно снимет ссылки на skills/tools, которых нет в старом
  SHA harness. После возврата на актуальный SHA — повторный
  `bootstrap-kit` (или link-скрипты) перелинкует (`LINK:`/`JUNCTION:`).
- **File symlink без прав** — Developer Mode / `SeCreateSymbolicLinkPrivilege`
  нужны только для symlink. Порядок fallback: symlink → **hardlink**
  (`mklink /H`, без прав, на том же томе) → copy (cross-volume). Каждый
  fallback фиксируется в `.kit/fallback.txt`
  (rel path, source, sha256), поэтому:
  - prune (tombstones) снимает и fallback-копии по манифесту, а не только
    reparse (старый «prune blind» для copy закрыт);
  - `kit-doctor` различает «in sync» и «stale / content differs»
    (раньше умел только сказать «есть копии»);
  - правка потребителя в fallback **не затирается** молча — `KEEP LOCAL
    EDITS` (перенеси файл в `.kit/local-overlay.txt`/`.kit/local-tools.txt`, если он
    должен быть своим);
  - managed-блок `.gitignore` перегенерируется bootstrap, поэтому ссылки и
    fallback не висят `??` в `git status`
    (`KIT_NO_GITIGNORE=1` / `--no-gitignore` — выключить).
  Hardlink делает правку потребителя видимой как грязь в `harness`
  (`git -C harness status`); `kit-doctor` предупреждает «harness working
  tree dirty». Лечение прежнее: Developer Mode / SeCreateSymbolicLinkPrivilege.
- **Старый worktree** — merge → hydrate harness → `bootstrap-kit` → verify.
- **Агент/UI не видит skill (Zed, Cursor slash)** — читается `.agents/skills`
  (у Zed это корень скиллов проекта), а не `.cursor/skills`. `bootstrap-kit`
  делает junction/symlink `.agents/skills` → `.cursor/skills`
  (и `.claude/skills`). Не копировать потребительский
  `setup-project-symlinks.sh` целиком (`src/cf` — layout потребителя).
- **Нет node / openspec / rtk на голом Windows-worktree** — слот Docker
  уже содержит их в образе; 42/`features` — нет. Скрипт
  `init-kit-deps` (`-Install`) ставит core-зависимости (`core/core.json`)
  + зависимости выбранных стеков (`stacks/<id>/stack.json`). **Не** `openspec init` (свои
  `openspec/` + kit skills). **Не** `rtk init` (CLAUDE.md). Канон:
  [core/docs/ai/kit-host-deps.md](core/docs/ai/kit-host-deps.md).
- **Пути в разном регистре (Win/macOS)** — NTFS не видит
  `Foo`/`foo`, индекс Git видит два пути. Merge:
  `untracked would be overwritten`. Канон:
  [core/docs/ai/git-workflow.md](core/docs/ai/git-workflow.md) § «Регистр путей».
  `git mv` по регистру — **два** шага через `_case.tmp`.

## cc-1c-skills (vendor + junction)

Upstream [cc-1c-skills](https://github.com/Nikolay-Shirokov/cc-1c-skills) vendored
в `stacks/1c/skills/`. Promote = sync в **этом** репо → commit → bump gitlink у
потребителей.

**Потребитель** после bump (или весь стек через `bootstrap-kit`):

```bash
DRY_RUN=1 bash harness/scripts/link-cc-1c-skills.sh . .kit/local-skills.txt
bash harness/scripts/link-cc-1c-skills.sh . .kit/local-skills.txt
```

- LOCAL manifest: `.kit/local-skills.txt` (шаблон
  [templates/local-skills.txt](templates/local-skills.txt)).
- Windows: только `mklink /J`, не Git Bash `ln -s`.
- Срез 1: без `web-test` в kit (форк потребителя остаётся LOCAL).
- meta-* XML-патчи: `tools/cc-1c-skills-sync/overlays/` + `apply-meta-xml-patches.py`.

## Cursor overlay (срез A + B)

Универсальные rules/commands/skills (не cc-1c) — [core/cursor/](core/cursor/);
1С-специфика и компаньоны `<name>-1c` — [stacks/1c/cursor/](stacks/1c/cursor/).
Канон `harness-promote`: [core/cursor/skills/harness-promote/](core/cursor/skills/harness-promote/).

**Срез A:** caveman, openspec-*, explore, …  
**Срез B (workflow):** handoff, close-chat, load-changed-files, bsl-check,
architect-apply, review, review-request, retro.

Mid-pipeline core-скиллы (handoff, close-chat, architect-apply,
orchestrated-child, orchestrator) переписаны линейно без 1С; 1С-шаги — в
компаньонах `stacks/1c/cursor/skills/<name>-1c`, которые core-версия
вызывает по generic-указателю в начале пайплайна (см. § Stack authoring).

**Потребитель** после cc-1c link:

```bash
DRY_RUN=1 bash harness/scripts/link-cursor-overlay.sh . .kit/local-overlay.txt
bash harness/scripts/link-cursor-overlay.sh . .kit/local-overlay.txt
```

- Skills: `mklink /J`. Rules/commands: **file** `mklink` (Windows Developer
  Mode); без прав — hardlink, затем copy (см. `.kit/fallback.txt`).
- `sandbox` skill, `web-test` — LOCAL у потребителя.

## Pi harness (опционально)

[pi](https://pi.dev) читает навыки из `.agents/skills` (линк kit) и контекст
из `AGENTS.md`. `bootstrap-kit` дополнительно линкует:

- `.pi/skills` → `.cursor/skills` (относительные ссылки из команд),
- `.pi/prompts` → `.cursor/commands` (prompt templates `/имя`),
- `.pi/extensions` → `harness/pi/extensions` (расширения kit).

Вручную: `bash harness/scripts/link-pi-roots.sh .` (Win — `.ps1`).
Расширение `auto-session-title` — [pi/extensions/](pi/extensions/);
Zed/ACP — `node harness/pi/scripts/patch-pi-acp-session-title.mjs`.
Канон: [core/docs/ai/pi-harness.md](core/docs/ai/pi-harness.md).

## Workflow tools (срез B)

Core: `core/tools/sandbox`, `core/tools/docs-links` (граф ссылок
документации: битые ссылки и достижимость от `AGENTS.md`,
[README](core/tools/docs-links/README.md)), `core/tools/git-partial-stage.py`.
Стек `1c`: `stacks/1c/tools/bsl-check`, `stacks/1c/tools/load-changed-files`,
`stacks/1c/tools/mcp-call` (JSON-RPC к MCP-серверам 1С, в т.ч. streamable HTTP),
`stacks/1c/tools/answer42` (UI 1С через клиент тестирования:
[README](stacks/1c/tools/answer42/README.md),
[канон](stacks/1c/docs/ai/answer42.md)), `stacks/1c/tools/rights-xml-lint`.
Kit-internal: `tools/kit-layout`, `tools/kit-agent`, `tools/kit-lint`.
Load engine:
`stacks/1c/tools/load-changed-files/load-changed-files.sh`; корень потребителя — wrapper
(пишется bootstrap только при выбранном стеке `1c`).

**Потребитель** после overlay link:

```bash
DRY_RUN=1 bash harness/scripts/link-kit-tools.sh . .kit/local-tools.txt
bash harness/scripts/link-kit-tools.sh . .kit/local-tools.txt
```

- BSLLS binary не в git: один раз на хост
  `bash harness/stacks/1c/tools/bsl-check/update-bsl-language-server.sh` (**без**
  `--latest` = пин `BSLLS_VERSION`) пишет в **кэш**, не в worktree. Канон:
  [stacks/1c/tools/bsl-check/README.md](stacks/1c/tools/bsl-check/README.md). `bootstrap-kit` не
  качает. На 42: User env `KIT_BSLLS_ROOT=D:\tools\bslls`.
- Env-шаблон: [templates/env.example](templates/env.example).
- `-U`, если `/UpdateDBCfg` упал на HTTP-клиентах второй публикации ИБ: авто-retry
  `-Dynamic- -SessionTerminate force` — гейт `UPDATE_DB_FORCE_SESSIONS` (default
  `true`) / `--force-sessions` / `--no-force-sessions`. На prod выключайте гейт
  (`false`), если нельзя рвать сеансы пользователей.
- Доки: [stacks/1c/docs/ai/load-config-to-dev.md](stacks/1c/docs/ai/load-config-to-dev.md).

Порядок bootstrap второго ПК: `git submodule update --init` →
`bootstrap-kit` (или три link-скрипта) → BSLLS в кэш хоста (не worktree) →
Reload Window.

## Подключение в проект

```bash
git submodule add <url-этого-репо> harness
git submodule update --init
# .kit.json со stacks проекта, затем:
bash harness/scripts/bootstrap-kit.sh .
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
Skill: [core/cursor/skills/harness-promote/SKILL.md](core/cursor/skills/harness-promote/SKILL.md).
