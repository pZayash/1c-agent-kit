# Выгрузка конфигурации в CF-файл (ibcmd / конфигуратор)

Канон: как выгрузить конфигурацию ИБ в бинарный `.cf` (и расширение в `.cfe`)
двумя штатными путями, и как доставить CF обратно в базу.

Обратная операция (загрузка XML-исходников в ИБ) —
[load-config-to-dev.md](load-config-to-dev.md).

## Два движка

| | `ibcmd infobase config save` | `1cv8 DESIGNER /DumpCfg` |
| --- | --- | --- |
| Базы | **только файловые** (`--db-path`, либо `--pid` автономного сервера) | файловые `/F` и серверные `/S` |
| Учётка | `--user=` / `--password=` (короткие `-u` / `-P`) | `/N` / `/P` |
| Расширение | `--extension=<имя>` (по одному) | `-Extension "<имя>"` или `-AllExtensions` |
| Прочее | headless, без клиента; **save = CF** | нужен установленный клиент той же сборки |

Входная точка — скрипт скилла `db-dump-cf` (`skills/cc-1c/db-dump-cf`):
движок выбирается по `-V8Path` — если бинарь `ibcmd*`, идёт ветка ibcmd,
иначе `DESIGNER /DumpCfg`. Доп. аргументы — `-AdditionalIbcmdArguments`
(`--ключ=значение`, через запятую) / `-AdditionalV8Arguments`; скрипт
отклоняет набор чужого движка.

## Синтаксис

```bash
# ibcmd — файловая ИБ
ibcmd infobase config save --db-path="<каталог ИБ>" [--user=..] [--password=..] "<out.cf>"
ibcmd infobase config save --db-path="<каталог ИБ>" --extension=<ИмяРасширения> "<out.cfe>"

# ibcmd — база под автономным сервером ibsrv (онлайн, шлюз администрирования)
ibcmd infobase config save --pid=<pid узла> -u <user> "<out.cf>"

# Конфигуратор — файловая / серверная
1cv8 DESIGNER /F"<каталог ИБ>" /N".." /P".." /DumpCfg "<out.cf>"
1cv8 DESIGNER /S"<srv>\<ref>" /N".." /P".." /DumpCfg "<out.cf>"
# расширение:
... /DumpCfg "<out.cfe>" -Extension "<Имя>"
... /DumpCfg "<каталог>" -AllExtensions

# Из хранилища конфигурации (только конфигуратор)
1cv8 DESIGNER /F"<ИБ>" /ConfigurationRepositoryF "<хранилище>" \
  /ConfigurationRepositoryDumpCfg "<out.cf>" [-v <версия>]
```

## Ловушки

- **`config save` ≠ `config export`.** `save` — бинарный CF; `export` —
  выгрузка в **XML-исходники** (создаёт каталог). Перепутать легко.
- **ibcmd без учётки может виснуть.** Без `--user` на Windows ibcmd читает
  креды с консоли (stdin игнорируется) → промпт блокирует процесс. Всегда
  передавать учётку либо закрывать stdin (скрипт скилла делает `input=""`).
- **Базу держит не только конфигуратор.** Веб-публикация (Apache/IIS), автономный
  сервер `ibsrv`, клиент тестирования и любая клиентская сессия тоже дают
  «Ошибку исключительной блокировки». Кто держит и как освободить —
  [infobase-exclusive-access.md](infobase-exclusive-access.md).
- **Висячий сеанс «Конфигуратор» блокирует операции.** Прерванные запуски
  designer/ibcmd оставляют сеанс → «Ошибка блокировки информационной базы для
  конфигурирования». Перед операцией проверять чужие сеансы
  (`ibcmd infobase config extension list --pid=<pid>` на автономном сервере,
  либо список сеансов в консоли/АС).
- **Инвентарь расширений** — `РасширенияКонфигурации.Получить()` в базе или
  `ibcmd infobase config extension list`. MCP-инструменты вроде
  `extensions_get` могут отдавать неполный список.
- **`ibcmd.exe` есть не в каждой сборке платформы** — проверять наличие
  бинаря в `bin/` до выбора движка.
- **Поддержка:** CF переносит состояние поддержки молча, но снять/прочитать его
  инструментом (`ibcmd config support`) может не получиться — тогда проверка
  вручную (Справка → О поддержке).
- **Designer на Windows из MSYS/Git-Bash:** `MSYS_NO_PATHCONV=1`,
  `MSYS2_ARG_CONV_EXCL="*"`; путь для `/Out` — Windows (`cygpath -w`), не
  Unix `/c/…` (иначе «Каталог не обнаружен»).

## Доставка CF в базу (обратный путь)

```bash
ibcmd infobase create --db-path="<ИБ>"          # только новая база
ibcmd infobase config load  --db-path="<ИБ>" "<file.cf>"
ibcmd infobase config apply --db-path="<ИБ>" --force
```

- Выгрузка CF — чтение: база не меняется, блокировок не требует.
- `load`+`apply` на большой базе — десятки минут; оффлайн `--db-path`
  требует **монопольного доступа** (остановить сервер/сеансы ИБ).
  Онлайн-вариант `apply --pid=<узел>` на ibsrv применяет конфигурацию
  к работающему серверу, но на крупных изменениях метаданных проверять
  отдельно.
- Полнота переноса проверяется сравнением **поколения конфигурации**
  (`ibcmd infobase config version` / параметр поколения в метаданных)
  до и после `apply`.

## См. также

- Skill `db-dump-cf` (`skills/cc-1c/db-dump-cf`) — обёртка над обоими движками.
- [metadata-xml-load-pitfalls.md](metadata-xml-load-pitfalls.md) — грабли
  XML-маршрута (полный импорт, `import files`, `--no-check`).
