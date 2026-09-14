---
name: bsl-check
description: >-
  Проверка BSL через bsl-language-server (check-bsl.py); см. AGENTS.md,
  docs/ai/code-standards.md
---

# Проверка BSL (bsl-language-server / BSLLS)

## Зачем

Статический анализ `.bsl` через обёртку
[`tools/bsl-check/check-bsl.py`](../../../tools/bsl-check/check-bsl.py) над
[BSL Language Server](https://github.com/1c-syntax/bsl-language-server).

Единый прогон всех проверок проекта — [`check-changed.sh`](../../../check-changed.sh) /
[`tools/check-all/`](../../../tools/check-all/README.md) (источник истины по чекам —
[`check_all.py`](../../../tools/check-all/check_all.py)).

После правок `.bsl` запускай проверку **перед финальным ответом** пользователю.
Это дешёвый чек по риску правки `.bsl`. Коммент/опечатка без кода — BSLLS не
гоняй, скажи что пропустил. XML метаданных / несколько типов файлов →
`check-changed.sh` по ним. Полный suite / load в ИБ — только риск или явная
просьба.

Код в `#Область яя_` должен проходить BSLLS или иметь комментарий о причине
отступления — см.
[`docs/ai/code-standards.md`](../../../docs/ai/code-standards.md).

## Команды (из корня репозитория)

**ВАЖНО:** Всегда запускай проверку через песочницу Docker, чтобы избежать проблем с версиями Java/Python и запросами разрешений.

После правок файлов на диске:

```bash
bash tools/sandbox/run.sh python harness/tools/bsl-check/check-bsl.py conf/.../Module.bsl
```

Windows Docker: не `tools/bsl-check/…` — junction в sandbox мёртвый. Linux/слот:
`tools/bsl-check/check-bsl.py` тоже ок.

Проверка текста **без записи** в дерево (stdin):

```bash
bash tools/sandbox/run.sh python harness/tools/bsl-check/check-bsl.py --stdin --path Module.bsl < file.bsl
```

Если известен логический путь модуля, передай его в `--path`, например
`conf/CommonModules/яя_Модуль/Ext/Module.bsl`.

Первичный прогон (только ошибки), затем полный режим:

```bash
bash tools/sandbox/run.sh python harness/tools/bsl-check/check-bsl.py --min-severity Error conf/Path/To/Module.bsl
bash tools/sandbox/run.sh python harness/tools/bsl-check/check-bsl.py conf/Path/To/Module.bsl
```

По умолчанию порог для кода возврата — `Warning`; см. `--min-severity` в
`python harness/tools/bsl-check/check-bsl.py --help`.

## Обновление BSLLS (бинарь не в git)

Канон: [`tools/bsl-check/README.md`](../../../tools/bsl-check/README.md).

Runtime в **кэше хоста** (`KIT_BSLLS_ROOT/<пин>/`), не в каждом worktree.
`bootstrap-kit` не качает. Нет лаунчера → `check-bsl.py --which` (exit 2) и
рецепт; поставь **один раз на хост**:

```bash
# Общий кэш на хосте (User env, не repo .env):
# KIT_BSLLS_ROOT=D:\tools\bslls
bash harness/tools/bsl-check/update-bsl-language-server.sh
python harness/tools/bsl-check/check-bsl.py --which
```

Без `--latest` (бамп пина, не «как у всех»). Не качай в sidecar / worktree.
`--local` — только слот-сборка или авария.

Хост, **не** `sandbox/run.sh`. Нужны `unzip` + (`gh` или `curl`) + сеть GitHub.

**Бамп пина** (этот хост, потом commit `BSLLS_VERSION` в kit `harness/`):

```bash
bash harness/tools/bsl-check/update-bsl-language-server.sh --version 1.1.0-rc.3
# GitHub Latest = stable, RC пропускает:
# bash harness/tools/bsl-check/update-bsl-language-server.sh --latest
```

После — smoke на одном `.bsl` (не `--help` / `--which`: они BSLLS не запускают).

Windows + Docker sandbox: junction `tools/bsl-check` внутри контейнера — битая
ссылка на `/mnt/host/c/...`. Звать физический путь kit:

```bash
bash tools/sandbox/run.sh python harness/tools/bsl-check/check-bsl.py --min-severity Error conf/Path/To/Module.bsl
```

Agent-slot: rebuild образа, linux-дерево копируется на `docker build`.

## Коды возврата

- `0` — нет диагностик не ниже `--min-severity`.
- `1` — есть диагностики не ниже `--min-severity`.
- `2` — ошибка запуска или конфигурации.

## Инварианты для агента

- Чини **только** свои изменения. Чужой BSL не правь без запроса пользователя.
- Подавление замечаний: комментарии `// BSLLS:RuleKey-off` / `-on` (см. BSL LS).
- Параметр, меняющий поведение метода, должен читаться в теле — после правки
  проверь поиском по имени параметра (BSLLS не ловит неиспользуемый параметр;
  см. чек-лист корректности в [code-standards.md](../../../docs/ai/code-standards.md)).

## Сбор кейсов для SkillOpt (opt-in)

> **Пауза (2026-06):** пилот SkillOpt остановлен — **не выполнять** этот раздел:
> не вызывать `skillopt-capture`, не задавать `SKILLOPT_SESSION_ID`.
> Канон: [tools/skillopt-capture/README.md](../../../tools/skillopt-capture/README.md).

Историческая инструкция (после снятия паузы):

Если переменная окружения `SKILLOPT_SESSION_ID` задана — снимай снапшоты
файла **до и после** правки через
[`tools/skillopt-capture/snapshot.py`](../../../tools/skillopt-capture/snapshot.py).
Если переменная не задана — пропусти этот раздел, обычный workflow без
накладных расходов.

```bash
# 1. До правки
bash tools/sandbox/run.sh python tools/skillopt-capture/snapshot.py \
    conf/.../Module.bsl --note "before-fix"

# 2. ... правишь файл, прогоняешь check-bsl, чинишь диагностики ...

# 3. После правки
bash tools/sandbox/run.sh python tools/skillopt-capture/snapshot.py \
    conf/.../Module.bsl --note "after-fix"
```

`--session` подхватывается из `SKILLOPT_SESSION_ID` автоматически. Кейс
эмитится только если число диагностик строго уменьшилось.

Зачем: датасет для оптимизации этого SKILL.md накапливается stream-режимом
по триггерам решения задач (см.
[docs/ai/skillopt-датасеты.md](../../../docs/ai/skillopt-датасеты.md)),
а не bulk-mine git-истории. Инструкции по запуску и схема кейса —
[tools/skillopt-capture/README.md](../../../tools/skillopt-capture/README.md).
