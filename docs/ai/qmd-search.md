# QMD search — agent guide

Terse. QMD = black box. Канон kit; специфика потребителя — addendum
`docs/ai/qmd-search-*.md` (если есть).

Синтаксис `lex:` / `vec:` / `hyde:`: [qmd-query-syntax.md](qmd-query-syntax.md).

## Client mode (`QMD_CLIENT`)

Агент **читает** `.env` (схема — `.env.example`). Ключи ниже — из
[templates/env-qmd.example](../../templates/env-qmd.example).

| `QMD_CLIENT` | Как искать | CLI `qmd` | MCP tools |
| --- | --- | --- | --- |
| `off` | только `rg` / `Grep` | не звать | не ждать |
| `cli` | `qmd query` / `search` / `links` / `get` | да, PATH | не обязателен |
| `mcp` | tools `query` / `get` / `multi_get` / `links` / `status` | **не** звать | `QMD_MCP_URL` |

Пусто / неизвестно: если `QMD_MCP_URL` задан — как `mcp`; иначе если `qmd` в
PATH — как `cli`; иначе как `off` (и скажи оператору, что поиск без индекса).

`mcp` и демон мёртв / URL пуст → fallback `rg`/`Grep`, не выдумывать CLI.

Слот без бинарника `qmd` в образе: обычно `mcp`. URL слота может быть
`host.docker.internal:8181` **или** общий сервер из `QMD_MCP_URL` — что в `.env`.

Не поднимать индекс (`collection add` / `update` / `embed` / `links --backfill`)
без просьбы оператора.

## What qmd is

- **Hybrid search**: BM25 + vectors + optional LLM expand + optional rerank
  (`qmd query`).
- **Link graph**: 1-hop out-links, backlinks, dangling — `qmd links`
  (wikilinks, relative `.md`; **not** BM25).

## Before search (`cli` or operator)

| Goal | Command |
| --- | --- |
| See collections | `qmd collection list` |
| Index a dir | `qmd collection add <path> --name <n> --mask '<glob>'` — **user**, heavy |
| Refresh index | `qmd update` — **user** |
| Partial refresh | `qmd update --files <path…>` — [Partial index](#partial-index-update---files) |
| Link graph fill | `qmd links --backfill` — **user** |
| Vectors | `qmd embed` — **user**; `qmd embed --files <path…>` subset |
| Status | `qmd status` |
| Filter search | `qmd query "…" -c <collection>` |

## Partial index (`update --files`)

Форк [pZayash/qmd](https://github.com/pZayash/qmd). Не путать с search `--files`
(формат вывода).

```bash
qmd update --files conf/Foo/Ext/Module.bsl docs/bar.md
qmd update --files removed.bsl
qmd embed --files conf/Foo/Ext/Module.bsl
qmd embed -f --files conf/Foo/Ext/Module.bsl
```

| Поведение | Деталь |
| --- | --- |
| Файл есть + glob коллекции | переиндекс (hash, FTS, links, anchors) |
| Путь удалён с диска | `deactivateDocument` только для него |
| Вне коллекции / не glob | warning, exit 0; `--strict` → exit 1 |
| Полный `qmd update` | сканирует всю коллекцию; `--files` не деактивирует прочих |

`dist/` форка не в git: `git pull` без `pnpm run build` → нет `--files`.

После апгрейда бинарника на старом индексе: `qmd update` **не** извлекает links
у неизменных hash → оператор: `qmd links --backfill` один раз.

Без `qmd embed`: `vec:` / `hyde:` молча игнор, только `lex:` (BM25).
`qmd status` → Pending > 0 — предупреди оператора.

Cold start: первая query грузит модели (~30–50s GPU / дольше CPU). Не ретраить.

## Command pick

| Cmd | Use |
| --- | --- |
| `qmd query` | Default. Hybrid + expand + rerank |
| `qmd search` | BM25 only, no LLM |
| `qmd vsearch` | Vector only |
| `qmd links` | Graph: out / backlinks / dangling (1-hop) |
| `qmd get` | Body by path or `#docid` |

`rg` видит любой файл на диске (в т.ч. `*.xml`). qmd видит только glob коллекции.

`lex:` / `vec:` / `hyde:` — **только** `qmd query` (MCP `query`), не `search`.

Медленный `query`: rerank на CPU десятки секунд. `--no-rerank` / `-C <n>` /
`vsearch`. Для code-lookup по именам процедур rerank часто не меняет top-5 —
default `--no-rerank`.

## One-line query

Строка без `lex:`/`vec:`/`hyde:` → **expand**. Модель expand часто английская
даже при русском вводе. Фикс: structured query или `intent:` / `--intent`
«variants in Russian».

Env `QMD_EMBED_MODEL` — забота оператора, если recall плохой на не-EN.

## Structured query

Typed lines → `lex` BM25, `vec`/`hyde` vector. Первая typed line — 2× вес.
Грамматика: [qmd-query-syntax.md](qmd-query-syntax.md).

Multiline: реальные newline **или** литерал `\n` (многие сборки нормализуют).
Надёжнее звать бинарник `qmd` из PATH, не npm-wrapper.

## Retrieval / links

Search даёт `#abc123`. Fetch: `qmd get "#abc123"`.

`qmd links` ≠ `query`. Graph = markdown links, не BM25.

MCP tool `links`: `doc`, `collection`, `view` = `out` | `backlinks` |
`dangling` | `all`.

Не `--backfill` / `--force-links` без просьбы.

## Path filter (`--path`)

Prefix, не glob. Несколько `--path` — OR.

```bash
qmd search "ключ" --path "conf/"
qmd search "ключ" --path "memory/"
```

Не: `conf/**`, `**/conf/**`.

## Tool choice — qmd vs Grep

Если `QMD_CLIENT=off` — колонка qmd не действует, сразу `Grep`/`rg`.

| Вопрос | Инструмент |
| --- | --- |
| точное имя символа / «найди вызовы X» | `Grep` |
| где / как / почему / откуда / куда | `qmd query`, потом `Grep` по топу |
| соседи memory / wikilink | `qmd links` |
| XML форм, если не в маске | `Grep` |
| факт в одном файле | `Grep` по пути |

После >3 `Grep` без сходимости и `QMD_CLIENT` не `off` — стоп, `qmd query`.

## Shared HTTP MCP

Демон: `qmd mcp --http --daemon` (порт 8181). Health: `GET /health`.
MCP: `POST /mcp`.

Bind loopback = только эта машина. LAN/слоты — bind `0.0.0.0` + firewall
(MCP без auth, пока форк не даст токен). Операционка хоста — не этот файл
(у потребителя / у хоста 42).

Клиент Cursor: `mcp.json` → `QMD_MCP_URL`. Не копировать хостовый mcp.json
со JWT 1С в слот.
