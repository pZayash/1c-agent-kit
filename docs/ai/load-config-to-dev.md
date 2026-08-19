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
- **`--reset-marker`** — сброс маркера merge-загрузки.
- **`--ibcmd`** / `LOAD_ENGINE=ibcmd` — headless/CI (медленнее designer).

Подробности — skill `/load-changed-files` и docs потребителя.

## Чек-лист агента

1. Правки в git (`conf/`, `cfe.xml/`)? → без `--list-file`.
2. Не трогал `cfe.xml/` → `--no-extensions`.
3. `.env` настроен (`cp .env.example .env`).
4. `./load-changed-files.sh -U` (или `-U --no-extensions`).
5. BSL/XML проверки до load — `/bsl-check`, `/xml-wellformed`.

## Promote

Правки load engine — commit в kit → bump gitlink у потребителей.
