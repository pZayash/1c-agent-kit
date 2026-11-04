# docs-links — граф ссылок документации

Проверяет, что документация **достижима по ссылкам** от точки входа, и находит
**битые ссылки**. Без зависимостей: Python 3 stdlib.

Нужен для «последовательного раскрытия» (progressive disclosure): `AGENTS.md` —
минимум, дальше по оглавлениям (TOC) до любого документа.

## Термины

Русский канон первым, английский — синоним для поиска.

- **точка входа** (entry) — файл(ы), с которых начинается обход. Канон — `AGENTS.md`.
- **оглавление** (TOC) — `docs/README.md`, `memory/INDEX.md`, `README.md` каталога.
- **недостижимый документ** (unreachable) — нет цепочки ссылок от точки входа.
- **висячий документ** (dangling) — ноль входящих ссылок от других документов.
- **заглушка** (stub) — короткий файл «перенесено в kit»; ссылки внутрь не проверяем.
- **ссылка на каталог** (dir-link) — ведёт на папку, а не на файл.

## Установка

Канон — kit: `harness/tools/docs-links/`. В проект линкуется
`harness/scripts/link-kit-tools.sh` (Windows: `.ps1`). После линка доступно как
`tools/docs-links/check.py`.

## Запуск

```bash
# Полный аудит: числа + первые находки каждого вида
bash tools/sandbox/run.sh python tools/docs-links/check.py report

# Машиночитаемо (для автоматизаций)
bash tools/sandbox/run.sh python tools/docs-links/check.py report --json

# Все находки без обрезки
bash tools/sandbox/run.sh python tools/docs-links/check.py report --all

# Для хука/CI: только находки по изменённым файлам, exit 1 при ошибках
bash tools/sandbox/run.sh python tools/docs-links/check.py check --strict --files docs/ai/x.md

# Оглавление памяти: memory/INDEX.md (по месяцам, H1 + теги)
bash tools/sandbox/run.sh python tools/docs-links/check.py index
```

В `check_all.py` подключён чек `docs-links` (warning-only, как остальные).

## Конфиг

`.docs-links.json` в корне репозитория; дефолты — в `DEFAULT_CONFIG`
(`check.py`). Ключи:

| Ключ | Смысл |
| --- | --- |
| `entry` | точки входа обхода (обычно `["AGENTS.md"]`) |
| `roots` | что считать документацией: файлы и каталоги |
| `exclude` | префиксы вне аудита (код, генерируемые деревья, рабочие артефакты) |
| `stubs.max_bytes`, `stubs.markers` | как распознать заглушку |
| `severity` | `error` / `warning` для видов находок |
| `max_per_section` | сколько строк печатать в `report` без `--all` |
| `index_source`, `index_path` | каталог записей и файл индекса для `index` |

Важно: `exclude` не прячет файл от проверки ссылок внутри, он исключает его из
графа. Ссылка на исключённый, но существующий файл (например, `harness/…`)
считается валидной внешней целью.

## Что считается документом

**Отслеживаемые и новые неигнорируемые** `*.md` (`git ls-files --cached
--others --exclude-standard`) под `roots` и не под `exclude`. Так в аудит
попадают свежие документы, но не попадают `node_modules`, скачанные бинари,
`tmp/`, `outputs/` и архивы изменений. Если git недоступен — обход файловой
системы.

Код-фенсы и inline-код вырезаются: примеры `[x](path)` не считаются ссылками.
Проверяются markdown-ссылки, reference-определения и `<a href>`.

## Находки

| Вид | По умолчанию | Что значит |
| --- | --- | --- |
| `broken` | error | файла-цели нет |
| `anchor` | error | файл есть, заголовка с таким якорем нет |
| `unreachable` | error | не достигается от `entry` |
| `dangling` | warning | ноль входящих ссылок |
| `dir-link` | warning | ссылка на каталог вместо файла/оглавления |

Формат строки в `check`:

```text
docs-links: <файл>[:<строка>]: <severity>: <сообщение>
```

## Границы

- Только локальные ссылки: `http(s)`, `mailto`, `tel` не проверяются.
- Якоря — по GitHub-слагу заголовков (кириллица сохраняется).
- Симлинки-навыки (`.cursor/skills/`) исключены: это kit, а не документация проекта.
- Генератор оглавлений — только для `memory/` (`index`); README каталогов пока руками.
- Тесты: `python -m unittest discover -s harness/tools/docs-links -p "test_*.py"`.
