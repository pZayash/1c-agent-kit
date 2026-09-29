---
name: retro
description: >-
  Ретроспектива сессии: предложить улучшения ОКРУЖЕНИЯ агента (навигация,
  автопроверки, стандарты ревью, AGENTS.md, экономия tool calls, доступ к
  информации), а не правки кода. Триггеры: /retro, «сделай ретро»,
  «ретроспектива сессии», «почему сессия была тяжёлой». Только предлагает:
  ничего не меняет без выбора оператора.
argument-hint: "<сессия | путь к логам> (опционально)"
disable-model-invocation: true
license: MIT
metadata:
  derivedFrom:
    - https://github.com/mattpocock/skills/tree/main/skills/engineering/retro
  projectAdaptation: 1c-agent-kit (harness-окружение, docs/ai, guardrails)
---

# retro — ретроспектива сессии и улучшение окружения

Адаптация [mattpocock/skills — retro](https://github.com/mattpocock/skills/tree/main/skills/engineering/retro)
(MIT) под стек kit: те же категории, но цели — файлы и guardrails этого репо.

Ты проводишь **ретроспективу**. Смотришь на запись сессии и предлагаешь
улучшения **окружения** агента, чтобы следующий прогон был лучше. Код сессии
не трогаешь.

**Принцип:** каждый кандидат трассируется к **конкретному моменту** сессии
(«искал `x` двадцатью вызовами», «сломал `y`, проверка поймала бы»).
Generic-советы «пишите тесты» — не находки.

**Жёсткое ограничение:** режим **read-only**. Ничего не менять — ни `docs/ai/`,
ни `AGENTS.md`, ни `memory/`, ни skills, ни hooks, ни `guards.json` — пока
оператор явно не выберет кандидата. Ретро **предлагает**, решает оператор.

## Когда вызывать

- `/retro`, «сделай ретро», «ретроспектива сессии», «разбери сессию»,
  «почему сессия была тяжёлой», «улучши окружение агента».
- В конце сессии, которая была тяжелее, чем должна: агент долго искал,
  ошибся на том, что поймала бы машина, или не мог дотянуться до данных.
- Скилл **user-invoked** (`disable-model-invocation`): агент не тянется к нему
  сам. Гладкая сессия даёт мало — не гонять «на всякий случай».

Не путать с [close-chat](../close-chat/SKILL.md) (закрытие/коммит) и
[review](../review/SKILL.md) (вердикт по коду). Retro смотрит не на код, а на
среду, в которой агент работал.

## Аргумент

- Без аргумента — **текущая** сессия (лучший случай: борьба ещё в контексте).
- Slug сессии / путь к логам / «прошлая сессия» — читать её запись.
- Если сессия вышла из «умной зоны» (контекст переполнен) — не мучить текущую,
  попросить открыть `/retro` в свежем чате на логах прошлой.

## Источники (read-only)

Читать в этом порядке, пока хватает доказательств:

1. **Контекст сессии** — моменты, где агент буксовал, повторял вызовы, ошибался.
2. **Сигналы разлада** — `memory/rule-friction/` (guards `block`/`warn`, ручные
   `evolve note`; канон [memory-format.md](../../../docs/ai/memory-format.md)
   § Разлад). Разобранные сигналы не переразбирать.
3. **`memory/*.md`** и `memory.md` — факты сессии (если писались).
4. **OpenSpec** — `openspec/changes/<id>/implementation-notes.md`, `tasks.md`,
   `operator-checklist.md` (отклонения, «отложено», smoke).
5. **Git** — `git log` / `git diff` / `git status` сессии, touched-файлы.
6. **Steering kit** — `AGENTS.md` (и managed-секции `templates/sections/*.md`),
   [docs/ai/README.md](../../../docs/ai/README.md) (срезы),
   [code-standards.md](../../../docs/ai/code-standards.md) (+ addendum
   потребителя `<канон>-<проект>.md`).
7. **Инвентарь guardrails** — что уже есть (см. ниже), чтобы не изобретать
   заново и замечать **неподключённые/сломанные** проверки.
8. **Логи** — dev/БД-логи или tee-файлы, если сессия их оставила.

Перед формулировкой правок в steering прочитать стиль:
[docs-layout.md](../../../docs/ai/docs-layout.md) § Progressive disclosure,
[markdown-formatting.md](../../../docs/ai/markdown-formatting.md),
[agent-session-lessons.md](../../../docs/ai/agent-session-lessons.md).
(В upstream это роль skill `writing-for-agents`; в kit — эти три документа.)

## Категории находок

| Что пошло не так | Чем чинить в kit | Куда писать |
| --- | --- | --- |
| Агент долго искал файл/факт | **Navigation pointer** из файла, который агент уже читает | `AGENTS.md` (одна ссылка), `docs/ai/README.md` (строка среза), `README.md`, `CONTEXT.md`/`TAGS.md` |
| Ошибка, которую поймала бы машина | **Automated check** | `tools/kit-agent/guards.json` + `check-command`, `tools/bsl-check`, [xml-wellformed](../xml-wellformed/SKILL.md), `tools/skill-frontmatter`, markdownlint, `hooks/pre-commit-harness`, `.githooks`/CI потребителя, `scripts/check-ps1-ascii.sh`, `kit_layout.py verify` |
| Ревьювер пропустил **judgement call** | Правило ревьюверу | [code-standards.md](../../../docs/ai/code-standards.md); специфика — addendum потребителя |
| `AGENTS.md` распух | Вынести steering в docs/ai или в проверку | `docs/ai/` (kit → Promote) или check; `AGENTS.md` — только навигация |
| Дорогой tool call | Streamline или замена | [rtk](../../../docs/ai/rtk-token-optimized-cmd.md), qmd, `grep-ast`, `mcp-call`, `mailbox` |
| Инструкция ничего не меняет (**no-op**) | Удалить | любой steering-файл |
| Агент не мог дотянуться до информации | Widen access | [sandbox.md](../../../docs/ai/sandbox.md), [logging-strategy.md](../../../docs/ai/logging-strategy.md) (tee логов), [mcp-config.md](../../../docs/ai/mcp-config.md) (read-only), qmd |

### Автопроверка важнее прозы

Различай вид нарушения **до** предложения:

- **Механическое** (запрещённый API, форма импорта, расположение файла, маркер
  `№%`) → **детерминированная проверка**, всегда. Kit для этого даёт
  `guards.json` (block/warn на команду), pre-commit, bsl-check, XML-чекер,
  skill-frontmatter, markdownlint, CI. Не писать правило прозой.
- **Judgement call** (кросс-файловая консистентность, «как в соседнем коде»,
  смысл) → [code-standards.md](../../../docs/ai/code-standards.md), которое
  читает ревьювер.

Перед предложением новой проверки прочитай **свою** команду проверки репо
(`package.json` / build-tool, `.githooks`, CI workflow). Существующая, но
**неподключённая или молча сломанная** проверка — это и есть находка, а не
повод строить новую. Репо без guardrail (нет pre-commit и CI, гоняющего
lint/typecheck/test) — отдельная находка.

### Стандарты — ревьюверу, не исполнителю

Реализация несёт максимум **контекстного давления**: исследование, код,
отладка. Ревьювер получает дифф и почти не тратит контекст. Поэтому новое
правило идёт туда, где есть место его применить — в ревью
([review](../review/SKILL.md), субагент `reviewer`), **не** в `AGENTS.md`,
который грузится в каждую сессию. `AGENTS.md` — для navigation pointers и
почти ничего больше.

## Порядок и формат вывода

Кандидаты — в чат, **по убыванию серьёзности** (🔴/🟠/🟡, как в review).
Каждый кандидат:

```markdown
1. 🔴 **Автопроверка** — момент: «<что именно было в сессии>»
   - Причина: <почему это повторится>
   - Фикс: <check | pointer | standard | removal> — `<path>`
   - Куда: `<канон kit | addendum потребителя>`
2. 🟠 **Навигация** — ...
```

Требования:

- Метка + **категория** + **момент сессии** + **фикс** + **куда**.
- Каждый пункт трассируется к моменту; не трассируется — выбросить.
- Серьёзность — черновик: тихая дорогая ошибка может быть ниже громкой дешёвой.
- В конце — **один** вопрос: «Какие кандидаты берём?» Ничего не менять до ответа.

После выбора оператора:

- Общее kit (`docs/ai`, tools, guards, skills) — правка в каноне kit, затем
  [harness-promote](../harness-promote/SKILL.md) (commit в submodule → bump SHA).
- Специфика потребителя — `docs/ai/` / `AGENTS.md` потребителя (addendum).
- Новую проверку «примерить» на репо до того, как она начнёт блокировать merge.

## Границы

- **Не правит код** сессии — это [review](../review/SKILL.md) / code-review.
- **Не пишет** `memory/`, `docs/`, `AGENTS.md`, skills, hooks, `guards.json`
  автоматически — только по выбору оператора.
- **Не заменяет** [close-chat](../close-chat/SKILL.md) (архивация/очистка/коммит)
  и [handoff](../handoff/SKILL.md) (снимок сессии).
- **Не дублирует** `evolve` (локальный overlay потребителя, разбор
  `memory/rule-friction/`): retro читает его сигналы, но ведёт шире — навигация,
  checks, tool economy, no-ops, доступ к информации.
- Kit **публичный**: перед коммитом — OPSEC self-check
  ([commit-hygiene.md](../../../docs/ai/commit-hygiene.md)); не течь внутренними
  хостами/путями/секретами.
- Не плодить проверки «навсегда»: правило, шумящее на хорошем коде, — повод его
  снять, а не терпеть. Аудит старых проверок — за оператором.

## Критерии, что сработало

- Каждый кандидат указывает на момент сессии, а не на generic best practice.
- Повторные ошибки превращаются в падающие проверки, а `AGENTS.md` — короче,
  не длиннее.
- Существующая, но не подключённая проверка всплывает как находка.
- Следующая сессия на такой же задаче находит дорогу быстрее.

## Связанные скиллы и документы

- [close-chat](../close-chat/SKILL.md) — закрытие сессии; шаг 0б memory → docs.
- [handoff](../handoff/SKILL.md) — снимок сессии для продолжения.
- [review](../review/SKILL.md) / [review-request](../review-request/SKILL.md) —
  вердикт по коду; ревьювер — адресат стандартов.
- [harness-promote](../harness-promote/SKILL.md) — перенос kit-правок.
- [agent-session-lessons.md](../../../docs/ai/agent-session-lessons.md) —
  memory → docs (уроки, которые агент решил сам).
- [docs-layout.md](../../../docs/ai/docs-layout.md),
  [markdown-formatting.md](../../../docs/ai/markdown-formatting.md) — стиль
  steering-файлов.
- [code-standards.md](../../../docs/ai/code-standards.md) — стандарты, которые
  читает ревьювер.

---

Адаптация [mattpocock/skills — retro](https://github.com/mattpocock/skills/tree/main/skills/engineering/retro)
(MIT), copyright (c) 2026 Matt Pocock. Лицензия — [LICENSE](LICENSE).
