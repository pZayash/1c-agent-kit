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

## Чек-лист агента

1. Правки в git (`conf/`, `cfe.xml/`)? → без `--list-file`.
2. Не трогал `cfe.xml/` → `--no-extensions`.
3. `.env` настроен (`cp .env.example .env`).
4. Обычный load: `./load-changed-files.sh -U`. Merge + отставание ИБ: `-F -U`.
5. Не записывать маркер = текущий HEAD до успешной заливки файлов.
6. BSL/XML проверки до load — `/bsl-check`, `/xml-wellformed`.

## Promote

Правки load engine — commit в kit → bump gitlink у потребителей.
