# Справочник паттернов для анализа кода

## Структура conf/ (hierarchical XML+BSL)

```
conf/
  CommonModules/ИмяМодуля/Ext/Module.bsl
  Documents/ИмяДокумента/Ext/ObjectModule.bsl
  Documents/ИмяДокумента/Ext/ManagerModule.bsl
  Documents/ИмяДокумента/Forms/ИмяФормы/Ext/Form/Module.bsl
  Catalogs/ИмяСправочника/Ext/ObjectModule.bsl
  AccumulationRegisters/ИмяРегистра/Ext/RecordSetModule.bsl
  InformationRegisters/ИмяРегистра/Ext/ManagerModule.bsl
```

## Стратегии поиска

### Через Grep + Read (предпочтительно для 1-5 файлов)

```
Grep: pattern="ИмяПроцедуры", path="conf/", glob="*.bsl"
Read: file_path="conf/CommonModules/Имя/Ext/Module.bsl"
```

### Через grep-ast (контекст функции)

```bash
python -m grep_ast "ИмяПроцедуры" "conf/CommonModules/Имя/Ext/Module.bsl"
```

### Через rlm-tools-bsl (массовый поиск, экономия контекста)

Workflow: `rlm_start(project='proj', query='…')` → `rlm_execute(script)` → `rlm_end()`
(проект+индекс зарегистрированы разово, см. [docs/ai/rlm-tools-bsl.md](../../../docs/ai/rlm-tools-bsl.md)).

В `rlm_execute` доступны 57 BSL-хелперов; точные имена/сигнатуры — через `rlm_help('<helper>')`
или `docs/HELPERS.md` форка (не угадывать). Скрипт всегда заканчивается `print()`. Пример
формы (имена хелперов сверь через `rlm_help`):

```python
# поиск процедуры + контекст вызовов — конкретные хелперы см. rlm_help
res = find_procedure("ИмяПроцедуры")   # имя-пример, сверь через rlm_help
for r in res[:10]:
    print(r)
```

## Ключевые паттерны кода 1С

### Присвоение реквизита формы

```bsl
Форма.ИмяРеквизита = Значение;
ЭтаФорма.ИмяРеквизита = Значение;
```

**grep-паттерн**: `Форма\.ИмяРеквизита\s*=|ЭтаФорма\.ИмяРеквизита\s*=`

### Экспортная процедура/функция

```bsl
Процедура ИмяПроцедуры(Параметр1, Параметр2) Экспорт
Функция ИмяФункции(Параметры) Экспорт
```

**grep-паттерн**: `(Процедура|Функция)\s+ИмяПроцедуры`

### Вызов метода общего модуля

```bsl
ОбщийМодуль.ИмяМетода(Параметры);
Результат = ОбщийМодуль.ИмяФункции(Параметры);
```

**grep-паттерн**: `ОбщийМодуль\.ИмяМетода\(`

## Маппинг типов модулей

| Каталог | Тип модуля | Файл |
|---------|-----------|------|
| `CommonModules/X/` | Общий модуль | `Ext/Module.bsl` |
| `Documents/X/` | Модуль объекта | `Ext/ObjectModule.bsl` |
| `Documents/X/` | Модуль менеджера | `Ext/ManagerModule.bsl` |
| `Documents/X/Forms/Y/` | Модуль формы | `Ext/Form/Module.bsl` |
| `Catalogs/X/` | Модуль объекта | `Ext/ObjectModule.bsl` |
| `AccumulationRegisters/X/` | Модуль набора записей | `Ext/RecordSetModule.bsl` |
| `InformationRegisters/X/` | Модуль менеджера | `Ext/ManagerModule.bsl` |

## Частые ошибки

| Ошибка | Решение |
|--------|---------|
| Grep по `conf/` слишком медленный | Сузь glob: `*.bsl`, конкретная папка |
| Модуль не найден | `Glob: pattern="conf/**/*ЧастьИмени*"` |
| Слишком много результатов | Ищи в конкретном каталоге, не во всём `conf/` |
| rlm-tools-bsl: пустой вывод | Добавь `print()` |
| rlm-tools-bsl: session expired | Вызови `rlm_start` заново |
