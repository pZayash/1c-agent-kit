# bsl-check / BSL Language Server

Статический анализ `.bsl`: обёртка [`check-bsl.py`](check-bsl.py) над
[BSL Language Server](https://github.com/1c-syntax/bsl-language-server).

Навык агента: [`bsl-check`](../../cursor/skills/bsl-check/SKILL.md).

## Бинарник не в git

В kit коммитятся только скрипт, пин, JSON-конфиг. Runtime (~500 МБ win+nix)
живёт в **кэше хоста**, не в worktree. Скачивает
[`update-bsl-language-server.sh`](update-bsl-language-server.sh).
`bootstrap-kit` / `init-kit-deps` **не** качают.

| Файл/каталог | В git? |
| --- | --- |
| `check-bsl.py`, `update-bsl-language-server.sh`, `bsl-language-server.json` | да |
| [`BSLLS_VERSION`](BSLLS_VERSION) (пин тега без `v`) | да |
| runtime в `$KIT_BSLLS_ROOT/<пин>/` | нет |
| sidecar `exe` / `app/` / `runtime/` / `bsl-language-server-linux/` | нет (fallback) |

Junction потребителя: `tools/bsl-check` → `harness/tools/bsl-check` (скрипты).

## Кэш и резолвер

Порядок в `check-bsl.py`: `BSL_LANGUAGE_SERVER` / `--bsl-ls` →
`$KIT_BSLLS_ROOT/<пин>/` → sidecar рядом со скриптом.

- Без `KIT_BSLLS_ROOT`: `%LOCALAPPDATA%/1c-agent-kit/bslls` (Win),
  `~/.cache/1c-agent-kit/bslls` (Linux).
- SRV01 (несколько worktree): User env
  `KIT_BSLLS_ROOT=D:\tools\bslls` (не `.env` репо).
- Layout пина: `bsl-language-server.exe`, `app/`, `runtime/`,
  `bsl-language-server-linux/`.
- Чужой подкаталог кэша (другой пин) **не** подставляется.

Печать пути без запуска BSLLS:

```bash
python harness/tools/bsl-check/check-bsl.py --which
```

Нет лаунчера → exit 2 и рецепт. Sidecar — последний fallback; **новые**
установки туда не класть (только `--local`).

## Новый хост / другой ПК

После clone + `git submodule update --init` + `bootstrap-kit`:

```bash
# один раз на (хост × пин), не на каждый worktree
bash harness/tools/bsl-check/update-bsl-language-server.sh
```

Без флагов = версия из `BSLLS_VERSION` **в кэш**. **Не** передавай `--latest`
на чужом хосте: это бамп пина, не «поставить как у всех».

Sidecar (слот-сборка образа / аварийно):

```bash
bash harness/tools/bsl-check/update-bsl-language-server.sh --local
```

Нужно на **хосте** (не через `sandbox/run.sh`):

- `unzip` (Git for Windows; Linux: `apt install unzip`)
- `gh` или `curl`
- сеть до GitHub (`1c-syntax/bsl-language-server` releases)

Allowlist Cursor (чтобы агент не ждал approve):

```json
"Bash(bash tools/bsl-check/update-bsl-language-server.sh:*)"
```

## Бамп версии (менять пин)

Релизы: <https://github.com/1c-syntax/bsl-language-server/releases>

```bash
# конкретный тег, в т.ч. pre-release (RC)
bash harness/tools/bsl-check/update-bsl-language-server.sh --version 1.1.0-rc.3

# GitHub Latest = stable, RC пропускает
bash harness/tools/bsl-check/update-bsl-language-server.sh --latest
```

Потом:

1. Smoke (см. ниже).
2. Commit в **kit** (`harness/`): только `BSLLS_VERSION` (+ скрипт/дока). Не
   бинарники.
3. В потребителе: bump gitlink `harness`.
4. Другие хосты: `git pull` → снова скрипт **без** флагов (докачает новый пин
   в кэш).
5. Agent-slot: образ `COPY` linux-дерево на **build**. После бампа — rebuild
   слотов. До follow-up Dockerfile: `--local` или sidecar на машине сборки.

## Проверка что работает

```bash
python harness/tools/bsl-check/check-bsl.py --which
bash tools/sandbox/run.sh python harness/tools/bsl-check/check-bsl.py --min-severity Error conf/path/Module.bsl
```

`--help` и `--which` не запускают BSLLS. Нужен прогон по `.bsl`. В слоте
(`AGENT_SLOT=true`): `python3 tools/bsl-check/check-bsl.py …` напрямую
(`BSL_LANGUAGE_SERVER` в образе).

**Windows + Docker sandbox:** `tools/bsl-check` — junction с абсолютным
Windows-путём. Docker Desktop превращает его в `/mnt/host/c/...`, этого mount
в `agent-sandbox` нет → `can't open file '.../tools/bsl-check/check-bsl.py'`.
Обход: путь `harness/tools/bsl-check/check-bsl.py`. `check-all.py` уже
предпочитает его. Кэш вне bind-mount sandbox не видит — тогда
`BSL_LANGUAGE_SERVER` в контейнер или sidecar `--local`. На 42 sandbox не
гоняют: `python harness/tools/bsl-check/check-bsl.py` на хосте.

## Конфиг правил

[`bsl-language-server.json`](bsl-language-server.json). Схема:
<https://1c-syntax.github.io/bsl-language-server/configuration/schema.json>
