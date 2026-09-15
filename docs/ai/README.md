# docs/ai в kit

Общие правила агентов. Без специфики потребителя (`яя_`, печать, MCP CFE,
mailbox пилота). Правка — здесь, потом Promote (commit в submodule → bump SHA).

## Срез 1 (2026-08-17)

| Файл | Зачем |
| --- | --- |
| [markdown-formatting.md](markdown-formatting.md) | markdownlint, code fences |
| [project-file-links.md](project-file-links.md) | кликабельные пути, `#L` |
| [platform-pitfalls.md](platform-pitfalls.md) | ловушки платформы 1С |
| [rtk-token-optimized-cmd.md](rtk-token-optimized-cmd.md) | `rtk` |
| [shell-safety-playbook.md](shell-safety-playbook.md) | shell, byte-cap |

## Срез 2 (2026-08-18)

| Файл | Зачем |
| --- | --- |
| [query-standards.md](query-standards.md) | роутер запросов 1С |
| [регистры.md](регистры.md) | проектирование регистров |
| [скд.md](скд.md) | проектирование СКД |
| [async-methods.md](async-methods.md) | `Асинх` / `Ждать` / `Обещание` |
| [locks-and-transactions.md](locks-and-transactions.md) | блокировки, транзакции |
| [metadata-xml-load-pitfalls.md](metadata-xml-load-pitfalls.md) | ловушки LoadConfigFromFiles |
| [grep-ast.md](grep-ast.md) | поиск с контекстом AST |
| [1c-specs-index.md](1c-specs-index.md) | индекс XML-спек платформы |
| [specs/1c-*-spec.md](specs/) | спеки формата дампа (11 файлов) |

В пилоте на старых путях `docs/ai/<имя>.md` — заглушка со ссылкой сюда.

## Срез 2b (2026-08-18)

| Файл | Зачем |
| --- | --- |
| [sandbox.md](sandbox.md) | Docker-песочница, `run.sh` |
| [agent-command-allowlist.md](agent-command-allowlist.md) | allowlist Cursor/Claude |
| [git-workflow.md](git-workflow.md) | git для агентов; регистр путей NTFS |

## Срез 3w (workflow, 2026-08-19)

| Файл | Зачем |
| --- | --- |
| [agent-task-bus.md](agent-task-bus.md) | шина задач, mailbox |
| [load-config-to-dev.md](load-config-to-dev.md) | load conf в dev-ИБ |

Скиллы: `harness/cursor/skills/` (срез B). Tools: `harness/tools/{mailbox,bsl-check,sandbox,load-changed-files}`.

`tools/sandbox/` и `.cursor/cli.json` — junction/copy у потребителя. Пилот ORG: addendum
`docs/ai/git-workflow-org.md` (не в kit).

## Срез 2c (2026-08-18)

| Файл | Зачем |
| --- | --- |
| [specs/form-dsl-spec.md](specs/form-dsl-spec.md) | Form JSON DSL |
| [specs/meta-dsl-spec.md](specs/meta-dsl-spec.md) | Meta JSON DSL |
| [specs/skd-dsl-spec.md](specs/skd-dsl-spec.md) | SKD JSON DSL |
| [specs/mxl-dsl-spec.md](specs/mxl-dsl-spec.md) | MXL JSON DSL |
| [specs/role-dsl-spec.md](specs/role-dsl-spec.md) | Role JSON DSL |

Скиллы `*-compile` — в `.cursor/skills/` потребителя.

web/build/autotest:

| Файл | Зачем |
| --- | --- |
| [specs/web-spec.md](specs/web-spec.md) | Apache, default.vrd, wsap24 |
| [specs/build-spec.md](specs/build-spec.md) | пакетный `1cv8.exe` |
| [specs/epf-erf-autotest-scenario-spec.md](specs/epf-erf-autotest-scenario-spec.md) | `autotest.scenario.json` |

## Срез 3 (2026-08-18)

| Файл | Зачем |
| --- | --- |
| [code-standards.md](code-standards.md) | BSL: формат, запросы, perf/correctness, UI-сообщения |

Пилот ORG: addendum `docs/ai/code-standards-org.md` (`яя_`, `+org`/`№%`, журнал).

## Срез 3b (2026-08-18)

| Файл | Зачем |
| --- | --- |
| [object-conventions.md](object-conventions.md) | префикс/формы/XML-квалификаторы, нав-ссылки |
| [logging-strategy.md](logging-strategy.md) | когда логировать, уровни, `Попытка/Исключение` |

Пилот: `object-conventions-org.md`, `logging-strategy-org.md`.

## Срез host-deps (2026-08-20+)

| Файл | Зачем |
| --- | --- |
| [kit-host-deps.md](kit-host-deps.md) | node/openspec/rtk на worktree; **не** `openspec init` |

## Срез qmd-client (2026-09-01)

| Файл | Зачем |
| --- | --- |
| [qmd-search.md](qmd-search.md) | гибридный поиск; `QMD_CLIENT` = off / cli / mcp |
| [qmd-query-syntax.md](qmd-query-syntax.md) | `lex:` / `vec:` / `hyde:` |

Ключи `.env`: [templates/env-qmd.example](../../templates/env-qmd.example).
Специфика потребителя — addendum `docs/ai/qmd-search-*.md`, не этот kit.

## Срез docs-layout (2026-08-27)

| Файл | Зачем |
| --- | --- |
| [docs-layout.md](docs-layout.md) | папки `docs/`, оглавления, куда агент пишет |
| [ADR-FORMAT.md](ADR-FORMAT.md) | ADR |
| [CONTEXT-FORMAT.md](CONTEXT-FORMAT.md) | словарь домена |
| [ROLES-FORMAT.md](ROLES-FORMAT.md) | бизнес-роли |
| [ANALYTICS-FORMAT.md](ANALYTICS-FORMAT.md) | штатка / люди / теневая автоматизация |
| [memory-format.md](memory-format.md) | записи `memory/` |
| [agent-session-lessons.md](agent-session-lessons.md) | memory → docs на close-chat |

Шаблоны оглавления: [templates/docs/](../../templates/docs/). Карта kit:
[docs/README.md](../README.md).

## Срез commit-hygiene (2026-09-04)

| Файл | Зачем |
| --- | --- |
| [commit-hygiene.md](commit-hygiene.md) | kit публичный: denylist внутренней инфры, allowlist плейсхолдеров, self-check перед коммитом |

Enforced cursor-rule: `cursor/rules/commit-hygiene.mdc` (`alwaysApply: true`).

## Срез mcp-config (2026-09-09)

| Файл | Зачем |
| --- | --- |
| [mcp-config.md](mcp-config.md) | `.mcp.json` канон: committable, `${VAR}` из `.env`; discovery; tools `mcp-call` |

Tool: `harness/tools/mcp-call/` (link-kit-tools). Потребитель: `.mcp.json`,
`.env` значения, `tools/mcp-call-examples/`.

## Срез pi-harness (2026-09-14)

| Файл | Зачем |
| --- | --- |
| [pi-harness.md](pi-harness.md) | pi: `.agents/skills`, `.pi/{skills,prompts,extensions}`, AGENTS.md, Zed/ACP |

Overlay: `harness/pi/` (`extensions/auto-session-title.ts`), линк —
`scripts/link-pi-roots.*` (в `bootstrap-kit`).

## Срез answer42 (2026-09-14)

| Файл | Зачем |
| --- | --- |
| [answer42.md](answer42.md) | UI 1С через клиент тестирования (Answer42): когда применять, цикл агента, безопасность |

Tool: `harness/tools/answer42/` (`answer42.ps1` / `answer42.sh`, `smoke.py`),
skill: `harness/cursor/skills/answer42-ui/`. Потребитель: `.env` ключи
`ANSWER42_*`, запись в `.mcp.json`, сервис на `127.0.0.1:9010`.

## Пока в репо потребителя

Печать, MCP, слоты, OpenSpec, `tools/`, skills. Индекс потребителя —
`docs/README.md` (не копировать kit blob).
