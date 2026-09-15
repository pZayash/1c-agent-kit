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
  `linux-window-control`.

## Установка

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 install
```

Linux:

```bash
bash tools/answer42/answer42.sh install
```

Windows-вариант создаёт `.venv-answer42` в корне проекта-потребителя и ставит
`answer42[screenshot,windows-window-control]`. Каталог venv обязан быть в
`.gitignore` потребителя.

## Ключи `.env`

| Ключ | Зачем |
| --- | --- |
| `ANSWER42_MCP_URL` | endpoint сервера, напр. `http://127.0.0.1:9010/mcp` (порт берётся отсюда) |
| `ANSWER42_ACCOUNT_ID` | namespace credential-стора; **должен совпадать** с account в `~/.answer42-credentials.json` |
| `ANSWER42_TOKEN` | Bearer для StreamableHTTP; только в `.env` |
| `ANSWER42_EXTRA_ARGS` | доп. аргументы сервера; по умолчанию `--disable-rag` — RAG задерживает готовность |
| `ANSWER42_BIN` | опционально: путь к `answer42(.exe)`, если venv нестандартный |

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

## Ограничения upstream (0.5.3)

- **Текст ошибки tool-call пустой**: при сбое BSL-части ответ приходит как
  `Error executing tool <name>` без причины (`structured_content: null`).
  Воспроизводится на `open_navigation_link` с несуществующей ссылкой и на
  повторном `start_session`; собственный `E2E_SCENARIO=smoke` upstream падает
  на ассерте ожидаемого текста. Диагностику смотреть через `current_error_info`,
  `user_messages`, `window_command_interface` и лог сервера.
- Форма пользовательской настройки «Изменить форму» автоматизируется частично
  (кнопка «Добавить поля» может не находиться).

## Лицензия

Answer42 — MIT (42Clouds, S. Kosolapov). Пакет ставится из PyPI, исходники в
репозиторий потребителя не вендорятся.
