# code-as-spec — binding 1C

Рамка и правила — [core/docs/ai/code-as-spec.md](../../../core/docs/ai/code-as-spec.md).
Здесь — специфика 1С: синтаксис анкера, носитель, инструмент `spec-lint`,
владелец по `PROJECT_PREFIX`.

## 1. Анкер (BSL)

Комментарий-блок `//` над сигнатурой метода: **после** док-коммента метода,
**перед** `Функция`/`Процедура`:

```bsl
// СПЕЦИФИКАЦИЯ
// REQUIREMENT: REQ-NNN — <краткое имя>
//
// <полный prose требования из spec.md>
//
// VERIFIED-BY: <имя теста или (no-test)>
```

## 2. Носитель требования

- Requirement с SHALL → метод по ключевым словам в tasks/design (propose
  обычно указывает имя метода).
- **1 модуль → 1 capability**: все Requirement спеки ложатся в этот модуль
  (типичный случай).
- Не сопоставляется → fallback: `tasks.md` явно указывает REQ-ID → метод.
- Контракт модуля/объекта — `MODULE_CONTRACT` над модульным комментарием.

## 3. Инструмент: spec-lint

`tools/spec-lint/spec_lint.py` (инструмент потребителя; канон —
`tools/spec-lint/README.md`). Запуск через sandbox:

```bash
bash tools/sandbox/run.sh python tools/spec-lint/spec_lint.py check [файлы]
bash tools/sandbox/run.sh python tools/spec-lint/spec_lint.py render <capability>
```

- `check` — консистентность анкеров (оторванные REQUIREMENT, дрифт).
  Не зелёный после миграции → предупредить, **не** блокировать apply.
- `render <capability>` — пересобирает `specs/<cap>/spec.md` из анкеров.
  **Отказывает (rc≠0, без записи) при 0 REQUIREMENT-анкеров** — маркер на
  prose-only capability ошибочен: снять маркер, синкать прозой как обычно.

**Бюджет `render` (агент):** один вызов за раз; early stdout ожидаем сразу
(`discovery…`). Нет stdout ~90 с → диагностика, **не** второй параллельный
render. Тишина ~3–5 мин → стоп, fallback: ручной stub из анкеров + пометка
в summary. Нужен `rg` в sandbox (rebuild образа).

## 4. Render при archive (ветка `code-as-spec: render`)

Дельта `specs/<cap>/spec.md` с маркером `<!-- code-as-spec: render -->`:
prose-источник — анкеры кода, не дельта. Финальный `specs/<cap>/spec.md`
получается **render'ом**, не merge прозы:

```bash
mkdir -p specs/<cap>
cp specs/changes/<name>/specs/<cap>/spec.md specs/<cap>/spec.md   # seed
bash tools/sandbox/run.sh python tools/spec-lint/spec_lint.py render <cap>
```

Seed нужен, чтобы первый render сохранил `Purpose` и маркер. Остальные
capability синкаются как обычно (prose merge, скилл `spec-sync`).

## 5. Владелец кода в 1С

Значения `OWNER:` — рамка §5. Дефолт — по префиксу (`is_ours()` из
spec-lint): наш код (префикс `PROJECT_PREFIX` из `.env`) → `agent`;
чужой/вендорский → `vendor`; `human` — только явным маркером.
`vendor` — read-only: доработка через `PROJECT_PREFIX`-инъекции/CFE.

## 6. Change затрагивает корень исходников

Guard при apply: если change добавляет/меняет значимые методы по префиксу
потребителя, `tasks.md` должен включать шаги с REQUIREMENT/MODULE_CONTRACT/
VERIFIED-BY (rules.tasks → `kit_spec.py instructions tasks`). Нет —
предупредить пользователя, не блокировать.
