# answer42 — UI-driver MCP для 1С

Локальный MCP-сервер [Answer42](https://gitlab.com/platform42/answer42-mcp):
управление UI **1С:Предприятия** через клиент тестирования
(`1cv8c /TESTMANAGER` + `/TESTCLIENT`). Поднимается как StreamableHTTP-сервис,
вызовы — через [`tools/mcp-call`](../mcp-call/README.md).

Назначение: проверить живую форму (открыть, кликнуть, заполнить, прочитать
таблицу/динамический список, снять скриншот) там, где веб-клиент (`/web-test`)
не даёт нужного сценария или нужен именно клиент тестирования.

## Требования

- Python 3.11–3.13 (проверено на 3.11), пакет `answer42` с PyPI.
- 1С:Предприятие **8.3.27+** или **8.5+**; нужны `1cv8c` и `ibcmd`, желателен
  `ibsrv` (без него Answer42 уходит в `file-direct`).
- Windows — **интерактивная desktop-сессия** пользователя: Answer42 запускает
  окна `1cv8c`. Служба и заблокированный RDP-сеанс не подходят.
- Linux — X11 или Xvfb (`xvfb`, `wmctrl`, `xdotool`), extra
  `linux-window-control`; для `answer42.sh` — `python3` и `curl` в PATH.

## Установка

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 install
```

Linux:

```bash
bash tools/answer42/answer42.sh install          # PyPI-сборка
bash tools/answer42/answer42.sh install --fork   # editable-сборка из форка (ANSWER42_FORK_DIR)
```

Windows-вариант создаёт `.venv-answer42` в корне проекта-потребителя и ставит
`answer42[screenshot,windows-window-control]`; Linux-вариант — то же с
`[screenshot,linux-window-control]`. Каталог venv обязан быть в
`.gitignore` потребителя.

`answer42.sh` работает и в **Git Bash на Windows**: Windows-пути из `.env`
нормализуются, сервис запускается через `Start-Process` (фоновый процесс MSYS
не переживает выход шелла), а `stop` добивает владельца порта через `taskkill`.
Канонический вариант для Windows — всё же `answer42.ps1`.

### Сборка из форка

Если нужны локальные патчи, ставится не PyPI-релиз, а форк
(`<https://github.com/pZayash/answer42-mcp>`, ветка `fork-patches`; ветка `beta` —
зеркало upstream). Мотив и состав патчей — `FORK.md` в чекауте форка.

Важно: чек-аут и venv должны лежать в **латинском пути** — кириллица в пути
ломает editable-установку (`.pth` с не-ASCII путём не подхватывается, `import
mcp_1c` падает) на Windows.

Linux/Git Bash — одной командой (`ANSWER42_FORK_DIR` в `.env`; делает venv,
editable-установку и локальную сборку CF из XML):

```bash
bash tools/answer42/answer42.sh install --fork
```

Вручную (любая ОС):

```bash
# чекаут: C:\GitHub\pzayash\answer42-mcp
python -m venv .venv
.venv/Scripts/python.exe -m pip install -e ".[screenshot,windows-window-control]"

# в editable-сборке нет готовых CF (их инжектит CI) — собираем из XML локально,
# иначе start_session не найдёт CF при рабочем каталоге вне чекаута
.venv/Scripts/python.exe scripts/build_cf.py src/cf src/mcp_1c/assets/MCPTestManager.cf
.venv/Scripts/python.exe scripts/build_cf.py src/client_cf src/mcp_1c/assets/MCPTestClient.cf
```

Затем `ANSWER42_BIN` в `.env` потребителя указывает на бинарь venv форка;
обновление с upstream — действием `update` (см. ниже), вручную — так:

```bash
git fetch upstream --tags && git switch fork-patches && git rebase <новый-тег>
git push --force-with-lease origin fork-patches
```

Проверка патча: ответ на заведомо битую ссылку
(`open_navigation_link "e1cib/list/Catalog.Missing"`) должен содержать текст
ошибки 1С, а не голое `Error executing tool ...`.

## Ключи `.env`

| Ключ | Зачем |
| --- | --- |
| `ANSWER42_MCP_URL` | endpoint сервера, напр. `http://127.0.0.1:9010/mcp` (порт берётся отсюда) |
| `ANSWER42_ACCOUNT_ID` | namespace credential-стора; **должен совпадать** с account в `~/.answer42-credentials.json` |
| `ANSWER42_TOKEN` | Bearer для StreamableHTTP; только в `.env` |
| `ANSWER42_EXTRA_ARGS` | доп. аргументы сервера; по умолчанию `--disable-rag` — RAG задерживает готовность |
| `ANSWER42_BIN` | опционально: путь к `answer42(.exe)` — напр. бинарь venv форк-сборки |

Схема ключей — [`.env.example`](../../.env.example) потребителя.

## Логины баз

Answer42 берёт учётку из локального файла **вне репозитория**
(`~/.answer42-credentials.json`, формат v2 = `accounts.<account_id>.entries[]`)
или из `ONEC_MCP_CREDENTIALS_FILE`. В аргументах tool-call логин/пароль не
передавать: они попадают в историю чата.

Пустой пароль допустим: `"password": ""`.

## Запуск, остановка, статус

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 start
powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 status
powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 stop
```

Linux (и Git Bash на Windows) — то же через `.sh`:

```bash
bash tools/answer42/answer42.sh start|status|stop|restart|smoke
```

`start` проверяет только то, что процесс поднял порт, и возвращает управление;
готовность эндпоинта (она наступает позже — инициализация Answer42) проверяется
канонным способом:

```bash
bash tools/mcp-call/mcp-call.sh --server answer42 --timeout 120 session_status
```

Логи и pid — в `.tmp/answer42/` (каталог gitignored). Рабочим каталогом сервера
намеренно сделан `.tmp/answer42`: Answer42 складывает рядом `build/`
(CF-артефакты, `build/rag/onec-rag.sqlite`) и без этого сорит в корне проекта.

## Подключение к агентам

Канон — [`.mcp.json`](../../.mcp.json) (плейсхолдеры `${ANSWER42_MCP_URL}`,
`${ANSWER42_TOKEN}`).

`tools/mcp-call` подстановку `${VAR}` **не делает** — ему нужен literal-конфиг
(`.cursor/mcp.json` потребителя, gitignored) с фактическими URL и токеном.

## Обновление форк-сборки

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 update [-Ref тег] [-Push] [-RestartService]
```

```bash
bash tools/answer42/answer42.sh update [--ref тег] [--push] [--no-restart]
```

Эквивалент вручную:

```powershell
# подтянуть релизы upstream, ребейзнуть fork-patches, пересобрать CF, переустановить пакет
powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 update
# плюс пуш ветки в origin и перезапуск сервиса
powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 update -Push -RestartService
```

Ключи `.env`: `ANSWER42_FORK_DIR` (чекаут форка), `ANSWER42_FORK_BRANCH`
(`fork-patches`), `ANSWER42_FORK_REMOTE` (`upstream` — источник релизов),
`ANSWER42_FORK_PUSH_REMOTE` (`origin`).

Что делает действие (одинаково в `.ps1` и `.sh`):

- без `-Ref`/`--ref` берёт новейший тег upstream; если ветка уже основана на нём —
  сообщает «обновлять нечего» (повторный запуск безопасен);
- неизвестный ref — внятная ошибка (exit 2), а не сырой `git fatal`;
- ребейзит ветку с патчами и проверяет, что патч (`_tool_error_text`) на месте;
  конфликт останавливает действие с подсказкой `git rebase --continue | --abort`;
- пересобирает `MCPTestManager.cf` / `MCPTestClient.cf` и делает
  `pip install -e`;
- на время переустановки останавливает HTTP-сервис (на Windows работающий
  сервис держит `answer42.exe` → WinError 32) и поднимает его обратно, если он
  был запущен.

## Вызовы

```bash
bash tools/mcp-call/mcp-call.sh --server answer42 --list
bash tools/mcp-call/mcp-call.sh --server answer42 session_status
bash tools/mcp-call/mcp-call.sh --server answer42 sessions_list
bash tools/mcp-call/mcp-call.sh --server answer42 --timeout 300 \
  start_session '{"session_id":"ui","base_url":"<URL ИБ>","idle_timeout_minutes":30}'
bash tools/mcp-call/mcp-call.sh --server answer42 --timeout 120 \
  stop_session '{"session_id":"ui","clean_data":true}'
```

## Smoke

Демо-база Answer42 (ИБ потребителя не затрагивается):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 smoke
```

Реальная ИБ (учётка из credential-стора):

```bash
.venv-answer42/Scripts/python.exe tools/answer42/smoke.py \
  --bin .venv-answer42/Scripts/answer42.exe \
  --base-url "http://127.0.0.1/<публикация>"
```

## Грабли

- **`.ps1` с кириллицей — только UTF-8 с BOM.** Windows PowerShell 5.1 читает
  файл без BOM как cp1251, кириллица ломает парсер (`Unexpected token`).
- **PowerShell 5.1 ≠ 7**: нет `String.Partition`, нет `-Encoding utf8NoBOM`;
  `Invoke-WebRequest` нужен с `-UseBasicParsing`.
- **Не проверять готовность `/mcp` через `Invoke-WebRequest` в PS 5.1**: на
  SSE-эндпоинте, который ещё не отвечает, запрос виснет без срабатывания
  `-TimeoutSec`. Поэтому `start`/`status` делают TCP-чек, а HTTP-проверка —
  `mcp-call`.
- **StreamableHTTP требует `Accept: application/json, text/event-stream`.**
  Без `text/event-stream` сервер отвечает `406`, а тело ответа приходит как SSE
  (`event: message` + `data: {…}`) — `mcp-call.sh` умеет и то, и другое по форме
  URL (`/mcp` без `/hs/` = streamable).
- У upstream-скрипта `scripts/e2e_stable.py` первым делом `taskkill /IM
  1cv8.exe 1cv8c.exe ibcmd.exe ibsrv.exe /T /F` — на рабочей машине запускать
  только с `E2E_SKIP_KILL_ALL_1C=1`.
- `--dev-tools` не включать: регистрирует `dev_eval` (произвольный BSL).
- 129 инструментов по умолчанию — для агента это много; профиль режется
  `--tool-profile core,ui,forms,tables` (значения: `core`, `ui`, `sessions`,
  `windows`, `forms`, `tables`, `tabular`, `dynamic`, `rag`, `recording`,
  `full`, `all`). `credentials_list` рекомендуется исключать из выдачи агенту.
- `1С window geometry was not detected` — скриншот уходит в `fallback:
  full_display` (снимок всего экрана), это не ошибка запуска.
- **Форк-сборка требует латинского пути** (editable `.pth` с кириллицей не
  читается) и локальной сборки CF в `src/mcp_1c/assets/`.
- **После неудачной навигации остаётся модальное окно ошибки** — следующая
  навигация в той же сессии падает. Закрыть окно (`click_button` с `OK`) или
  перезапустить сессию.
- **`stop`/`restart`:** pid в pid-файле — лаунчер, слушает порт другой pid,
  поэтому останавливаем и по pid, и по владельцу порта (`Get-NetTCPConnection`).

## Ограничения сборок

- **Пустой текст ошибки tool-call — только у PyPI-сборки** (0.5.3): при сбое
  ответ приходит как `Error executing tool <name>` без причины
  (`structured_content: null`) — MCP-SDK 2.x сохраняет текст лишь у `ToolError`.
  В **ветке патчей форка** это исправлено: ответ несёт сообщение 1С и
  `client_diagnostics`. Если текст снова пустой — работает не форк-сборка:
  проверить `ANSWER42_BIN` и выполнить `answer42.ps1 update`.
  Диагностика для PyPI-сборки: `current_error_info`, `user_messages`,
  `window_command_interface`, лог сервера.
- Форма пользовательской настройки «Изменить форму» автоматизируется частично
  (кнопка «Добавить поля» может не находиться).

## Лицензия

Answer42 — MIT (42Clouds, S. Kosolapov). Пакет ставится из PyPI, исходники в
репозиторий потребителя не вендорятся.
