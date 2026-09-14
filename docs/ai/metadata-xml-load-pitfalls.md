# Метаданные XML: ловушки LoadConfigFromFiles

Кейсы из OpenSpec `payment-terms-kp-zp` (2026-06-16): `meta-edit` /
`meta-compile` + `meta-validate` прошли, а `1cv8 CONFIG /LoadConfigFromFiles`
падал с **«Исключение XDTO при чтении файла»**.

`xml-wellformed` и `meta-validate` **не заменяют** smoke загрузки в dev.
После правок метаданных — `./load-changed-files.sh -U` (или хотя бы один
пробный partial load).

См. также: [object-conventions.md § Квалификаторы типов](object-conventions.md#квалификаторы-типов-в-xml--правильные-имена-тегов),
[load-config-to-dev.md](load-config-to-dev.md).

**Агент:** новый успешно решённый кейс load/XDTO — сразу в `memory/`; перед
`/close-chat` предложить оператору перенос в этот файл
([agent-session-lessons.md](agent-session-lessons.md)).

## Чеклист перед загрузкой

1. **Числа** — только `xs:decimal` + `v8:NumberQualifiers`, не shorthand в XML.
2. **Ссылки** — в `conf/` иерархической выгрузки: `cfg:CatalogRef.*` /
   `cfg:EnumRef.*` (корневой `xmlns:cfg` уже в `MetaDataObject`).
3. **Нет `&#13;`** между соседними тегами после `meta-edit`.
4. **ТЧ каталога/документа** — сверить с эталоном УНФ: `LineNumberLength`,
   `TypeReductionMode` у `LineNumber` (ТЧ-level), полный набор стандартных полей
   атрибута. **Object-level `StandardAttributes` — без `LineNumber`** (платформа
   добавляет в ТЧ сама).
5. **Формы** — `PagesGroupExtInfo` (с «s»), не `PageGroupExtInfo`; каждый `<Page>`
   содержит `<enabled>true</enabled>`.
6. **`meta-validate`** по затронутым объектам.
7. **UUID** — новые объекты: только случайные GUID (`uuid.uuid4()` / конфигуратор /
   `meta-compile` с генерацией). Запрещены placeholder `a1b2c3d4-…`,
   `b2c3d4e5-…` и copy-paste. Перед коммитом — `rg` по uuid в `conf/` **и**
   `cfe.xml/`. Новые объекты — обновить `Configuration.xml` (порядок `ChildObjects`).
8. **`load-changed-files.sh -U --no-extensions`** — если не трогали `cfe.xml/`.

## Антипаттерны (симптом → исправление)

| Симптом в логе 1С | Что в XML | Исправление |
| --- | --- | --- |
| XDTO на Catalogs/Documents | `Number(3)` в Type | `xs:decimal` + qualifiers |
| То же | `d5p1:EnumRef.X` | `cfg:EnumRef.X` |
| То же | `</Attribute>&#13;` | Убрать `&#13;` (CRLF от `meta-edit`) |
| XDTO на ТЧ | Нет `LineNumberLength` | Эталон типовой ТЧ УНФ |
| XDTO/задвоение `LineNumber` | `LineNumber` в object-level `StandardAttributes` | Убрать — ТЧ-level добавит сама |
| Группа страниц формы не грузится | `PageGroupExtInfo` (опечатка) | `PagesGroupExtInfo` (с «s») |
| Страница формы отключена/валидация падает | `<Page>` без `<enabled>` | `<enabled>true</enabled>` |
| Конфликт UUID (часто MCP) | Дубль conf ↔ cfe | GUID в **conf**, не MCP |

### Число `Число(3)` в DSL

В **JSON/meta-edit DSL** пишите **`Number(3,0)`** или **`Number(3,0,nonneg)`**,
не `Number(3)`.

`meta-edit.py` / `meta-compile.py` парсят только `Number(D,F)`. Один аргумент
уходит в fallback:

```xml
<v8:Type>Number(3)</v8:Type>
```

— невалидно для XDTO. Подробнее: [object-conventions.md](object-conventions.md).

Пример корректного фрагмента:

```xml
<Type>
    <v8:Type>xs:decimal</v8:Type>
    <v8:NumberQualifiers>
        <v8:Digits>3</v8:Digits>
        <v8:FractionDigits>0</v8:FractionDigits>
        <v8:AllowedSign>Nonnegative</v8:AllowedSign>
    </v8:NumberQualifiers>
</Type>
```

### Ссылочные типы: `cfg:` vs `d5p1:`

В **дампе конфигурации** (`conf/`, hierarchical) эталон УНФ — префикс **`cfg:`**:

```xml
<v8:Type>cfg:EnumRef.яя_ТипыЭтаповОплаты</v8:Type>
```

`meta-edit` / `meta-compile` эмитят **`d5p1:`** с inline `xmlns` (задумано для
EPF/отдельных контекстов, см. [skd-dsl-spec.md](specs/skd-dsl-spec.md)). Для
**загрузки в основную конфигурацию** после генерации заменить на `cfg:` или
починить генератор (см. предложения ниже).

Проверка по репозиторию:

```bash
rg 'd5p1:(EnumRef|CatalogRef)' conf/Catalogs conf/Documents
rg '<v8:Type>Number\([0-9]+\)</v8:Type>' conf/
rg '&#13;' conf/Catalogs conf/Documents
```

### Артефакт `&#13;`

После `add-ts-attribute` / вставки атрибутов `meta-edit` в файле может
появиться буквальный `&#13;` перед следующим тегом. XML well-formed, но
**LoadConfigFromFiles падает**. Удалить вручную или скриптом постобработки.

### UUID: общие правила

- Генерируй каждый UUID отдельно: `uuid.uuid4()` (Python), `[guid]::NewGuid()`
  (PowerShell) или конфигуратор. `meta-compile` с генерацией — тоже ок.
- **Не** переиспользуй UUID copy-paste'ом — даже «похожие» объекты получают
  разные.
- **Не** используй placeholder/последовательные UUID (`a1b2c3d4…`, `b2c3d4e5…`).
- После массовой генерации метаданных — проверка на дубликаты UUID по дереву
  исходников (`rg` по uuid в `conf/` **и** `cfe.xml/`).
- При добавлении новых объектов метаданных — обнови `Configuration.xml`
  (порядок `ChildObjects` важен для загрузки).

### Placeholder UUID ↔ конфликт с MCP

`meta-compile` / ручной scaffold иногда вставляет шаблонные GUID
(`a1b2c3d4-e5f6-4789-a012-3456789abcde`, затем `b2c3d4e5-…` в InternalInfo).
Те же значения уже есть у объектов расширения `MCP_Сервер` / `MCP_Сервер_Dev`
на развёрнутых базах.

Симптом после загрузки conf + `/UpdateDBCfg` расширения:

> Конфликт внутренних идентификаторов у объекта Обработка.mcp_Инструмент_…

**Правила:**

1. Новые объекты **conf/** — только случайные UUID. Placeholder-последовательности
   запрещены.
2. Дубликат найден → менять GUID в **conf**, **не** в MCP (расширение уже на
   prod/dev).
3. Смена uuid уже загруженного в ИБ enum/объекта: partial load одного файла
   часто недостаточен — грузить с `Configuration.xml` (или шире), затем
   `/UpdateDBCfg`.
4. Симптом «конфликт внутренних идентификаторов» на объекте MCP после правок
   conf — первым делом искать дубликат uuid между `conf/` и `cfe.xml/`.

Память-источник:
[memory/2026-07-02-uuid-placeholder-conflict-mcp.md](../memory/2026-07-02-uuid-placeholder-conflict-mcp.md).

### Табличная часть справочника

При `add-ts` сверять с существующей ТЧ в `conf/Catalogs/`:

- `LineNumberLength` (часто `5`) в `Properties` ТЧ;
- `xr:TypeReductionMode` в `StandardAttributes/LineNumber` **ТЧ-level** (внутри
  `<TabularSection>`);
- порядок `ChildObjects`: `TabularSection` → `Form` (как в типовых объектах).

**Не путать два блока `StandardAttributes`:**

- **Object-level** (`<StandardAttributes>` вверху каталога/документа, до
  `ChildObjects`) — содержит `PredefinedDataName`, `Reference`, `DeletionMark`,
  `Code`, `Owner`, `Description` и т.п. **Не добавляй туда `LineNumber`** —
  платформа сама генерирует `LineNumber` в ТЧ-level блок. Дублирование → ошибка
  загрузки или задвоение.
- **ТЧ-level** (`<StandardAttributes>` внутри `<TabularSection>`) — вот тут
  `xr:StandardAttribute name="LineNumber"` с `TypeReductionMode` обязан быть.

## Формы (`form-edit` и разметка)

Отдельно от XDTO метаданных: события в `Form.xml` — не ключ `on: ИмяПроцедуры`,
а:

```xml
<Events>
    <Event name="OnChange">яя_УсловияОплатыПриИзменении</Event>
</Events>
```

`form-validate` ловит не всё; после правок — открытие формы в dev или smoke UI.

### Группа страниц `Pages`: `PagesGroupExtInfo`

Тип extInfo для группы страниц — **`PagesGroupExtInfo`** (с буквой «**s**» в
`Pages`), не `PageGroupExtInfo`. Опечатка тихо ломает форму — группа страниц не
грузится в Конфигураторе/EDT.

```xml
<type>Pages</type>
<extInfo xsi:type="form:PagesGroupExtInfo">
    <pagesRepresentation>Auto</pagesRepresentation>
    <currentRowUse>Auto</currentRowUse>
</extInfo>
```

### Элемент `Page`: обязательный `<enabled>true</enabled>`

Для каждого `<Page>` внутри `<Pages>` требуется `<enabled>true</enabled>`.
Без него Конфигуратор считает страницу отключённой (или валидация формы падает).

```xml
<type>Page</type>
<enabled>true</enabled>
```

## Порядок работы агента (рекомендуемый)

```text
meta-compile / meta-edit
  → meta-validate (затронутые объекты)
  → metadata-xml-lint (см. ниже) или rg по антипаттернам
  → load-changed-files.sh -U [--no-extensions]
  → smoke (MCP / UI)
```

## Предложения по доработке скиллов и скриптов

### `meta-edit` / `meta-compile` (upstream cc-1c-skills)

| Проблема | Предложение |
| --- | --- |
| `Number(3)` в XML | Парсить `Number(D)` как `Number(D,0)` |
| `d5p1:` в `conf/` | `--ref-prefix cfg` или авто по hierarchical dump |
| `&#13;` при save | LF-only; post-save strip `&#13;` |
| ТЧ без `LineNumberLength` | `add-ts` копирует шаблон с эталона |
| False confidence | Warnings: счётчик d5p1 / `Number(D)` |

Патчить: скрипт `meta-edit` в `.cursor/skills/` потребителя (upstream cc-1c-skills
+ локальные правки потребителя при необходимости).

Линт: `metadata-xml-lint` в `tools/` потребителя (если есть).

### `meta-validate`

Добавить проверки (severity **error**, не warn):

- `<v8:Type>Number\(\d+\)</v8:Type>` без qualifiers;
- `d5p1:(EnumRef|CatalogRef|DocumentRef)` в путях под `conf/` (опционально
  `--profile hierarchical`);
- литерал `&#13;` вне CDATA;
- ТЧ без `LineNumberLength` (catalog/document);
- `LineNumber` в object-level `StandardAttributes` (дубликат);
- `PageGroupExtInfo` (опечатка) вместо `PagesGroupExtInfo` в `Form.xml`;
- `<Page>` без `<enabled>` в `Form.xml`.

Опционально: режим `--loadconfig-smoke` — вызов `load-changed-files.sh` по
одному файлу (тяжело, но ground truth).

### `xml-wellformed`

Расширить до **`metadata-xml-lint`** (отдельный скрипт или флаг):

- well-formed (как сейчас);
- антипаттерны из таблицы выше.

`xml-wellformed` alone недостаточен — `Number(3)` парсится как well-formed.

### `form-edit`

- Валидировать синтаксис `on` в JSON definition;
- В SKILL: канон `<Event name="OnChange">` + ссылка на этот документ.

### Документация / workflow

- Ссылка из [merge-vendor-pitfalls.md](merge-vendor-pitfalls.md) (раздел
  LoadConfigFromFiles) на этот файл для **наших** правок, не только мерджа.
- В скилле `load-changed-files` потребителя: шаг «после meta-edit — rg/lint
  по антипаттернам».

## Правка `Form.xml`/XML: CRLF+BOM, байтово, `diff -w`

XML метаданных и форм 1С — **UTF-8 BOM + CRLF**, без хвостового перевода строки.

- `sed -i`/awk (git-bash) и Edit-tool легко ломают CRLF или смешивают переводы
  строк → нечитаемый diff, риск отказа `LoadConfigFromFiles`. Edit-tool вдобавок
  ненадёжно матчит **табовую** индентацию форм.
- **rtk не для извлечения содержимого:** `rtk git show HEAD:file > out` нормализует
  вывод (срезает `\r`, переотступает) — это **не** байтовая копия blob. `rtk` —
  только для чтения глазами. Точный blob: `git checkout HEAD -- file` (без `rtk`).
- Whole-file **whitespace-diff** (переотступ всего файла) маскирует реальное
  изменение. Отделять сигнал: `git diff -w --stat -- file`.

**Рецепт точечной правки большого XML/формы:**

1. эталон: `git checkout HEAD -- <file>`;
2. вставка/удаление **байтово** python из [sandbox](sandbox.md), сохраняя BOM/`\r\n`:
   `open(p,"rb")` → отделить `\xef\xbb\xbf` → `splitlines(keepends=True)` →
   правка по номерам строк / `replace(marker, marker+ins)` со строками
   `...\r\n` → `open(p,"wb")`;
3. контроль: `xml-wellformed` + `grep -c $'\r' == wc -l`; `git diff -w` = ожидаемое.

Память: [2026-06-18-1c-xml-forms-crlf-byte-edit](../memory/2026-06-18-1c-xml-forms-crlf-byte-edit.md),
[2026-06-18-rtk-not-for-file-extraction](../memory/2026-06-18-rtk-not-for-file-extraction.md).

## Источник

OpenSpec `payment-terms-kp-zp`, исполнитель 2026-06-16; память:
[memory/2026-06-16-metadata-xml-loadconfig-pitfalls.md](../memory/2026-06-16-metadata-xml-loadconfig-pitfalls.md).
Добивка 2026-06-18 (CRLF/rtk) — секция выше.
Headless smoke форм: **не** `ПолучитьФорму` на сервере — см.
[изменение-типовых-форм.md § Проверка: открыть форму](изменение-типовых-форм.md#5-проверка-открыть-форму).
UUID/MCP — 2026-07-02, секция выше.
