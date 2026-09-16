# 1c-agent-kit

Общая инфраструктура агентов для доработки конфигураций 1С.
Потребители подключают этот репозиторий как **git submodule** в `harness/`.

Канон решений — отдельный пилот-репозиторий (не этот kit). Срез общих
`docs/ai` — [docs/ai/README.md](docs/ai/README.md). Раскладка `docs/` у
потребителя — [docs/ai/docs-layout.md](docs/ai/docs-layout.md). Навыки cc-1c —
[skills/cc-1c/](skills/cc-1c/) + sync [tools/cc-1c-skills-sync/](tools/cc-1c-skills-sync/).

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

# Проверка links (копия ≠ kit link)
bash harness/scripts/verify-kit-links.sh .

# Сводная диагностика (read-only): gitlink, gitdir, links,
# stale-ссылки (WOULD PRUNE), host deps, ps1-ASCII
bash harness/scripts/kit-doctor.sh .
```

### Движок раскладки kit-layout (opt-in)

Альтернатива link-скриптам — декларативная таблица
`tools/kit-layout/layout.json` + движок `kit_layout.py` (idea: teamai
ResourceHandler): один кроссплатформенный код вместо пар sh/ps1,
встроенные tombstones и идемпотентность (`OK` без перелинковки).

```bash
# посмотреть план, ничего не меняя
python harness/tools/kit-layout/kit_layout.py plan .
# раскладка через движок в bootstrap
LAYOUT_ENGINE=1 bash harness/scripts/bootstrap-kit.sh .
# проверка (все ресурсы; verify-kit-links.sh — только spot-check)
python harness/tools/kit-layout/kit_layout.py verify .
# kit-пути, всё ещё трекнутые в индексе потребителя (Windows/junction)
python harness/tools/kit-layout/kit_layout.py tracked .
```

Паритет с link-скриптами проверен синтетикой (440 путей идентично) и на
живом потребителе (нулевой plan). Движок — **дефолт** bootstrap; откат на
legacy-скрипты: `LEGACY_LINKS=1` / `-LegacyLinks`.

`apply` ведёт **fallback-манифест** `tools/cc-1c-skills-sync/kit-fallback.txt`
(hardlink/copy + sha256) и регенерирует managed-блок `.gitignore`, чтобы
ссылки и фолбэки не попадали в `git status` потребителя.

**Windows (junction).** Без symlink-привилегии каталоги линкуются через
`mklink /J`. Git при `core.symlinks=false` идёт **внутрь** junction и трекает
содержимое kit как обычные blob'ы потребителя — на свежем `git clone` вышли
бы устаревшие копии вместо ссылок. Поэтому `apply` делает `UNTRACK`
(index-only `git rm --cached`; рабочее дерево/junction не трогаются), а
`verify` предупреждает, `tracked` — exit 1 и список. Отключить:
`--no-untrack`.

Движок безопасен при запуске из другого namespace (Linux sandbox по
Windows-раскладке): ссылка, указывающая вне consumer root, помечается
`SKIP FOREIGN-NS` и никогда не перелинковывается. `plan --strict` —
exit 1 при pending-действиях (гейт паритета для CI/валидации).

### kit-agent: хуки и guard-правила для агентов

Ядро `tools/kit-agent/kit_agent.py` (idea: teamai hooks, harness-агностично):

```bash
python harness/tools/kit-agent/kit_agent.py session-start       # подсказки (пусто = ок)
python harness/tools/kit-agent/kit_agent.py check-command "git add harness/x"  # guards
```

Адаптеры (тонкие, логика — только в ядре; правила — `guards.json`):

- **pi** (TUI и RPC/ACP — bb, Zed): `pi/extensions/kit-hooks.ts` →
  `.pi/extensions`; session-start подсказки (notify + разовый инжект),
  block/warn на bash-команды по guards, команда `/kit`.
- **Kilo Code / OpenCode**: `kilo/plugin/kit-hooks.ts` → `.kilo/plugin`
  и `.opencode/plugin` (тот же файл; Kilo — OpenCode-семейство,
  `engines.opencode`); guard-block через `tool.execute.before`,
  session-start → `experimental.chat.system.transform`.
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

`bootstrap-kit` вызывает link cc-1c → overlay → tools → editor roots
(`.agents/skills`, `.claude/skills|commands`) → pi roots (`.pi/*`), при
необходимости пишет thin `load-changed-files.sh`, затем `verify-kit-links`.

Link-скрипты заодно делают **prune** (tombstones): kit-ссылка, чей
skill/tool/rule удалён или переименован upstream, снимается (`PRUNE:`).
Локальные копии и чужие ссылки не трогаются; имена из `local-*.txt`
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
  `tools/cc-1c-skills-sync/kit-fallback.txt`, поэтому prune и `kit-doctor`
  их видят (см. § Pitfalls «File symlink без прав»).
- Git Bash на Windows: `link-*.sh` делегируют в `.ps1`.

### Pitfalls

- **Skill «есть», но не из kit** — Win: `ReparsePoint` / `dir /AL`;
  Linux: `readlink` / `verify-kit-links`.
- **Сотни `D` в git после link** — сначала merge ветки, где skills
  **untrack**; потом bootstrap (иначе REPLACE COPY).
  - Linux: kit-ссылка — symlink (mode `120000`), старые трекнутые копии
    дают `D` в `.cursor/skills/*` и `tools/*`.
  - Windows без symlink-привилегии: junction git не считает symlink'ом,
    поэтому kit-файлы не удаляются, а **перезаписываются** (`M`), а `D`
    приходят в основном от потребительских файлов внутри kit-каталогов
    (vendored BSLLS, примеры `mcp-call`). До `UNTRACK` (см. kit-layout)
    `git add -A` затянет содержимое kit как blob'ы потребителя.
- **`verify-kit-links` — spot-check**, а не полный обход: несколько
  репрезентативных ссылок + алиасы. Полная проверка — `kit_layout.py
  verify` и `kit-doctor` (в т.ч. пункт «kit links tracked in index»).
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
- **Новые alias-каталоги в `git status`** — `.kilo/plugin`,
  `.opencode/plugin` (и ранее `.pi/*`) — junction'ы kit. Если у
  потребителя они не в `.gitignore` — добавить: `/.kilo/plugin`,
  `/.opencode/plugin` (аналогично `.pi`).
- **`.ps1` только ASCII** — PS 5.1 читает BOM-less файл как ANSI
  (CP1251): байты `—`/кириллицы дают `”`, парсер рвёт строку →
  `ParserError TerminatorExpectedAtEndOfString`. Guard:
  `bash harness/scripts/check-ps1-ascii.sh` (в kit CI/pre-push).
- **Downgrade сабмодуля + bootstrap = PRUNE более новых ссылок** —
  tombstones честно снимет ссылки на skills/tools, которых нет в старом
  SHA harness. После возврата на актуальный SHA — повторный
  `bootstrap-kit` (или link-скрипты) перелинкует (`LINK:`/`JUNCTION:`).
- **File symlink без прав** — Developer Mode / `SeCreateSymbolicLinkPrivilege`
  нужны только для symlink. Порядок fallback: symlink → **hardlink**
  (`mklink /H`, без прав, на том же томе) → copy (cross-volume). Каждый
  fallback фиксируется в `tools/cc-1c-skills-sync/kit-fallback.txt`
  (rel path, source, sha256), поэтому:
  - prune (tombstones) снимает и fallback-копии по манифесту, а не только
    reparse (старый «prune blind» для copy закрыт);
  - `kit-doctor` различает «in sync» и «stale / content differs»
    (раньше умел только сказать «есть копии»);
  - правка потребителя в fallback **не затирается** молча — `KEEP LOCAL
    EDITS` (перенеси файл в `local-overlay.txt`/`local-tools.txt`, если он
    должен быть своим);
  - managed-блок `.gitignore` перегенерируется bootstrap, поэтому ссылки и
    fallback не висят `??` в `git status`
    (`KIT_NO_GITIGNORE=1` / `--no-gitignore` — выключить).
  Hardlink делает правку потребителя видимой как грязь в `harness`
  (`git -C harness status`); `kit-doctor` предупреждает «harness working
  tree dirty». Лечение прежнее: Developer Mode / SeCreateSymbolicLinkPrivilege.
- **Старый worktree** — merge → hydrate harness → `bootstrap-kit` → verify.
- **Cursor UI не видит skill (slash)** — junctions в `.cursor/skills`, UI
  читает `.agents/skills`. `bootstrap-kit` делает junction/symlink
  `.agents/skills` → `.cursor/skills` (и `.claude/skills`). Не копировать
  потребительский `setup-project-symlinks.sh` целиком (`src/cf` — layout
  потребителя).
- **Нет node / openspec / rtk на голом Windows-worktree** — слот Docker
  уже содержит их в образе; 42/`features` — нет. Скрипт
  `init-kit-deps` (`-Install`). **Не** `openspec init` (свои
  `openspec/` + kit skills). **Не** `rtk init` (CLAUDE.md). Канон:
  [docs/ai/kit-host-deps.md](docs/ai/kit-host-deps.md).
- **Пути в разном регистре (Win/macOS)** — NTFS не видит
  `Foo`/`foo`, индекс Git видит два пути. Merge:
  `untracked would be overwritten`. Канон:
  [docs/ai/git-workflow.md](docs/ai/git-workflow.md) § «Регистр путей».
  `git mv` по регистру — **два** шага через `_case.tmp`.

## cc-1c-skills (vendor + junction)

Upstream [cc-1c-skills](https://github.com/Nikolay-Shirokov/cc-1c-skills) vendored
в `skills/cc-1c/`. Promote = sync в **этом** репо → commit → bump gitlink у
потребителей.

**Потребитель** после bump (или весь стек через `bootstrap-kit`):

```bash
DRY_RUN=1 bash harness/scripts/link-cc-1c-skills.sh . tools/cc-1c-skills-sync/local-skills.txt
bash harness/scripts/link-cc-1c-skills.sh . tools/cc-1c-skills-sync/local-skills.txt
```

- LOCAL manifest: `tools/cc-1c-skills-sync/local-skills.txt` (шаблон
  [templates/local-skills.txt](templates/local-skills.txt)).
- Windows: только `mklink /J`, не Git Bash `ln -s`.
- Срез 1: без `web-test` в kit (форк потребителя остаётся LOCAL).
- meta-* XML-патчи: `tools/cc-1c-skills-sync/overlays/` + `apply-meta-xml-patches.py`.

## Cursor overlay (срез A + B)

Универсальные rules/commands/skills (не cc-1c) — [cursor/](cursor/).
Канон `harness-promote`: [cursor/skills/harness-promote/](cursor/skills/harness-promote/).

**Срез A:** caveman, openspec-*, explore, …  
**Срез B (workflow):** handoff, close-chat, load-changed-files, bsl-check,
architect-apply, mailbox, review, review-request.

**Потребитель** после cc-1c link:

```bash
DRY_RUN=1 bash harness/scripts/link-cursor-overlay.sh . tools/cc-1c-skills-sync/local-overlay.txt
bash harness/scripts/link-cursor-overlay.sh . tools/cc-1c-skills-sync/local-overlay.txt
```

- Skills: `mklink /J`. Rules/commands: **file** `mklink` (Windows Developer
  Mode); без прав — hardlink, затем copy (см. `kit-fallback.txt`).
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
Канон: [docs/ai/pi-harness.md](docs/ai/pi-harness.md).

## Workflow tools (срез B)

`tools/mailbox`, `tools/bsl-check`, `tools/sandbox`, `tools/load-changed-files`,
`tools/git-partial-stage.py` — в [tools/](tools/). Load engine:
`tools/load-changed-files/load-changed-files.sh`; корень потребителя — wrapper.

**Потребитель** после overlay link:

```bash
DRY_RUN=1 bash harness/scripts/link-kit-tools.sh . tools/cc-1c-skills-sync/local-tools.txt
bash harness/scripts/link-kit-tools.sh . tools/cc-1c-skills-sync/local-tools.txt
```

- BSLLS binary не в git: один раз на хост
  `bash harness/tools/bsl-check/update-bsl-language-server.sh` (**без**
  `--latest` = пин `BSLLS_VERSION`) пишет в **кэш**, не в worktree. Канон:
  [tools/bsl-check/README.md](tools/bsl-check/README.md). `bootstrap-kit` не
  качает. На 42: User env `KIT_BSLLS_ROOT=D:\tools\bslls`.
- Env-шаблон: [templates/env.example](templates/env.example).
- Доки: [docs/ai/agent-task-bus.md](docs/ai/agent-task-bus.md),
  [docs/ai/load-config-to-dev.md](docs/ai/load-config-to-dev.md).

Порядок bootstrap второго ПК: `git submodule update --init` →
`bootstrap-kit` (или три link-скрипта) → BSLLS в кэш хоста (не worktree) →
Reload Window.

## Подключение в проект

```bash
git submodule add <url-этого-репо> harness
git submodule update --init
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
Skill: [skills/harness-promote/SKILL.md](skills/harness-promote/SKILL.md).
