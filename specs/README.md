# specs/

Spec-флоу kit: изменения самого `1c-agent-kit` ведутся через `kit_spec` —
тот же инструмент, что и у потребителей (dogfood).

- `changes/<id>/` — активные changes (`proposal.md`, `design.md`, `tasks.md`);
- `changes/archive/` — завершённые (`YYYY-MM-DD-<id>`);
- `<cap>/spec.md` — библиотека слитых спек (пока пусто);
- `openspec/` в корне — junction-shim для старых ссылок (в `.gitignore`).

Канон: [core/docs/ai/spec-workflow.md](../core/docs/ai/spec-workflow.md).
Инструмент: `python tools/kit-spec/kit_spec.py` (в kit — без `harness/`
префикса). Вход — скилл `spec-propose`.

История до миграции с `openspec/` — в git.
