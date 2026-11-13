# Host deps kit (новый worktree)

Два слоя. Не путать.

| Слой | Что | Скрипт |
| --- | --- | --- |
| **Links** | junctions/symlink skills/tools (по `.kit.json` — core + выбранные стеки) | `bootstrap-kit` |
| **Host PATH** | git, node, python, rtk, rg + per-stack (`stack.json` → хук `deps-check`) | `init-kit-deps` |

Docker-слот (`org-agent-*`): node 20 + python + rtk уже в образе.
Голый Windows-worktree (42/`features`) — **нет**.

Спек-флоу (`specs/`, changes) — инструмент `harness/tools/kit-spec/kit_spec.py`,
host-dep не нужен (stdlib python). openspec CLI не используется.

## Вход

```bash
# только проверка (exit 1, если нет обязательных)
bash harness/scripts/init-kit-deps.sh .

# поставить недостающее (node / python / rtk / rg)
INSTALL=1 bash harness/scripts/init-kit-deps.sh .
```

```powershell
powershell -NoProfile -File harness/scripts/init-kit-deps.ps1 -ConsumerRoot .
powershell -NoProfile -File harness/scripts/init-kit-deps.ps1 -ConsumerRoot . -Install
```

Потом `bootstrap-kit` (links) + `python harness/tools/kit-layout/kit_layout.py verify .`.

## Никогда не запускать

| Команда | Почему |
| --- | --- |
| `openspec init` | openspec CLI не нужен и опасен: init пишет vendor-скиллы/команды сквозь junction-алиасы (`.claude`, `.pi`, `.agents` → `.cursor`). Scaffold — `kit_spec.py init`. |
| `rtk init` | Пишет инструкции в `CLAUDE.md`. У нас канон уже в AGENTS / `rtk-token-optimized-cmd.md`. |
| `rtk init -g` | Хук Claude Code. Cursor-агент и так ставит префикс `rtk`. Не часть kit. |

Каталог `specs/` приходит **из git** потребителя (merge `dev`) или scaffold
`python harness/tools/kit-spec/kit_spec.py init` (пишет только внутрь `specs/`).
Легаси `openspec/` → `kit_spec.py migrate-root --apply`.
Нет папки → merge ветки или `kit_spec.py init`, не `openspec init`.

## Обязательный PATH

| Инструмент | Зачем | Поставить |
| --- | --- | --- |
| git | worktree, submodule | вручную |
| Node.js 20 (min 18) | markdownlint | Win: `winget install OpenJS.NodeJS.LTS` |
| python | kit-инструменты (kit-layout, kit-spec, kit-agent), sandbox | Win: `winget install Python.Python.3.12` |
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
- `.gitattributes` у потребителя без `*.sh text eol=lf` — bootstrap
  предупреждает: иначе при `core.autocrlf=true` `.sh` чекаутятся с CRLF
- `python` / sandbox ([sandbox.md](sandbox.md))
- голый `bash` на Windows-хосте может резолвиться в
  `C:\Windows\System32\bash.exe` (WSL-лаунчер) раньше Git Bash —
  скрипты уходят в WSL (`/mnt/c`, FOREIGN-NS). Звать `"$BASH"`/полный
  путь к Git Bash или `.ps1`; `kit-doctor`/`bootstrap-kit` сами
  отказываются в WSL-сессии (обход — `WSL_ALLOW=1`)
- Docker Desktop (sandbox, слоты)
- `qmd`, `uv` / rlm-tools-bsl. Клиент агента: `QMD_CLIENT` / `QMD_MCP_URL`
  ([qmd-search.md](qmd-search.md), шаблон [env-qmd.example](../../../templates/env-qmd.example))
- `unzip` + `gh`/`curl` (скачивание стековых бинарей **в кэш хоста**, не в
  worktree — точная команда в доках стека и его `deps-check`)
- Windows Developer Mode (file `mklink` для `.mdc`; без прав — hardlink,
  в крайнем случае copy-fallback; учёт в `.kit/fallback.txt`)
- `harness/.git` file-gitdir — `fix-harness-gitdir`
- 42 HTTP git: GCM без TTY; fetch с `D:\git-data\repositories\team\proj.git`

## CONFLICT при раскладке — consumer-owned пути

`bootstrap-kit` и `kit_layout.py verify` не трогают чужое: не-link путь
по managed-пути (свой `.agents/skills`, свой файл поверх kit-ребёнка)
печатает `FAIL CONFLICT consumer-owned ...` и остаётся нетронутым —
kit заменяет только пути из `.kit/fallback.txt`. Разрешение — на выбор:

1. Переименовать/удалить consumer-путь и перезапустить `bootstrap-kit`.
2. Исключить ресурс целиком: `.kit.json "exclude_resources": [<id>, ...]`
   (id — `kit_layout.py print-config --json`, поле `resources`). Так
   потребитель оставляет за собой целевой каталог (`.agents/skills`,
   `.claude/skills`) без вилки `layout.json`.
3. Отдельного ребёнка внутри ресурса — имя в `.kit/local-*.txt`.

Legacy link-скрипты (`LEGACY_LINKS=1`) — `SKIP consumer-owned`,
перезапись только по явному `-ReplaceCopies` / `KIT_REPLACE_COPIES=1`.
Подробности: `harness/README.md`, секции «`.kit.json`» и «Consumer-owned
пути — CONFLICT».

## Порядок на новом worktree (42)

1. Починить gitdir, если `not a git repository: harness/../.git/modules/harness`.
2. Merge канон-ветки (чтобы был `specs/` в git).
3. `init-kit-deps -Install` — **не** `openspec init`.
4. `bootstrap-kit` → `kit_layout.py verify`; `kit_spec.py init`, если `specs/` нет.
5. Стековые инструменты — по докам выбранных стеков (их `deps-check`
   показывает, чего не хватает; бинари ставятся один раз на хост, не в
   worktree).
6. Reload Window Cursor.

## deps-check хук стека

`deps` из `stack.json` диспетчеризует `init-kit-deps`: id с core-функцией
`dep_<d>` выполняется один раз (дедуп между стеками), остальные —
`unhandled`. При непустом `unhandled` вызывается
`stacks/<s>/deps-check.{sh,ps1}` (оба файла, `.ps1` — ASCII): env
`CONSUMER_ROOT`, `HARNESS_ROOT`, `INSTALL`, `STACK_DEPS` (id через пробел),
cwd — корень потребителя; stdout — статусы `dep_*`; `exit 0` при OK и
WARN-only, `!= 0` → fail. Что проверяет хук и как ставить недостающее —
в `docs/ai` соответствующего стека.
