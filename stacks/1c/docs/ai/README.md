# docs/ai в kit — стек `1c`

Правила агентов стека 1C:Enterprise. Стеко-нейтральные —
[core/docs/ai/README.md](../../../../core/docs/ai/README.md).
Правка — здесь, потом Promote (commit в submodule → bump SHA).

## Срез 1 (2026-08-17)

| Файл | Зачем |
| --- | --- |
| [platform-pitfalls.md](platform-pitfalls.md) | ловушки платформы 1С |

## Срез 2 (2026-08-18)

| Файл | Зачем |
| --- | --- |
| [query-standards.md](query-standards.md) | роутер запросов 1С |
| [регистры.md](регистры.md) | проектирование регистров |
| [скд.md](скд.md) | проектирование СКД |
| [async-methods.md](async-methods.md) | `Асинх` / `Ждать` / `Обещание` |
| [locks-and-transactions.md](locks-and-transactions.md) | блокировки, транзакции |
| [infobase-exclusive-access.md](infobase-exclusive-access.md) | кто держит базу (Apache/IIS/ibsrv/клиент) |
| [metadata-xml-load-pitfalls.md](metadata-xml-load-pitfalls.md) | ловушки LoadConfigFromFiles |
| [grep-ast.md](grep-ast.md) | поиск с контекстом AST |
| [1c-specs-index.md](1c-specs-index.md) | индекс XML-спек платформы |
| [specs/1c-*-spec.md](specs/) | спеки формата дампа (11 файлов) |

В пилоте на старых путях `docs/ai/<имя>.md` — заглушка со ссылкой сюда.

## Срез 3w (workflow, 2026-08-19)

| Файл | Зачем |
| --- | --- |
| [load-config-to-dev.md](load-config-to-dev.md) | load conf в dev-ИБ |
| [ibcmd-cli.md](ibcmd-cli.md) | ibcmd: хелп, креды, кодировка, import/export |

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

Пилот: `object-conventions-org.md`.

## Срез answer42 (2026-09-30)

| Файл | Зачем |
| --- | --- |
| [answer42.md](answer42.md) | UI 1С через клиент тестирования (Answer42): когда применять, цикл агента, безопасность |

Tool: `harness/stacks/1c/tools/answer42/` (`answer42.ps1` / `answer42.sh`, `smoke.py`,
`version_check.py`), skill: `harness/stacks/1c/cursor/skills/answer42-ui/`. Потребитель:
`.env` ключи `ANSWER42_*`, запись в `.mcp.json`, сервис на `127.0.0.1:9010`.
Минимум `answer42>=0.5.13`; свежесть сборки — `answer42.sh check` (и строка
`version` в `status`), диагностика в `kit-doctor` (проверка 12).

## Срез integrator

| Файл | Зачем |
| --- | --- |
| [agent-integrator.md](agent-integrator.md) | дочка-интегратор: сведение веток, загрузка в dev-ИБ, доказательство применения |
