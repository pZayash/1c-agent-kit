# Tasks: замена openspec на kit-spec

## 1. Инструмент `tools/kit-spec/`

- [x] 1.1 Создать `tools/kit-spec/kit_spec.py`: argparse-скелет по образцу
  `tools/kit-agent/kit_agent.py` (UTF-8 reconfigure, `--root`, exit 0/1/2),
  stdlib only.
- [x] 1.2 Резолв spec-корня: `--spec-root` → `specs/` → `openspec/` (legacy,
  WARN) → ошибка «run init»; внутренняя layout-модель §2.1 design.md
  (`<cap>/`, `changes/`, `changes/archive/`); для легаси-корня read-only
  маппинг `openspec/specs` + `openspec/changes/archive` только в
  `list`/`status`/`validate`.
- [x] 1.3 `init`: создать `specs/{changes,changes/archive}` +
  `specs/README.md` (указатель на spec-workflow.md) + маркер
  `specs/.kit-spec.json` (`{"spec_format": 1}`); идемпотентно; непустой
  `specs/` без маркера → отказ (`--force`: структура поверх + WARN по
  чужим детям); никогда не писать вне `specs/`. Резолв: `specs/` без
  маркера с `changes/` → self-heal WARN; без `changes/` → foreign.
- [x] 1.4 `new <name>`: kebab-case валидация, отказ при существующем,
  scaffold `proposal/design/tasks.md` из `templates/`; `--with-delta <cap>`.
- [x] 1.5 `instructions <artifact> --change <id>`: JSON
  `{rules, template, outputPath}` из `templates/rules.json` + файлов шаблонов.
- [x] 1.6 `list`/`status`: парсинг чекбоксов `- [x]`/`- [x]` tasks.md;
  прогресс; `--json`.
- [x] 1.7 `validate [--all|--archive]`: правила §4 design.md (FAIL: файлы/
  kebab/чекбоксы/структура дельт; WARN: «Артефакты», резерв-имена,
  легаси-маркер). `--archive`: редуцированный прогон по archive/* —
  открытые чекбоксы tasks/operator-checklist → WARN, никогда FAIL.
- [x] 1.8 `archive <id>`: гейты §3.1 (implementation-notes — жёсткий отказ;
  остальное — `--force`); move в `specs/changes/archive/YYYY-MM-DD-<id>`;
  сводка.
- [x] 1.9 `migrate-root`: план → moves (`openspec/specs/*`→`specs/*`,
  `openspec/changes/*`→`specs/changes/*`, archive внутрь
  `specs/changes/archive/`; свободные файлы корня → `specs/` с
  сохранением имени, приоритет перенесённому) → shim
  `openspec/{specs->../specs, changes->../specs/changes}` (Windows
  `mklink /J`, POSIX symlink — примитивы по образцу `kit_layout.py`) →
  `.gitignore` += `openspec/` + маркер `.kit-spec.json`. Целевой `specs/`
  непустой без маркера → FAIL.
- [x] 1.10 `test_kit_spec.py`: tempfile-деревья; кейсы: init idempotent,
  new/status прогресс, validate FAIL/WARN, archive гейты (notes жёсткий),
  migrate-root + резолв старых путей через shim.

## 2. Шаблоны и канон

- [x] 2.1 `tools/kit-spec/templates/`: `proposal.md`, `design.md`,
  `tasks.md`, `delta-spec.md`, `operator-checklist.md`, `rules.json`
  (per-artifact rules+instruction, источник для `instructions`).
- [x] 2.2 `core/docs/ai/spec-workflow.md`: флоу, контракт артефактов,
  формат дельт, правила proposal/design/tasks (впитать инлайн-правки из
  openspec-propose: «Артефакты»-оглавление, tasks-конкретика, без-git-шагов,
  operator-checklist, LDD-секция design).
- [x] 2.3 `core/docs/ai/code-as-spec.md`: рамка (REQUIREMENT/MODULE_CONTRACT/
  VERIFIED-BY, render-маркер, OWNER agent|human|vendor, анти-дрифт).
- [x] 2.4 `stacks/1c/docs/ai/code-as-spec-1c.md`: binding 1С (носитель
  `Функция/Процедура`, `//` -комментарии, `PROJECT_PREFIX`, `is_ours()`,
  spec-lint check/render, бюджет render-процесса) — контент из текущих
  openspec-apply/archive блоков.

## 3. Скиллы

- [x] 3.1 `core/cursor/skills/`: переименовать `openspec-propose`→`spec-propose`,
  `openspec-apply-change`→`spec-apply`, `openspec-archive-change`→`spec-archive`;
  frontmatter до kit-стандарта (name+description; убрать license/generatedBy/
  compatibility/author); команды openspec → `kit_spec.py`.
- [x] 3.2 В `spec-propose`/`spec-apply`/`spec-archive` добавить generic-
  указатель компаньона (README §Stack authoring); вынести 1С-конкретику из
  apply/archive в компаньоны (§6.3 design.md).
- [x] 3.3 Новый `spec-sync` (проза delta-merge): анализ дельт → показать
  сводку → merge в `specs/<cap>/`; render-капы — не трогать (их путь —
  binding-инструмент).
- [x] 3.4 `stacks/1c/cursor/skills/spec-apply-1c`: code-as-spec миграция
  (метод-носитель, анкер-блок, render-маркер, spec-lint check), OWNER-режим.
- [x] 3.5 `stacks/1c/cursor/skills/spec-archive-1c`: ветка
  `code-as-spec: render` (seed → `spec-lint render` → бюджет/фолбэк).
- [x] 3.6 Референты: review, review-request, handoff, close-chat, explore,
  architect-apply, retro — имена `openspec-*`→`spec-*`, пути `openspec/`→
  `specs/`, CLI-вызовы → `kit_spec.py`, ссылки на `openspec/config.yaml` →
  `spec-workflow.md`/`kit_spec.py instructions`.
- [x] 3.7 `THIRD_PARTY_LICENSES.md`: убрать секцию 6 (OpenSpec).

## 4. Guards, deps, доки

- [x] 4.1 `tools/kit-agent/guards.json`: message `openspec-init` → kit_spec
  init; новые `openspec-cli` (warn по глаголам) и `spec-manual-archive` (warn
  на mv по `changes/`).
- [x] 4.2 `core/core.json`: `-openspec`, `+python`; `init-kit-deps.{sh,ps1}`:
  удалить `dep_openspec`/`OPENSPEC_PKG`/re-check; `dep_python` → FAIL;
  consumer-check принимает `specs/` или `openspec/`.
- [x] 4.3 `manifest.yaml`: убрать `openspec:`.
- [x] 4.4 `core/tools/sandbox/Dockerfile`: убрать `@fission-ai/openspec@1.2.0`.
- [x] 4.5 Доки: `kit-host-deps.md` (PATH-таблица, NEVER init → kit_spec),
  `rtk-token-optimized-cmd.md` (убрать openspec-примеры), `README.md`
  (строки 28/148/428–432/465), `docs-layout.md`, `project-file-links.md`,
  `agent-orchestration.md`, `templates/sections/kit-agent-loop.md`,
  `tools/cc-1c-skills-sync/sync.py`.
- [x] 4.6 `scripts/kit-doctor.{sh,ps1}`: секция spec-flow (наличие корня,
  legacy-WARN, `validate --all`, `validate --archive`).
- [x] 4.7 `openspec/` kit → `specs/` через `migrate-root` (dogfood);
  `specs/README.md` — короткий «changes самого kit».

## 5. Проверки

- [x] 5.1 `python tools/kit-spec/test_kit_spec.py` — зелёный.
- [x] 5.2 `python tools/kit-lint/check_core_purity.py` и
  `check_cross_layer_links.py` — без находок (spec-скиллы стеко-нейтральны,
  ссылки резолвятся).
- [x] 5.3 `python tools/skill-frontmatter/skill-frontmatter.py lint
  core/cursor/skills stacks/1c/cursor/skills` — без FAIL.
- [x] 5.4 Ручной прогон флоу на kit: `init` (на `specs/` после migrate) →
  `new` → `status` → `validate` → `archive` — по README-канону.
