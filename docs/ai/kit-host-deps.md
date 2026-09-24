# Host deps kit (новый worktree)

Два слоя. Не путать.

| Слой | Что | Скрипт |
| --- | --- | --- |
| **Links** | junctions/symlink skills/tools | `bootstrap-kit` |
| **Host PATH** | git, node, openspec CLI, rtk, rg | `init-kit-deps` |

Docker-слот (`org-agent-*`): node 20 + `@fission-ai/openspec@1.2.0` + rtk
уже в образе. Голый Windows-worktree (42/`features`) — **нет**.

## Вход

```bash
# только проверка (exit 1, если нет обязательных)
bash harness/scripts/init-kit-deps.sh .

# поставить недостающее (node / openspec CLI / rtk / rg)
INSTALL=1 bash harness/scripts/init-kit-deps.sh .
```

```powershell
powershell -NoProfile -File harness/scripts/init-kit-deps.ps1 -ConsumerRoot .
powershell -NoProfile -File harness/scripts/init-kit-deps.ps1 -ConsumerRoot . -Install
```

Потом `bootstrap-kit` (links) + `verify-kit-links`.

## Никогда не запускать

| Команда | Почему |
| --- | --- |
| `openspec init` | Дефолтный `openspec/`, skills, AGENTS/CLAUDE. У нас свои. Init затрёт. |
| `rtk init` | Пишет инструкции в `CLAUDE.md`. У нас канон уже в AGENTS / `rtk-token-optimized-cmd.md`. |
| `rtk init -g` | Хук Claude Code. Cursor-агент и так ставит префикс `rtk`. Не часть kit. |

Каталог `openspec/` приходит **из git** потребителя (merge `dev`), не из CLI init.
Нет папки → merge ветки, не `openspec init`.

CLI: `npm install -g @fission-ai/openspec@1.2.0` (пин как в
`tools/sandbox/Dockerfile` / agent-container). `openspec` **без** `rtk`
(npm-shim → `[rtk: program not found]`).

## Обязательный PATH

| Инструмент | Зачем | Поставить |
| --- | --- | --- |
| git | worktree, submodule | вручную |
| Node.js 20 (min 18) | openspec, markdownlint | Win: `winget install OpenJS.NodeJS.LTS` |
| openspec CLI 1.2.x | skills `openspec-*` | `npm i -g @fission-ai/openspec@1.2.0` |
| rtk | префикс `git`/`docker` у агента | https://github.com/rtk-ai/rtk — оператор ставит сам |
| rg | фильтры rtk + поиск агента | Win: `winget install BurntSushi.ripgrep.MSVC` |

После winget — **новое** окно терминала (PATH).

## PowerShell не в PATH (Windows)

`.sh`-обёртки kit на Windows не зовут `powershell.exe` вслепую, а резолвят
интерпретатор: PATH → `%SystemRoot%\System32\WindowsPowerShell\v1.0` →
`/c/Windows/...` → `pwsh`. В урезанном PATH (агентный/GUI-терминал Zed,
sandbox) печатается `WARN: powershell.exe не в PATH - использую <путь>` —
это норма, скрипт работает. Если не найден ни один вариант, обёртка делает
`exit 1` с `ERROR: PowerShell не найден`; тогда — запуск `.ps1` из PowerShell.

## Warn (скрипт не ставит)

- `.env` в корне потребителя
- `python` / sandbox (`docs/ai/sandbox.md`)
- Docker Desktop (sandbox, слоты)
- `qmd`, `uv` / rlm-tools-bsl. Клиент агента: `QMD_CLIENT` / `QMD_MCP_URL`
  ([qmd-search.md](qmd-search.md), шаблон [env-qmd.example](../../templates/env-qmd.example))
- `unzip` + `gh`/`curl` (скачать BSLLS **в кэш хоста**, не в worktree:
  `bash harness/tools/bsl-check/update-bsl-language-server.sh`)
- Windows Developer Mode (file `mklink` для `.mdc`; без прав — hardlink,
  в крайнем случае copy-fallback; учёт в `kit-fallback.txt`)
- `harness/.git` file-gitdir — `fix-harness-gitdir`
- 42 HTTP git: GCM без TTY; fetch с `D:\git-data\repositories\team\proj.git`

## Порядок на новом worktree (42)

1. Починить gitdir, если `not a git repository: harness/../.git/modules/harness`.
2. Merge канон-ветки (чтобы был `openspec/` в git).
3. `init-kit-deps -Install` — **не** `openspec init`.
4. `bootstrap-kit` → `verify-kit-links`.
5. BSLLS: один раз на хост (не на worktree)
   `bash harness/tools/bsl-check/update-bsl-language-server.sh` (без `--latest`).
   На 42 сначала User env `KIT_BSLLS_ROOT=D:\tools\bslls`.
   Проверка: `python harness/tools/bsl-check/check-bsl.py --which`.
6. Reload Window Cursor.
