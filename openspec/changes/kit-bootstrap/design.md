# Design: kit-bootstrap

## Цель

Надёжный bootstrap **1c-agent-kit** у потребителя на Windows и Linux без
ручных обходов и без порчи git status.

## Контекст проблемы (проверено в поле)

1. `harness/scripts/link-*.sh` вызывают `powershell.exe` → в Linux Docker
   бесполезны.
2. Linux wiring жил в пилоте
   (`docker/agent-container/link-kit-in-worktree-linux.sh`), не в kit.
3. `Remove-Item` на junction → `NullReferenceException`; нужно `rmdir`.
4. «Skill есть» ≠ kit link: копии выглядят ок, ReparsePoint=False.
5. REPLACE COPY на tracked skills → сотни `D` в git; порядок: merge ветки с
   untrack → link.
6. Worktree: относительный `harness/.git` → `../.git/modules/harness` ломается,
   когда `.git` потребителя — файл. Offline copy без починки gitdir ломает
   `git status`.

## Подход (H1 MVP)

```text
bootstrap-kit
  ├─ check harness/ present (@ expected gitlink ideally)
  ├─ link-cc-1c (Win: /J, Linux: ln -sfn)
  ├─ link-cursor-overlay
  ├─ link-kit-tools
  ├─ link-editor-roots (.agents/skills, .claude/skills|commands)
  ├─ ensure thin load-changed-files.sh wrapper (warn if fat legacy)
  └─ verify-kit-links → non-zero if key paths not reparse/symlink
```

### Windows

- Каталоги skills/tools: `mklink /J`.
- Rules/commands (файлы): `mklink` (Developer Mode) или copy-fallback (уже есть).
- Удаление старого reparse: **только** `cmd /c rmdir "path"` (dirs) /
  `cmd /c del` (files), не `Remove-Item -Force` на reparse.

### Linux

- **`link-*.sh` — нативные bash** (`ln -sfn`), без вызова `powershell.exe`.
  Windows остаётся на `.ps1` (`mklink /J` / file `mklink`).
- Логику пилотного `docker/agent-container/link-kit-in-worktree-linux.sh`
  влить в kit; в пилоте оставить **thin wrapper** → `harness/scripts/…`
  (или удалить + обновить README слота).
- Manifest LOCAL: те же `local-skills.txt` / `local-overlay.txt` /
  `local-tools.txt` у потребителя.

### Verify

Минимум путей (оба OS):

- `.cursor/skills/handoff`
- `.cursor/skills/mailbox`
- `tools/mailbox`
- `tools/load-changed-files` (если не LOCAL)

Критерий: symlink/junction (reparse), не обычный каталог.

### Docs (pitfalls)

В `harness/README.md` (короткий блок) + детали здесь / explore-notes:

- Как проверить junction (`ReparsePoint`, `dir /AL`).
- Порядок на старом worktree: merge wiring → hydrate harness → bootstrap →
  verify.
- Worktree gitdir: абсолютный путь к
  `<main>/.git/worktrees/<name>/modules/harness`.
  Скрипт `fix-harness-gitdir`; `-CopyFrom` если каталога нет.
  Emergency: rename `harness` → parent git оживает.
- Нет GitHub creds / GCM без TTY: bundle/copy + pin SHA
  (ручной fallback phase 1).
- CRLF в `.sh` с Windows → `tr -d '\r'` перед запуском в Linux.
- Untracked `harness/` vs incoming gitlink: удалить копию до merge.
- Docker slot: merge `kpsr/zayash` (не `origin`); не `worktree prune`
  с хоста.

## Вне scope (явно)

- OpenSpec CLI / `openspec/config.yaml` в kit.
- Автоматический hydrate-from-bundle.
- Правки Docker image (`unzip` для BSLLS) — потребитель/слот.
- Изменение пилотного `cc-1c-skills-in-kit`.

## Риски и допущения

| Риск | Митигация |
| --- | --- |
| Два мира `.sh` (PS vs native) | Один контракт CLI; Win → `.ps1`, Linux → native bash |
| Thin wrapper затрёт толстый local load script | bootstrap: warn + флаг `--force-wrapper` |
| Verify ломает CI без Developer Mode | file links: warn; dir junctions — fail |

## Критерии готовности apply

- [x] Linux: один вход поднимает links без powershell (`bootstrap-kit.sh`).
- [x] Win: повторный bootstrap не падает на существующих junction (`rmdir`).
- [x] `verify-kit-links` отличает копию от link и проверяет `.agents/skills`.
- [x] README kit: pitfalls + порядок bootstrap.
- [x] Пилотный `docker/agent-container/link-kit-in-worktree-linux.sh` —
      thin wrapper на `harness/scripts/bootstrap-kit.sh`.

Apply: 2026-08-20.

## Follow-up сессии

1. Apply этого design (commit kit → bump).
2. OpenSpec-in-kit: включить CLI на `harness/openspec/`, формализовать
   `proposal`/`tasks` из этих файлов.
