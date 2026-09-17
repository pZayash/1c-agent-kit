# Загрузка конфигурации в dev-ИБ (для агентов)

## Канон

Залить изменения из git (`conf/`, `cfe.xml/`) в **dev-базу** — только:

```bash
./load-changed-files.sh
```

С обновлением структуры БД после правок метаданных:

```bash
./load-changed-files.sh -U
```

Навык: **`/load-changed-files`**.

Ядро скрипта — `harness/tools/load-changed-files/` (kit). Корневой
`load-changed-files.sh` потребителя — thin wrapper.

Настройки: `.env` (`IB_CONNECTION`, `DESIGNER_PATH`, `CONFIG_PATH`,
`EXTENSIONS_PATH`). Шаблон ключей: [templates/env.example](../../templates/env.example).

Зависимости потребителя (не в kit): `tools/load-project-env.sh`, `tools/os/`.

## Не использовать

Upstream cc-1c: `db-load-git`, `db-load-xml`, `db-update`, `db-load-cf` —
исключены из sync. Канон — `./load-changed-files.sh`.

## Типовые флаги

- **`-U`** — `/UpdateDBCfg` после загрузки (почти всегда после метаданных).
- **`--no-extensions`** — только `conf/`, без `cfe.xml/`. **Обязателен**, если
  агент не менял расширения (защита от чужих правок в worktree).
- **`--list-file PATH`** — фолбэк: явный список вместо git-discovery.
- **`-F` / `--full-resync`** — вся `conf/` без partial; когда ИБ отстала от
  диска после merge («Неизвестный объект», exit 21).
- **`--reset-marker`** — удалить файл маркера (мёртвый SHA). **Не** канон
  «залить merge»: на чистом дереве это был бы только UpdateDB; скрипт на
  merge-HEAD сам берёт `HEAD^1`.
- **`--force-partial`** — не отменять partial с `Configuration.xml` после merge.
- **`--ibcmd`** / `LOAD_ENGINE=ibcmd` — headless/CI (медленнее designer).
- **`--force-sessions`** / **`--no-force-sessions`** — разрешить/запретить авто-retry
  `/UpdateDBCfg` при ошибке «обнаружены клиенты, работающие по HTTP». Env:
  `UPDATE_DB_FORCE_SESSIONS` (по умолчанию `true`).

После merge: `./load-changed-files.sh -U`. Стоп: `Загрузка пропущена; только
UpdateDB` при ненулевой дельте `conf/` — смотри exit 21, затем `-F -U`.
`LOAD_HIDE_FILES` в `.env` прячет битые типовые формы на время designer.

Подробности — skill `/load-changed-files` и docs потребителя.

## Preflight поддержки объектов

При partial-загрузке `conf/` скрипт делает preflight объектов на поддержке
(`Ext/ParentConfigurations.bin`). `parent_config.py` резолвится по порядку:
`PARENT_CONFIG_PY` → `scripts/parent_config.py` потребителя → канон
`harness/tools/load-changed-files/parent_config.py` (kit). Если файла нет
нигде — preflight пропускается с `WARN`, загрузка продолжается. Альтернатива —
`-F` (full-resync без preflight).

Внутренний список `-listFile` пишется в `.tmp/changed_files.txt` и удаляется
при любом выходе (успех/ошибка), в корне репозитория артефакт не остаётся.
Рабочие `temp_*.txt` движка тоже снимаются на любом выходе (EXIT-trap), так что
`git status` потребителя остаётся чистым даже при падении `-U`.

## UpdateDB упёрся в HTTP-клиентов (вторая публикация ИБ)

Симптом в логе:

```text
ОШИБКА: Обновление основной конфигурации базы данных завершилось с ошибкой (код: 1)
ОШИБКА:   Динамическое обновление конфигурации БД невозможно:
           обнаружены клиенты, работающие по HTTP
```

Причина: ИБ публикует не одна служба Apache. Скрипт гасит только
`APACHE_SERVICE_NAME`, а вторая публикация (например, MCP на другом порту,
служба `Apache24-2`) продолжает держать HTTP-сеансы — поэтому
`/UpdateDBCfg` не может взять эксклюзивную блокировку. Остановка
`APACHE_SERVICE_NAME` не помогает: файлы уже загружены, не применён только
UpdateDB.

Рабочая команда (designer), проверено на 8.5.1.1302:

```bash
1cv8.exe CONFIG /F"C:/base/proj" /UpdateDBCfg -Dynamic- -SessionTerminate force /DisableStartupDialogs
```

Важно: `-SessionTerminate force` работает **только** вместе с `-Dynamic-`.
Без `-Dynamic-` платформа на динамическое/эксклюзивное обновление не идёт,
и ошибка по HTTP-клиентам повторяется.

Движок делает этот retry сам, если после `/UpdateDBCfg` в логе есть признак
HTTP-клиентов и разрешён гейт `UPDATE_DB_FORCE_SESSIONS` (или явный
`--force-sessions`). Сеансы завершаются принудительно — в лог пишется `WARN`,
что пользователи отключаются. На prod-хостах гейт выключайте
(`UPDATE_DB_FORCE_SESSIONS=false` / `--no-force-sessions`): тогда скрипт
упадёт с подсказкой, но никого молча не разорвёт. Без второй публикации
(и без HTTP-ошибки) поведение не меняется.

### ibcmd

Аналог есть: у `ibcmd infobase config apply` ключи `--dynamic=<auto|disable|prompt|force>`
и `--session-terminate=<disable|prompt|force>` (по умолчанию `auto` и `disable`).
Retry движка для ibcmd:

```bash
ibcmd infobase config apply ... --force --dynamic=disable --session-terminate=force
```

### Мультислужбовый Apache

На Windows движок перед UpdateDB предупреждает, если в системе запущены другие
службы `Apache24*`/`*httpd*` кроме `APACHE_SERVICE_NAME`: они тоже публикуют ИБ
и держат HTTP-сеансы. Консьюмерский `tools/os/apache.sh` управляет одной службой;
список `APACHE_SERVICE_NAMES` пока не поддержан (будущее расширение).

## Чек-лист агента

1. Правки в git (`conf/`, `cfe.xml/`)? → без `--list-file`.
2. Не трогал `cfe.xml/` → `--no-extensions`.
3. `.env` настроен (`cp .env.example .env`).
4. Обычный load: `./load-changed-files.sh -U`. Merge + отставание ИБ: `-F -U`.
5. Не записывать маркер = текущий HEAD до успешной заливки файлов.
6. BSL/XML проверки до load — `/bsl-check`, `/xml-wellformed`.

## Promote

Правки load engine — commit в kit → bump gitlink у потребителей.
