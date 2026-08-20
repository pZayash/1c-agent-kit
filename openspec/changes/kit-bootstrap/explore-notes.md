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

## Поле 2026-08-20 (slot-1 + 42/features)

Новые ловушки (скрипт `scripts/fix-harness-gitdir.*`):

1. **Windows vs Linux:** один и тот же битый
   `harness/.git` = `gitdir: ../.git/modules/harness`. На 42/features
   **любой** `git status` в корне падает. В Docker slot-1 parent git
   жив, ломается только submodule.
2. **`worktrees/<name>/modules/harness` может не существовать** — submodule
   ни разу не init в этом wt. v77: путь есть; features: нет;
   `main/.git/modules/harness` на 42 тоже нет. COPY_FROM с живого wt.
3. **Untracked `harness/` vs gitlink `160000`:** slot-1 до merge — копия
   kit, HEAD без `.gitmodules`. `git merge` zayash не пройдёт, пока
   копию не снести. `git clean -fd` **не** удаляет каталог с файлом
   `.git` (nested repo) — `rm -rf harness`.
4. **42 fetch без TTY:** GCM `wincredman` + `/dev/tty` → origin/zayash
   застревает. **Не** HTTP. Канон:
   `git fetch D:\gitea-data\repositories\admin\unf_ru.git zayash`
   (см. `docs/ai/mailbox-srvkpsr42-prompt.md`). `credential.helper=`
   недостаточно — askpass всё равно лезет в `/dev/tty`.
   **`fetch.recurseSubmodules`:** после обновления `origin/zayash` git
   всё равно лезет в GitHub за `harness` и даёт **exit 1**, хотя ref
   уже обновлён. Канон: `-c fetch.recurseSubmodules=false`.
5. **Слот:** remote `kpsr` не `origin`; host worktree list = prunable
   (`/srv/agent-worktrees/agent-N` нет на Windows) — не prune.
6. **`git submodule update --init` с GitHub** в слоте просит Username
   (kit private / no TTY). `submodule sync` **затирает** local url
   обратно на GitHub. Канон: `git clone /srv/src.git/modules/harness`
   (`protocol.file.allow=always`) → перенести `.git` в
   `worktrees/agent-N/modules/harness`.
7. **Git Bash + `docker exec -C /work`:** MSYS превращает `/work` в
   `C:/Program Files/Git/work`. Канон: `docker exec bash -lc 'tar -C /work/...'`.
8. **Linux `git status` после bootstrap:** `.cursor/skills/.gitignore`
   паттерны `name/` не игнорят **symlink** (git видит файл). На Win
   junction ≈ dir — игнор работает. Slot-1: ~98 `??` skills. Phase 2:
   паттерн без `/` или `*`.
9. **gitdir copy без `checkout -f`:** features получил modules/harness
   с v77, working tree остался пустой/битый. Junctions на
   `explore/` смотрели в каталог без `SKILL.md`. После
   `git -C harness checkout -f HEAD` файлы появились.
10. **Старый `link-*.ps1` + leftover junction:** `Remove-Item` →
    NullRef на середине (form-compile). Повторный прогон падает на
    уже созданных junction. Канон: `bootstrap-kit` с `cmd rmdir`.
11. **Editor roots** ещё не в kit `02a4097` (грязный working tree).
    Overlay `link-editor-roots.*` до bump.
