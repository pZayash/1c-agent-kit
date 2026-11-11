# LDD — binding для Node (JS/TS)

Стеко-нейтральный контракт: [core/docs/ai/ldd.md](../../../../core/docs/ai/ldd.md).
Здесь — только привязка к Node: чем писать, куда мапить события и уровни.

## Запись

| Аспект | Binding |
| --- | --- |
| Библиотека | `pino` (дефолт); fallback — `console` с JSON.stringify |
| Формат | структурный JSON на строку (pino из коробки) |
| Событие | поле `event` в объекте лога; dotted `<домен>.<операция>` (`order.submit`) |
| Wide event | один объект на операцию, копим поля, финальный emit в конце |

## Уровни

| Контракт | pino |
| --- | --- |
| ERROR | `log.error` (`err` — нативное поле для Error) |
| WARN | `log.warn` |
| INFO | `log.info` |
| DEBUG | `log.debug` / `log.trace` — выключены по умолчанию (`level: 'info'`) |

## Correlation

Request id — через `AsyncLocalStorage`; middleware хранит id на запрос,
child-logger (`log.child({ requestId })`) или hook подставляет в каждую
запись.

## Triage

| Задача | Инструмент |
| --- | --- |
| Тесты | vitest/jest — spy на методы logger, ассерт по аргументам |
| Прод/dev | stdout, `pino-pretty` для глаз, `jq` по JSON-строкам |
| Алерты | внешний сборщик (Sentry, Loki) — опционально, не часть контракта |
