# docs/ai в kit — core

Общие правила агентов, стеко-нейтральные. Без специфики потребителя
(`яя_`, печать, MCP CFE) и без специфики стека `1c` — она в
`stacks/<id>/docs/ai/README.md`.
Правка — здесь, потом Promote (commit в submodule → bump SHA).

## Срез 1 (2026-08-17)

| Файл | Зачем |
| --- | --- |
| [markdown-formatting.md](markdown-formatting.md) | markdownlint, code fences |
| [project-file-links.md](project-file-links.md) | кликабельные пути, `#L` |
| [rtk-token-optimized-cmd.md](rtk-token-optimized-cmd.md) | `rtk` |
| [shell-safety-playbook.md](shell-safety-playbook.md) | shell, byte-cap |

## Срез 2b (2026-08-18)

| Файл | Зачем |
| --- | --- |
| [sandbox.md](sandbox.md) | Docker-песочница, `run.sh` |
| [agent-command-allowlist.md](agent-command-allowlist.md) | allowlist Cursor/Claude |
| [git-workflow.md](git-workflow.md) | git для агентов; регистр путей NTFS |

Скиллы: `harness/core/cursor/skills/` (срез B). Tools:
`harness/core/tools/{sandbox,git-partial-stage.py}` +
`harness/stacks/1c/tools/{bsl-check,load-changed-files}`.

`tools/sandbox/` и `.cursor/cli.json` — junction/copy у потребителя. Пилот ORG: addendum
`docs/ai/git-workflow-org.md` (не в kit).

## Срез 3b (2026-08-18)

| Файл | Зачем |
| --- | --- |
| [logging-strategy.md](logging-strategy.md) | когда логировать, уровни, `Попытка/Исключение` |

Пилот: `logging-strategy-org.md`.

## Срез host-deps (2026-08-20+)

| Файл | Зачем |
| --- | --- |
| [kit-host-deps.md](kit-host-deps.md) | node/openspec/rtk на worktree; **не** `openspec init` |

## Срез qmd-client (2026-09-01)

| Файл | Зачем |
| --- | --- |
| [qmd-search.md](qmd-search.md) | гибридный поиск; `QMD_CLIENT` = off / cli / mcp |
| [qmd-query-syntax.md](qmd-query-syntax.md) | `lex:` / `vec:` / `hyde:` |

Ключи `.env`: [templates/env-qmd.example](../../../templates/env-qmd.example).
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

Шаблоны оглавления: [templates/docs/](../../../templates/docs/). Карта kit:
[docs/README.md](../../../docs/README.md).

## Срез commit-hygiene (2026-09-04)

| Файл | Зачем |
| --- | --- |
| [commit-hygiene.md](commit-hygiene.md) | kit публичный: denylist внутренней инфры, allowlist плейсхолдеров, self-check перед коммитом |

Enforced cursor-rule: `core/cursor/rules/commit-hygiene.mdc` (`alwaysApply: true`).

## Срез mcp-config (2026-09-09)

| Файл | Зачем |
| --- | --- |
| [mcp-config.md](mcp-config.md) | `.mcp.json` канон: committable, `${VAR}` из `.env`; discovery; tools `mcp-call` |

Tool: `harness/stacks/1c/tools/mcp-call/` (link-kit-tools). Потребитель: `.mcp.json`,
`.env` значения, `tools/mcp-call-examples/`.

## Срез pi-harness (2026-09-14)

| Файл | Зачем |
| --- | --- |
| [pi-harness.md](pi-harness.md) | pi: `.agents/skills`, `.pi/{skills,prompts,extensions}`, AGENTS.md, Zed/ACP |

Overlay: `harness/pi/` (`extensions/auto-session-title.ts`), линк —
`scripts/link-pi-roots.*` (в `bootstrap-kit`).

## Срез orchestrator (2026-09-25)

| Файл | Зачем |
| --- | --- |
| [agent-orchestration.md](agent-orchestration.md) | тред-оркестратор и дочерние треды: роли, брифы, спавн, сторож, приёмка, механика bb |

Скиллы: [orchestrator](../../cursor/skills/orchestrator/SKILL.md),
[orchestrated-child](../../cursor/skills/orchestrated-child/SKILL.md).
Сторож залипших дочек — пока у потребителя; promote после боевого срабатывания.

## Пока в репо потребителя

Печать, MCP, слоты, OpenSpec, `tools/`, skills. Индекс потребителя —
`docs/README.md` (не копировать kit blob).
