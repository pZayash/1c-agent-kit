---
name: xml-wellformed
description: >-
  Быстрая проверка well-formedness XML-файлов 1С (Template, Form, СКД, MXL,
  Rights, Configuration). Локальный python-скрипт без внешних зависимостей.
  Запускай после Edit/Write XML, перед `cfe-validate`/`meta-validate`.
---

# /xml-wellformed — Well-formedness XML-файлов 1С

## Зачем

XML 1С (`Template.xml`, `Form.xml`, `Rights.xml`, схемы СКД, MXL, конфигурация)
часто редактируются точечно (Edit). Поломанный XML ломает `cfe-validate`,
`meta-validate`, загрузку через `load-changed-files.sh`. Лучше отлавливать
сразу.

Skill — обёртка над `xml.etree.ElementTree.parse`. Проверяет только
синтаксис. Семантику (роли полей, схемы СКД) проверяют другие skill —
`cfe-validate`, `meta-validate`, `skd-validate`, `form-validate`.

## Команда

```bash
python tools/xml-wellformed/check.py <path> [<path> ...]
```

Из stdin:

```bash
python tools/xml-wellformed/check.py --stdin < file.xml
```

Несколько файлов разом:

```bash
python tools/xml-wellformed/check.py src/cfe/ТОРГ29_/**/*.xml
```

`-q` / `--quiet` — не печатать строки `OK`, только ошибки.

## Когда вызывать

- После Write/Edit любого `*.xml` под `src/cf/`, `src/cfe/`, `cfe.xml/`.
- Перед `cfe-validate` / `meta-validate` / `skd-validate` / `form-validate`
  — отсекает 90% ошибок на ранней стадии.
- Перед `./load-changed-files.sh` — иначе 1cv8.exe вернёт нечитаемый код
  ошибки.
- После `meta-edit` / `meta-compile` по `conf/` — **metadata-xml-lint**:

```bash
bash tools/sandbox/run.sh python tools/metadata-xml-lint/check.py path/to/Object.xml
```

## Коды возврата

- `0` — все файлы well-formed.
- `1` — хотя бы один файл с ParseError или not-found.
- `2` — usage error (нет аргументов и нет `--stdin`).

## Связанные skills

- `cfe-validate` — структурная валидация расширения.
- `meta-validate` — валидация объекта метаданных.
- `skd-validate` — валидация схемы компоновки.
- `form-validate` — валидация управляемой формы.