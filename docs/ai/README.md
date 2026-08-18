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
| [git-workflow.md](git-workflow.md) | общие правила git для агентов |

`tools/sandbox/` и `.cursor/cli.json` — в потребителе. Пилот КПСР: addendum
`docs/ai/git-workflow-kpsr.md` (не в kit).

## Срез 2c (2026-08-18)

| Файл | Зачем |
| --- | --- |
| [specs/form-dsl-spec.md](specs/form-dsl-spec.md) | Form JSON DSL |
| [specs/meta-dsl-spec.md](specs/meta-dsl-spec.md) | Meta JSON DSL |
| [specs/skd-dsl-spec.md](specs/skd-dsl-spec.md) | SKD JSON DSL |
| [specs/mxl-dsl-spec.md](specs/mxl-dsl-spec.md) | MXL JSON DSL |
| [specs/role-dsl-spec.md](specs/role-dsl-spec.md) | Role JSON DSL |

Скиллы `*-compile` — в `.cursor/skills/` потребителя. web/build/autotest — ещё
в потребителе.

## Пока в репо потребителя

`code-standards`, `object-conventions`, печать, MCP, слоты, OpenSpec,
`web-spec` / `build-spec` / autotest, `tools/`, skills. Следующий срез —
**3** (`code-standards` после выноса `яя_`-dialect).
