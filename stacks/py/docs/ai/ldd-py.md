# LDD — binding для Python

Стеко-нейтральный контракт: [core/docs/ai/ldd.md](../../../../core/docs/ai/ldd.md).
Здесь — только привязка к Python: чем писать, куда мапить события и уровни.

## Запись

| Аспект | Binding |
| --- | --- |
| Библиотека | stdlib `logging` (дефолт) или `structlog` (если уже в проекте) |
| Формат | структурный JSON на строку — `python-json-logger`/`structlog` JSONRenderer |
| Событие | имя логгера или поле `event`; dotted `<домен>.<операция>` (`order.submit`) |
| Wide event | один dict на операцию, копим поля, финальный emit в конце |

## Уровни

| Контракт | Python |
| --- | --- |
| ERROR | `logger.error` / `logger.exception` (со stack trace) |
| WARN | `logger.warning` |
| INFO | `logger.info` |
| DEBUG | `logger.debug` — выключен по умолчанию (`level=INFO`) |

## Correlation

Request/task id — через `contextvars.ContextVar` + `logging.Filter`,
подставляющий id в каждую запись. Веб-фреймворк — middleware ставит
contextvar в начале запроса.

## Triage

| Задача | Инструмент |
| --- | --- |
| Тесты | `pytest` + фикстура `caplog` (ассерт по `record.event`/полям) |
| Прод/dev | `tail -f` файла или stdout, `jq` по JSON-строкам |
| Алерты | внешний сборщик (Sentry, Loki) — опционально, не часть контракта |
