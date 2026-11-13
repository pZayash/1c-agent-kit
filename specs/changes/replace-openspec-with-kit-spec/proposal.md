# Замена openspec CLI на kit-spec

## Проблема

openspec CLI (`@fission-ai/openspec@1.2.0`, upstream уже 2.0.0) используется kit
только как флоу «propose → apply → archive» поверх Markdown-конвенции
`openspec/changes/<id>/{proposal,design,tasks}.md` + delta-спеки + archive.
Сам CLI при этом — обуза:

- host-dep через npm с пином версии (дрейф 1.2.0 → 2.0.0);
- `openspec init` пишет vendor-скиллы/команды сквозь junction-алиасы
  (`.claude/skills`, `.pi/*`, `.agents/skills` → `.cursor/*`) — реальная
  опасность для потребителей; сейчас сдерживается только guard-правилом и
  ручным scaffold;
- скиллы ссылаются на `openspec/config.yaml` (`rules.proposal`/`rules.tasks`),
  который `openspec init` 1.2.0 **не создаёт** — висячая ссылка;
- скилл `openspec-sync-specs` вызывается из archive-флоу, но в kit его нет —
  вторая висячая ссылка;
- `openspec/` в корне kit — ручной staging, который CLI не гарантированно видит.

## Цель

Свой легковесный инструмент `tools/kit-spec/kit_spec.py` (stdlib-only,
kit-internal, вызов через `python harness/tools/kit-spec/kit_spec.py`):
scaffold, чтение состояния, валидация, архивация. Плюс канонический документ
`core/docs/ai/spec-workflow.md`, шаблоны артефактов и переписанные скиллы
`spec-*` вместо vendor `openspec-*`.

Ценность сохраняется: конвенция каталога спек, delta-спеки, архивация.
Переплата уходит: npm-пакет, пин версии, init-ловушка, artifact-graph.

## Решения оператора (зафиксированы)

1. Скиллы — свои имена: `spec-propose`, `spec-apply`, `spec-archive`, `spec-sync`.
2. Корневой каталог по умолчанию `specs/`; существующие `openspec/` —
   миграция командой `migrate-root` с junction-совместимостью (старые ссылки
   `openspec/...` продолжают работать).
3. Опцию `openspec` из `manifest.yaml` убрать.
4. `project.md` не scaffold'ить — описание проекта живёт в его документации.
5. `python` — обязательный core-dep (FAIL в init-kit-deps, не WARN).
6. code-as-spec — стеко-нейтральный механизм: рамочный документ в core +
   binding-документы по стекам; 1С-специфика — в binding и компаньонах.
7. Архивацию не отменять (есть docs-only репо), но доктрина — «dissolve»:
   содержимое change по мере реализации максимально переносится в кодовую базу
   (анкеры, комментарии, ADR); archive — финальный bookkeeping-move.
8. kit-doctor — добавить spec-проверки.
9. Этот change — dogfood: артефакты написаны по новой конвенции вручную.

## Не-цели (scope-контроль)

- spec-diff engine, автоматический delta-merge — остаётся прозой скилла
  `spec-sync` (человек/агент контролирует scope слияния).
- watch/UI, схемы artifact-graph, `openspec show/update`, генерация
  AGENTS.md/команд харнессов — не переносим.
- Обратная совместимость CLI-флагов openspec — не нужна.

## Артефакты

- [design.md](design.md) — контракт команд, layout, шаблоны, скиллы, гварды,
  миграция, code-as-spec рамка, архивная доктрина.
- [tasks.md](tasks.md) — план реализации.

## Связанное

- Текущие скиллы: `core/cursor/skills/openspec-*/SKILL.md` (generatedBy 1.2.0).
- Правила, которые надо «впитать»: `openspec/config.yaml` (не существует),
  инлайн-правки в `openspec-propose` (rules.proposal/rules.tasks,
  operator-checklist, LDD-секция design.md).
