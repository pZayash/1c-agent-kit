# bsl-check / BSL Language Server

Статический анализ `.bsl`: обёртка [`check-bsl.py`](check-bsl.py) над
[BSL Language Server](https://github.com/1c-syntax/bsl-language-server).

Навык агента: [`bsl-check`](../../cursor/skills/bsl-check/SKILL.md).

## Бинарник не в git

В kit коммитятся только скрипт, пин, JSON-конфиг. Сборки (~160 МБ win + ~165 МБ
nix) качает [`update-bsl-language-server.sh`](update-bsl-language-server.sh).

| Файл/каталог | В git? |
| --- | --- |
| `check-bsl.py`, `update-bsl-language-server.sh`, `bsl-language-server.json` | да |
| [`BSLLS_VERSION`](BSLLS_VERSION) (пин тега без `v`) | да |
| `bsl-language-server.exe`, `app/`, `runtime/` (Windows, JRE внутри) | нет |
| `bsl-language-server-linux/` (для Docker sandbox и agent-slot) | нет |

Junction потребителя: `tools/bsl-check` → `harness/tools/bsl-check`.

## Новый хост / другой ПК / новый worktree

После clone + `git submodule update --init` + `bootstrap-kit` / `link-kit-tools`:

```bash
bash tools/bsl-check/update-bsl-language-server.sh
```

Без флагов = версия из `BSLLS_VERSION`. **Не** передавай `--latest` на чужом
хосте: это бамп пина, не «поставить как у всех».

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
bash tools/bsl-check/update-bsl-language-server.sh --version 1.1.0-rc.3

# GitHub Latest = stable, RC пропускает
bash tools/bsl-check/update-bsl-language-server.sh --latest
```

Потом:

1. Smoke (см. ниже).
2. Commit в **kit** (`harness/`): только `BSLLS_VERSION` (+ скрипт/дока). Не
   бинарники.
3. В потребителе: bump gitlink `harness`.
4. Другие хосты: `git pull` → снова скрипт **без** флагов.
5. Agent-slot: образ `COPY` linux-дерево на **build**. После бампа — rebuild
   слотов. Хост-sandbox bind-mount'ит worktree — rebuild образа sandbox не нужен.

## Проверка что работает

```bash
bash tools/sandbox/run.sh python harness/tools/bsl-check/check-bsl.py --min-severity Error conf/path/Module.bsl
```

`--help` не запускает BSLLS. Нужен прогон по `.bsl`. В слоте (`AGENT_SLOT=true`):
`python3 tools/bsl-check/check-bsl.py …` напрямую (слот — Linux, symlink живой).

**Windows + Docker sandbox:** `tools/bsl-check` — junction с абсолютным Windows-путём.
Docker Desktop превращает его в `/mnt/host/c/...`, этого mount в `agent-sandbox`
нет → `can't open file '.../tools/bsl-check/check-bsl.py'`. Обход: путь
`harness/tools/bsl-check/check-bsl.py` (реальный каталог в bind-mount).
`check-all.py` уже предпочитает его.

Если `bsl-language-server not found` — скрипт обновления не гоняли на этом хосте.

## Конфиг правил

[`bsl-language-server.json`](bsl-language-server.json). Схема:
<https://1c-syntax.github.io/bsl-language-server/configuration/schema.json>
