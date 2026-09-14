<!-- rtk-instructions v3 -->

# RTK (Rust Token Killer) — Оптимизация вывода команд

## TL;DR для агентов

**Перед запуском любой нативной CLI-команды — проверь, поддерживает ли её RTK.**
Если поддерживает — всегда префикс `rtk`. Экономия 26–99% токенов на типовом выводе.

Источники истины по списку поддерживаемых команд:

- Этот файл (раздел «Поддерживаемые команды» ниже) — кураторский список.
- `rtk --help` — **актуальный** перечень подкоманд (дополняется с обновлениями RTK).
  При сомнении сверяйся с `rtk --help`, а не угадывай.

## Правило использования

Используй `rtk` **для команд из списка ниже**. Для остальных команд RTK не
подходит — запускай их напрямую. Неизвестный большой stdout без `rtk` —
byte-cap (`| head -c 4000`), не `head -n`:
[shell-safety-playbook.md](shell-safety-playbook.md) § Byte-cap.

```bash
# ✅ Поддерживается RTK — всегда с префиксом
rtk git status
rtk git diff
rtk git add . && rtk git commit -m "msg"
rtk gh pr view 42
rtk cargo test

# ❌ Не поддерживается — запускать напрямую, без rtk
npx markdownlint docs/
openspec status --change "my-change"
pnpm install
```

**В цепочках `&&` префикс `rtk` ставится только на поддерживаемых звеньях:**

```bash
# ✅ Правильно
rtk git add file.md && rtk git commit -m "msg" && rtk git push

# ✅ Правильно — npx без rtk, git — с rtk
npx markdownlint docs/ && rtk git add . && rtk git commit -m "fix"
```

## Частые ошибки агентов

- **Забыть `rtk` на `git status` / `git diff` / `git commit`** — лишние
  сотни токенов на каждый вызов. Git — основной сценарий экономии.
- **Добавить `rtk` к `pnpm`/`npm`/`npx`/`openspec`** — получишь
  `[rtk: program not found]`, exit 127.
- **Забыть `rtk` в длинной цепочке `&&`** — префикс нужен на каждом
  поддерживаемом звене отдельно.

## Ограничение: только нативные .exe

RTK — нативный Windows-бинарник. Он запускает дочерний процесс напрямую
и **не умеет выполнять shell-скрипты, .cmd и .ps1 обёртки**.

На практике это значит: **npm-пакеты через rtk не работают**.
При `npm install -g` создаются shell-обёртки (не .exe), и rtk выдаёт
`[rtk: program not found]` с exit code 127.

```bash
# ❌ Не работает — openspec установлен через npm, это shell-скрипт
rtk openspec status --change "my-change"
# → [rtk: program not found], exit 127

# ✅ Правильно — запускать напрямую
openspec status --change "my-change"
```

**Как отличить**: если команда установлена через `npm install -g`,
`pip install`, `cargo install` (shim) или другой пакетный менеджер,
который создаёт скрипты-обёртки — запускай без rtk.
Нативные .exe (`git`, `gh`, `cargo`, `docker`, `kubectl`) — через rtk.

## Поддерживаемые команды

### Git (59–80% экономии)

```bash
rtk git status          # Компактный статус
rtk git log             # Компактный лог (все флаги работают)
rtk git diff            # Компактный diff (80%)
rtk git show            # Компактный show (80%)
rtk git add             # Ультра-компактные подтверждения (59%)
rtk git commit          # Ультра-компактные подтверждения (59%)
rtk git push            # Компактный вывод
rtk git pull            # Компактный вывод
rtk git branch          # Компактный список веток
rtk git fetch           # Компактный fetch
rtk git stash           # Компактный stash
rtk git worktree        # Компактный worktree
```

### GitHub CLI (26–87% экономии)

```bash
rtk gh pr view <num>    # Компактный PR (87%)
rtk gh pr checks        # Компактные checks (79%)
rtk gh run list         # Компактные workflow runs (82%)
rtk gh issue list       # Компактный список задач (80%)
rtk gh api              # Компактные API-ответы (26%)
```

### Сборка и компиляция (80–90% экономии)

```bash
rtk cargo build         # Вывод сборки Cargo
rtk cargo check         # Вывод проверки Cargo
rtk cargo clippy        # Предупреждения Clippy (80%)
rtk tsc                 # Ошибки TypeScript (83%)
rtk lint                # Нарушения ESLint/Biome (84%)
rtk prettier --check    # Только файлы, требующие форматирования (70%)
rtk format              # Универсальный чекер (prettier/black/ruff)
rtk next build          # Сборка Next.js с метриками маршрутов (87%)
rtk dotnet build        # .NET build/test/restore/format, компактно
rtk go build            # Go build/vet/test, компактно
rtk golangci-lint run   # golangci-lint, группировка по правилам
rtk prisma              # Prisma без ASCII-арта
```

### Тесты (90–99% экономии)

```bash
rtk cargo test          # Только провалы тестов Cargo (90%)
rtk vitest run          # Только провалы Vitest (99.5%)
rtk playwright test     # Только провалы Playwright (94%)
rtk pytest              # Только провалы Pytest, компактно
rtk test <cmd>          # Универсальная обёртка — только провалы
```

### Python-экосистема

```bash
rtk ruff check          # Ruff linter/formatter, компактно
rtk mypy                # Mypy с группировкой ошибок по файлам
rtk pip install …       # Pip (авто-детект uv), компактно
```

### Go-экосистема

```bash
rtk go build            # Go build с компактным выводом
rtk gt                  # Graphite (стек PR), компактно
```

### БД и облако

```bash
rtk aws <cmd>           # AWS CLI, форсирует JSON и сжимает вывод
rtk psql <args>         # psql без рамок, сжатые таблицы
```

### Менеджеры пакетов Node.js

RTK не всегда корректно запускает команды, которые доступны через shell-обертки.
Поэтому `pnpm`/`npm`/`npx` в этом проекте запускай напрямую, без `rtk`.

```bash
pnpm install
pnpm outdated
npm run <script>
npx <cmd>
```

### Файлы и поиск (60–75% экономии)

```bash
rtk ls <path>           # Дерево файлов, компактно (65%)
rtk read <file>         # Чтение кода с фильтрацией (60%)
rtk grep <pattern>      # Поиск, сгруппированный по файлам (75%)
rtk find <pattern>      # Поиск, сгруппированный по директориям (70%)
```

### Анализ и отладка (70–90% экономии)

```bash
rtk err <cmd>           # Только ошибки из любой команды
rtk log <file>          # Дедуплицированные логи со счётчиком
rtk json <file>         # Структура JSON без значений
rtk deps                # Обзор зависимостей
rtk env                 # Переменные окружения, компактно (секреты маскируются)
rtk summary <cmd>       # Умная сводка вывода команды
rtk smart <cmd>         # 2-строчная техническая сводка (эвристика)
rtk diff                # Ультра-компактные diff'ы
rtk wc <file>           # Подсчёт строк/слов/байт, компактно
```

### Инфраструктура (85% экономии)

```bash
rtk docker ps           # Компактный список контейнеров
rtk docker images       # Компактный список образов
rtk docker logs <c>     # Дедуплицированные логи
rtk kubectl get         # Компактный список ресурсов
rtk kubectl logs        # Дедуплицированные логи подов
```

### Сеть (65–70% экономии)

```bash
rtk curl <url>          # Компактные HTTP-ответы (70%)
rtk wget <url>          # Компактный вывод загрузки (65%)
```

### Мета-команды

```bash
rtk gain                # Статистика экономии токенов
rtk gain --history      # История команд с экономией
rtk cc-economics        # Claude Code: расходы (ccusage) vs экономия (rtk)
rtk discover            # Анализ сессий Claude Code — упущенные rtk
rtk learn               # Разбор ошибок CLI из истории Claude Code
rtk proxy <cmd>         # Запустить команду без фильтрации (для отладки)
rtk config              # Показать/создать конфиг
rtk rewrite <cmd>       # Показать rtk-эквивалент сырой команды
rtk hook-audit          # Метрики аудита переписывания хуков
rtk verify              # Проверка целостности хуков и TOML-фильтров
rtk init                # Инициализация rtk-инструкций в CLAUDE.md
```

### Флаги самого rtk

```bash
rtk -u git status       # Ultra-compact: ASCII-иконки, инлайн-формат
rtk --skip-env next …   # SKIP_ENV_VALIDATION=1 для дочернего процесса
rtk -v <cmd>            # Verbose (-v/-vv/-vvv)
rtk -V                  # Версия
```

## Как узнать актуальный список

Список подкоманд RTK расширяется. Если нужной команды нет в этом файле,
а по смыслу должна быть — сверься:

```bash
rtk --help              # Полный список подкоманд
rtk <cmd> --help        # Помощь по конкретной подкоманде
```

Не угадывай — если команды нет в `rtk --help`, значит запускай напрямую.

<!-- /rtk-instructions -->
