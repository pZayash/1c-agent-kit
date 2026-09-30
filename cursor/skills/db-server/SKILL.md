---
name: db-server
description: >-
  Отладочный узел 1С на автономном сервере (ibsrv): start/stop/status процесса,
  публикация HTTP-сервисов (MCP) через конфигурационный yaml, отладка по
  --debug. Нужен, когда требуется серверный режим и отладчик на копии базы.
argument-hint: "[-Action start|stop|status|yaml|basic] [--show]"
allowed-tools:
  - Bash
  - Read
---

# /db-server — отладочный узел 1С на автономном сервере

Поднимает **автономный сервер** (`ibsrv.exe`, «1С:Предприятие 8. Автономный
сервер») на **копии** файловой базы: веб-клиент + HTTP-сервисы (MCP) +
прямое соединение для конфигуратора + сервер отладки.

## Когда применять

- **dev-ИБ потребителя может жить на автономном сервере** (вместо публикации
  Apache): канон и процедуры — док потребителя (пример: `docs/ai/dev-ib-ibsrv.md`).
- Нужна **отладка** конфигурации (точки останова, стек, серверный код) —
  у автономного сервера для этого есть `--debug`.
- Нужен второй контур рядом с публикацией Apache: копия базы под сервером,
  основная база остаётся на Apache.

Файловая база **эксклюзивна**: если базу отдаёт ibsrv, публикация Apache по той же
базе работать не будет (и наоборот — первый старт на занятой базе падает с
«Ошибка исключительной блокировки информационной базы», см. Грабли).

## Что нужно в `.env`

| Ключ | Смысл |
| --- | --- |
| `IBSRV_PATH` | путь к `ibsrv.exe` |
| `IBSRV_DB_PATH` | каталог **копии** файловой базы |
| `IBSRV_NAME` | имя базы на сервере (для `/S`) |
| `IBSRV_DATA` | каталог данных сервера (вне репозитория) |
| `IBSRV_HTTP_*` | адрес/порт/базовый путь публикации |
| `IBSRV_DIRECT_REGPORT` | порт прямого соединения (`/S host:port\name`) |
| `IBSRV_DEBUG`, `IBSRV_DEBUG_PORT` | `http`/`tcp`/`server` и порт отладки |
| `IBSRV_SERVICES` | сервисы расширений через запятую, дефолт `mcp,mcp-dev` |
| `IBSRV_USER`, `IBSRV_PASSWORD` | учётка ИБ для Basic (фолбэк — `WEB_TEST_*`) |
| `IBSRV_PID_FILE` | PID-файл узла; задан → `load-changed-files.sh` работает через `ibcmd --pid` |
| `IBSRV_EXTRA_ARGS` | доп. флаги ibsrv (напр. `--enable-extended-designer-features`) |

Порты выбирай так, чтобы не пересекаться с Apache-публикацией и другими узлами.

## Команды

Скрипт запускается **на хосте** (не в sandbox): он стартует процесс и читает
хостовые пути.

```bash
SK=".cursor/skills/db-server/scripts/db-server.py"
python "$SK" -Action yaml     # перегенерировать конфигурационный yaml
python "$SK" -Action start    # запустить узел (detached, лог в .tmp/ibsrv)
python "$SK" -Action status   # pid + состояние портов
python "$SK" -Action stop     # остановить узел
python "$SK" -Action basic --show   # Basic-заголовок для MCP-клиента
```

Проверка MCP после старта:

```bash
curl -s -X POST "http://localhost:<IBSRV_HTTP_PORT>/hs/mcp/rpc" \
  -H "Authorization: Basic <base64 UTF-8>" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

## Конфигурационный yaml (публикация сервисов)

HTTP-сервисы **расширений** на автономном сервере не публикуются сами —
их надо перечислить в конфигурационном файле (`--config`), иначе сервис
отдаёт `503` с внутренней ошибкой `sessionId != kUUIDNull`. Канон структуры —
`ibcmd server config init`; ключ `http-services` **вложен** в элемент `http`:

```yaml
server:
  address: 'localhost'
  port: 8315
database:
  path: 'C:\Bases\copy'
infobase:
  id: '<uuid>'
  name: 'copy'
  distribute-licenses: yes
  schedule-jobs: allow
http:
  base: '/'
  http-services:
    publish-extensions-by-default: yes
    service:
    - name: 'mcp'
      root: 'mcp'
      publish: true
```

Разбор параметров: раздел «Standalone server configuration file» гайда
Administrator Guide (kb.1ci.com, Appendix 3) — см. память проекта.

## Отладка

1. `python db-server.py -Action start` (в `.env` задан `IBSRV_DEBUG=http`).
2. Конфигуратор: подключиться к `/S"<IBSRV_HTTP_ADDRESS>:<IBSRV_DIRECT_REGPORT>\<IBSRV_NAME>"`.
3. В конфигураторе — отладка по адресу сервера отладки (порт
   `IBSRV_DEBUG_PORT`), либо запуск клиента к тому же `/S`.

## Грабли

- **Файловая база эксклюзивна.** Пока ibsrv держит базу, публикация Apache по
  той же базе падает («Ошибка разделенного доступа»). Первый перевод базы на ibsrv:
  `Stop-Service Apache2.4` → старт узла → `Start-Service Apache2.4`
  (ИБ держит worker httpd.exe через wsap24.dll).
- **Аутентификация MCP — Basic**, не JWT: `accessTokenAuthentication` из
  `default.vrd` конфиг автономного сервера не описывает.
- **`/UpdateDBCfg` конфигуратором через `/S` рвёт сеанс**
  (`recv returns zero`, ассерт `m_dbOperationsBlock` в `workerHostImpl.cpp`) —
  загрузку `conf/` делать движком `ibcmd` (удалённый `--pid`).
- **MSYS переписывает POSIX-пути в env-переменных**: `IBSRV_HTTP_BASE="/"` без
  `MSYS_NO_PATHCONV=1` при запуске из Git Bash уезжает в `C:/Program Files/Git/`.
- **Basic-учётка — только UTF-8.** `curl -u` в Git Bash/MSYS отправляет
  кириллицу в cp1251/cp866 → платформа отвечает `401`. Собирай заголовок
  скриптом (`-Action basic --show`) или явным `Authorization: Basic …`.
- **Запуск из агентского шелла.** Процесс, оставшийся в консоли/дереве
  вызова, вешает Bash-инструмент — поэтому запуск detached
  (`DETACHED_PROCESS`/`start_new_session`).
- **`--http-base=/` из Git Bash** уезжает как `C:/Program Files/Git/`
  (нужен `MSYS_NO_PATHCONV=1`).
- Сервер отдаёт `401` без кредов и `503` для непубликованного сервиса —
  это разные диагнозы: 503 = нужен `http-services` в yaml.
