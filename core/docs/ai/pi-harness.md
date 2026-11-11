# pi как harness kit

[pi](https://pi.dev) — терминальный агент; у потребителя kit используется как
альтернатива Cursor / Claude Code. Контекст проекта pi читает из `AGENTS.md`
(и `CLAUDE.md`).

## Что pi читает из kit

| Ресурс | Путь у потребителя | Откуда |
| --- | --- | --- |
| Навыки | `.agents/skills` | junction на `.cursor/skills` (`link-editor-roots`) |
| Навыки (относительные ссылки из команд) | `.pi/skills` | junction на `.cursor/skills` (`link-pi-roots`) |
| Prompt templates (`/имя`) | `.pi/prompts` | junction на `.cursor/commands` (`link-pi-roots`) |
| Extensions | `.pi/extensions` | junction на `harness/pi/extensions` (`link-pi-roots`) |
| Контекст | `AGENTS.md` | файл потребителя |
| MCP | — | через `tools/mcp-call/mcp-call.sh` ([mcp-config.md](mcp-config.md)) |

Линки ставит `bootstrap-kit` (шаг `link-pi-roots`), проверяет
`verify-kit-links`. Вручную:

```bash
DRY_RUN=1 bash harness/scripts/link-pi-roots.sh .
bash harness/scripts/link-pi-roots.sh .
```

```powershell
powershell -NoProfile -File harness/scripts/link-pi-roots.ps1 -ConsumerRoot .
```

## Почему так

- pi сам находит `.agents/skills` (cwd и предки до git root), поэтому навыки
  cc-1c и overlay доступны без правок. pi допускает несовпадение `name` навыка
  и имени каталога (Agent Skills standard) — общий каталог kit подходит.
- Prompt templates pi читает только из `.pi/prompts`, поэтому
  `.cursor/commands` линкуется туда.
- `.pi/skills` нужен, чтобы относительные ссылки `../skills/<name>/SKILL.md`
  внутри команд разрешались: pi открывает файл по пути `.pi/prompts/<name>.md`,
  и `../skills` ведёт в `.pi/skills`. Дубли навыков pi схлопывает по
  каноническому пути.

## Локальные ресурсы потребителя

- Личные навыки / команды / расширения — в `~/.pi/agent/{skills,prompts,extensions}/`.
- Проектные pi-only ресурсы — через `.pi/settings.json` (`skills`, `prompts`,
  `extensions` — массивы путей): каталоги `.pi/{skills,prompts,extensions}`
  заняты junction'ами kit.
- `.pi/settings.json` — локальное состояние pi; коммитить только осознанно
  (пути не должны быть машинозависимыми).

## Zed / ACP (опционально)

Zed подключает pi через `pi-acp` (RPC). Имя сессии pi (`auto-session-title`)
попадает в открытый чат Zed только при наличии в `pi-acp` обработки события
`session_info_changed` → ACP `session_info_update`. Если релиз `pi-acp` её ещё
не содержит:

```bash
node harness/pi/scripts/patch-pi-acp-session-title.mjs
```

Скрипт идемпотентен, делает `.orig`-бэкап и no-op, если правка уже есть.
Правка теряется при обновлении `pi-acp` — запустить снова.

## Ловушки

- `.pi/extensions` — junction на kit: своё расширение туда не положить
  (только `~/.pi/agent/extensions/` или `.pi/settings.json`).
- Project trust: pi спрашивает доверие проекта, где есть `.agents/skills` и
  `.pi`. Неинтерактивно — `pi -a` / `--approve`.
- `enableSkillCommands` (default `true`) — навыки как `/skill:name`.
- `.cursor/rules/*.mdc` pi не читает. Always-on правила kit (caveman,
  commit-hygiene) для pi переносите в `AGENTS.md` потребителя.
