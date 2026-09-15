---
name: answer42-ui
description: >-
  Управление живым UI 1С:Предприятия через Answer42 (клиент тестирования) —
  открыть форму, кликнуть, заполнить, прочитать таблицу, снять скриншот.
  Триггеры: /answer42-ui, «проверь в тонком клиенте», «прогони UI в 1С»,
  «открой форму в 1С и проверь», «сними скриншот 1С».
---

# UI 1С через Answer42

Канон и ограничения: [answer42.md](../../../docs/ai/answer42.md).
Эксплуатация сервиса: [tools/answer42/README.md](../../../tools/answer42/README.md).

## Предусловие

HTTP-сервер Answer42 поднят и доступен в `tools/mcp-call`:

```bash
bash tools/mcp-call/mcp-call.sh --server answer42 session_status
```

Нет ответа — поднять (Windows):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/answer42/answer42.ps1 start
```

Дальше — `--server answer42`. Тяжёлые вызовы (`start_session`, `stop_session`,
печать, экспорт) — с `--timeout 300`.

## Минимальный прогон

```bash
# 1. сессия на нужной ИБ (URL публикации); учётка берётся из credential-стора
bash tools/mcp-call/mcp-call.sh --server answer42 --timeout 300 \
  start_session '{"session_id":"ui","base_url":"http://127.0.0.1/dev_db","idle_timeout_minutes":30}'

# 2. что открыто
bash tools/mcp-call/mcp-call.sh --server answer42 active_window '{"session_id":"ui"}'

# 3. структура окна (по умолчанию компактный профиль navigation)
bash tools/mcp-call/mcp-call.sh --server answer42 ui_tree '{"session_id":"ui"}'

# 4. открыть список и прочитать строки (только чтение)
bash tools/mcp-call/mcp-call.sh --server answer42 open_navigation_link \
  '{"session_id":"ui","navigation_link":"e1cib/list/Документ.ЗаказПокупателя"}'
bash tools/mcp-call/mcp-call.sh --server answer42 table_rows '{"session_id":"ui","name":"Список"}'

# 5. завершить обязательно
bash tools/mcp-call/mcp-call.sh --server answer42 --timeout 120 \
  stop_session '{"session_id":"ui","clean_data":true}'
```

## Работа с формой

- Не угадывать технические имена элементов: сначала `ui_tree`, затем
  `find_object` или `ui_tree` с фильтром `name`/`title`/`type`.
- Действия: `focus_object`, `set_field_value`, `click_button`, `save_form`,
  `close_form`; таблицы — `table_*`; динамические списки — `dynamic_list_*`.
- После действия проверять состояние: `form_state`, `field_value_text`,
  `table_rows`, `user_messages`, `current_error_info`.

## Доказательства

```bash
bash tools/mcp-call/mcp-call.sh --server answer42 screenshot '{"session_id":"ui"}'
bash tools/mcp-call/mcp-call.sh --server answer42 recording_start '{"session_id":"ui"}'
bash tools/mcp-call/mcp-call.sh --server answer42 recording_stop '{"session_id":"ui"}'
```

Без состояния формы, скриншота или записи задачу выполненной не объявлять.

## Запрещено

- Передавать логин/пароль в `start_session` — только credential-стор.
- Включать `--dev-tools` (`dev_eval` = произвольный BSL).
- Записывать и проводить в боевой ИБ без явной задачи оператора.
- Оставлять сессию живой: `stop_session(clean_data=true)` в конце.
- Трактовать пустой текст ошибки tool-call как «сбой платформы»: смотреть
  `current_error_info`, `user_messages`, лог `.tmp/answer42/http.err.log`.
