# grep-ast — поиск по коду с контекстом AST

## Что это

`grep-ast` — поиск по файлам исходного кода, который показывает совпадения
в контексте синтаксического дерева (AST). Вместо голых строк агент видит,
в какой функции/процедуре найдено совпадение, какой запрос содержит строку,
какой блок условий окружает результат.

## Синтаксис

```bash
PYTHONIOENCODING=utf-8 PYTHONUTF8=1 grep-ast "паттерн" путь/к/файлу.bsl --no-color
```

Обязательные флаги:

- `PYTHONIOENCODING=utf-8` — без него кириллица в путях и коде ломается
- `PYTHONUTF8=1` — **на Windows** обязателен: иначе Python 3.14 читает
  `.gitignore` в cp1251 → `UnicodeDecodeError` в pathspec (PowerShell:
  `$env:PYTHONUTF8=1`)
- `--no-color` — убирает ANSI-коды из вывода (удобнее для агента)

Полезные флаги:

- `-i` — регистронезависимый поиск
- `-n` — показать номера строк
- `--verbose` — подробный вывод

Можно передавать несколько файлов:

```bash
PYTHONIOENCODING=utf-8 PYTHONUTF8=1 grep-ast "паттерн" файл1.bsl файл2.bsl --no-color
```

## Чтение вывода

```text
conf\путь\Module.bsl:
│Функция МояФункция(параметр)     ← контекстная строка (родитель в AST)
│
⋮                                  ← пропуск (несмежные строки)
│   Запрос.Текст =                 ← контекст
█   |  Поле.ИскомоеЗначение        ← совпадение (█)
│   |  Поле.ДругоеПоле              ← контекст
⋮
│КонецФункции
```

- `█` — строка с совпадением
- `│` — контекстная строка (видна благодаря AST)
- `⋮` — пропущенные строки

## Откуда BSL-грамматика

grep-ast не знает 1С «из коробки». Грамматика BSL приходит через пакет
`tree-sitter-language-pack` под ключом `bsl` (грамматика
[alkoleft/tree-sitter-bsl](https://github.com/alkoleft/tree-sitter-bsl),
основа — [1c-syntax/bsl-parser](https://github.com/1c-syntax/bsl-parser)).
Расширения `.bsl`/`.os` регистрируются в `grep_ast/parsers.py` скриптом
`tools/grep-ast/patch-bsl-parsers.py` **если** потребитель его установил
(см. `development-setup.md` в репо потребителя). Отдельный
`pip install tree-sitter-bsl` без language-pack и без патча загрузчика выгоды
не даёт.

Smoke-проверка на эталонном модуле:

```bash
PYTHONIOENCODING=utf-8 PYTHONUTF8=1 grep-ast "Процедура" \
  conf/CommonModules/ОбщегоНазначения/Ext/Module.bsl --no-color
```

Признак успеха: контекстные строки с `│` на границах процедур/функций, а не
только «голые» совпадения.

Если smoke падает с `TypeError: ... 'bytes' object is not an instance of 'str'` —
установлен несовместимый `tree-sitter-language-pack` 1.x. Нужна связка
**grep-ast 0.9.0 + tree-sitter-language-pack 0.13.0** (см. setup потребителя).

## Ограничения BSL

- Community-грамматика, **не** парсер платформы 1С и **не** BSLLS. Для контекста
  «в какой процедуре найдено» обычно хватает; для валидации синтаксиса — нет.
- Текст запроса 1С в кавычках **не** разбирается как отдельное AST запроса.
- Препроцессор (`#Если …`) и редкий синтаксис могут рвать дерево →
  AST-контекст местами слабеет или пропадает.
- При сбое грамматики grep-ast деградирует к обычному текстовому grep — вывод
  всё ещё полезен, но без `│`-контекста.

Не использовать grep-ast как замену BSLLS: его задача — контекст при **чтении**,
а не диагностика качества кода.

## Диагностика

| Симптом | Причина | Решение |
| --- | --- | --- |
| `TypeError: argument 'source': 'bytes' object is not an instance of 'str'` | несовместимый `tree-sitter-language-pack` 1.x | связка **grep-ast 0.9.0 + tree-sitter-language-pack 0.13.0** |
| `UnicodeDecodeError` при чтении `.gitignore` (pathspec) | нет `PYTHONUTF8=1`, Python 3.14 читает cp1251 | добавить `PYTHONUTF8=1` (PowerShell: `$env:PYTHONUTF8="1"`) |
| Совпадения без `│`-контекста (только «голые» строки) | грамматика BSL не активна или сломалась на этом файле | проверить патч: `python tools/grep-ast/patch-bsl-parsers.py --check` (если есть в потребителе) |

## См. также

- Навык быстрого поиска по `conf/` — `.cursor/skills/1c-configdump-fast-search`
  в потребителе
- Гибридный поиск (BM25 + векторы): [qmd-search.md](qmd-search.md)
- Массовый обход кода: `rlm-tools-bsl.md` в потребителе (если подключён)
