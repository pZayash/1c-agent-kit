# Explore notes: kit-bootstrap

Дата: 2026-08-20. Режим: `/explore`, артефакты только в `harness/`.

## Намерение

Сделать подъём kit на любом worktree (Windows SRVKPSR42 / Linux Docker-слот)
предсказуемым: harness @ gitlink SHA → links → verify. Убрать ложные «OK»
(копии skills вместо junction/symlink) и грязный git после REPLACE COPY.

## Постановщик и роли

- **Постановщик (личность):** Заяш (Павел), в постановке — **Автор**.
- **Роль:** [Владелец харнеса](../../../../ROLES.md) (пилот `ROLES.md`).
- **Потребитель:** Разработчик-архитектор конфигурации (worktree пилота / 42 /
  agent-slot) — пользуется bootstrap, не владеет kit-репо.

## Связанное

- Пилот `openspec/changes/cc-1c-skills-in-kit` — смежная тема (H1 junctions);
  **не** расширять этим change.
- Черновик Linux wiring сейчас в пилоте:
  `docker/agent-container/link-kit-in-worktree-linux.sh` — канон перенести в kit.

## Гипотезы (выбор)

| # | Суть | Решение |
| --- | --- | --- |
| H1 | Linux links + fix rmdir + bootstrap/verify + docs | **выбрана** |
| H2 | Только docs | отклонена |
| H3 | Только Linux | отклонена |
| H4 | + OpenSpec-in-kit сразу | отложена (другая сессия) |

## MVP phase 1 (согласовано)

Входит:

1. Native Linux link/orchestrator в `harness/scripts/`.
2. Fix удаления junction в `.ps1` (`cmd /c rmdir`, не `Remove-Item` на reparse).
3. `bootstrap-kit` + `verify-kit-links` (Win + Linux).
4. Docs: pitfalls в README kit / этот change.

Не входит (phase 2+):

- Скрипт hydrate-from-bundle / offline submodule.
- `unzip` в Docker image слота.
- OpenSpec CLI внутри kit.

## Место артефактов

`harness/openspec/changes/kit-bootstrap/` — staging под будущий OpenSpec-in-kit.
Альтернатива `harness/spec/` отклонена (лишняя конвенция).

## Пачка 3 (закрыто)

1. Linux: нативные `link-*.sh` (не powershell).
2. Пилотный docker linux-скрипт → thin wrapper на kit после promote.
3. Explore достаточно; дальше — **apply-сессия** по `design.md`, не
   `openspec-propose` в пилоте.

## Language (черновик → согласовано в explore)

| Термин | Канон | Avoid |
| --- | --- | --- |
| **Kit bootstrap** | Подъём links+verify у потребителя после submodule | «установка skills», «sync.cc-1c» |
| **Kit link** | Junction (Win `/J`) или symlink (Linux) на дерево kit | «копия skill», «vendor в .cursor» |
| **Kit verify** | Проверка reparse/`-L` на ключевых путях | «Test-Path папки» без reparse |
| **OpenSpec staging (kit)** | `harness/openspec/` до CLI | пилотный `openspec/changes/` для правок kit |

Полные определения при promote можно поднять в kit glossary / CONTEXT kit,
когда появится.
