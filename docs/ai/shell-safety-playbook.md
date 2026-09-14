# Безопасный протокол shell

## Зачем

Этот плейбук снижает типовые ошибки при вызове shell-команд в проекте.
Используй как короткий чеклист перед каждым вызовом `Shell`.

Allowlist (автоподтверждение команд): [agent-command-allowlist.md](agent-command-allowlist.md).

## Базовые правила

- Не использовать `cd ... &&` в командах shell.
- Не использовать `git -C ...`.
- Использовать относительные пути от корня проекта.
- Для поддерживаемых нативных команд ставить префикс `rtk`.
- Для `pnpm`, `npm`, `npx` не использовать `rtk`.
- Команда вне `rtk` с неизвестно большим выводом — byte-cap (`head -c` /
  `tail -c`), не лимит строк. См. § Byte-cap.
- **Python:** не вызывать `python`, `python3`, `py`, `pip` на хосте — только
  `bash tools/sandbox/run.sh python …` / `… pip …` — **обязательно**
  ([sandbox.md](sandbox.md), раздел «Почему так»).
- **`run.sh` не в цепочке:** не клеить `&&` / `;` с другими командами на хосте —
  allowlist снова спросит approve. Отдельные Shell-вызовы или
  `run.sh bash -c '…'` ([sandbox.md](sandbox.md)).

## Поддерживаемые `rtk` команды

В первую очередь:

- `git`
- `gh`
- `ls`
- `tree`
- `find`
- `grep`

Также применяй `rtk` для других поддерживаемых нативных утилит по правилам проекта.

## Byte-cap неизвестного вывода

`rtk` уже сжимает `git`/`gh`/`ls`/`grep`/`find`. Для **остальных** команд с
неизвестно большим stdout — лимит **байт**, не строк. `head -n` небезопасен:
одна жирная строка (XML формы, JSONL) зальёт контекст.

Паттерн: [Austin1serb/agents-md](https://github.com/Austin1serb/agents-md).

```bash
COMMAND 2>&1 | head -c 4000
COMMAND 2>&1 | tail -c 4000
```

Примеры:

```bash
rg -n -m 20 'яя_Печать_' conf 2>&1 | head -c 4000
bash -o pipefail -c 'bash check-changed.sh --strict 2>&1 | tail -c 4000'
```

Не клеить кап поверх `rtk`. Не резать skill / `AGENTS.md` / docs / policy
(читай файл целиком, если он не аномально огромный). Кап мало → сузить
команду, потом поднять кап.

Exit code нужен (тест/чек упал?) — не через pipe напрямую (`head` даст 0):

```bash
tmp="$(mktemp)"
COMMAND >"$tmp" 2>&1
status=$?
tail -c 4000 "$tmp"
rm -f "$tmp"
exit "$status"
```

## Инструменты поиска и чтения

- Для поиска по коду сначала использовать `qmd` или узкий `rg` по пути.
- Не делать широкие сканы без необходимости.
- Для чтения файлов в агенте использовать файловые инструменты, а не `cat`.

## Windows, WSL и кириллица

- Bash в WSL обычно корректно показывает кириллицу.
- В PowerShell перед командами ставить UTF-8:

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
```

- Для CMD запускать через PowerShell и включать `chcp 65001`.

## Git-безопасность

- Не делать коммит без явного запроса пользователя.
- Не выполнять `reset --hard`, `checkout --`, force push без явного разрешения.
- Не использовать `--no-verify` и похожие обходы без явного запроса.
- После значимых изменений проверять состояние репозитория.

## Долгие и фоновые команды

- Для ожидаемо долгих команд заранее ставить достаточный `block_until_ms`.
- Для серверов и вотчеров запускать в фоне (`block_until_ms: 0`).
- После фонового старта делать один smoke-check, что процесс поднялся.

## Перед созданием файлов и папок

- Сначала проверить, что родительский путь существует и корректен.
- Только потом создавать директории и файлы.

## Правильно и неправильно

Неправильно:

```bash
cd "c:/repo" && git status
git -C "c:/repo" log --oneline -30
rtk npx markdownlint docs/ai/shell-safety-playbook.md
```

Правильно:

```bash
rtk git status
rtk git log --oneline -30
npx markdownlint docs/ai/shell-safety-playbook.md
```

Неправильно:

```bash
grep -n "Строка" /c/path/to/repo/conf/Configuration.xml
```

Правильно:

```bash
rtk grep -n "Строка" conf/Configuration.xml
```

Неправильно:

```bash
python3 tools/bsl-check/check-bsl.py conf/CommonModules/яя_/Ext/Module.bsl
```

Правильно:

```bash
bash tools/sandbox/run.sh python tools/bsl-check/check-bsl.py conf/CommonModules/яя_/Ext/Module.bsl
```

## Мини-чеклист перед shell-вызовом

- Нет `cd` в начале команды.
- Нет `git -C`.
- Путь относительный от корня проекта.
- Для поддерживаемой команды добавлен `rtk`.
- Для `npm/pnpm/npx` `rtk` не используется.
- Нет `rtk` и вывод может быть большим → `| head -c 4000` (не `head -n`).
- Python/pip — только через `bash tools/sandbox/run.sh`, не `python3` на хосте.
- Нет `run.sh … && …` / `;` с другими командами на хосте.
- Кодировка PowerShell учтена, если используется PowerShell.
- Команда не разрушительная или есть явное разрешение.
- Для долгой команды выставлен корректный `block_until_ms`.

## Частые нарушения

- Забыт `rtk` перед `git` или `gh`.
- `head -n` вместо `head -c` на неизвестном выводе.
- Использован абсолютный путь вместо относительного.
- Добавлен `cd` в начале команды.
- Запущен второй dev-сервер без проверки уже работающего процесса.
