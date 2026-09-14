# Синхронизация cc-1c-skills в Kit (1c-agent-kit)

Канон sync — **в этом репозитории**, не в потребителе.

## Быстрый старт (maintainer kit)

```bash
# Первый раз — в корне kit-репо
git clone https://github.com/Nikolay-Shirokov/cc-1c-skills.git tools/cc-1c-skills

# Sync upstream → skills/cc-1c/
python tools/cc-1c-skills-sync/sync.py

# План без записи
python tools/cc-1c-skills-sync/sync.py --dry-run
```

После sync: commit kit → push → bump gitlink `harness/` у потребителей →
`scripts/link-cc-1c-skills` у потребителя.

## Политика

| Тема | Решение |
| --- | --- |
| Target | `skills/cc-1c/` (в git kit) |
| Исключены | `db-load-*`, `db-update`, `db-dump-dt`, `web-test` (срез 1) |
| meta-* | После sync — `apply-meta-xml-patches.py` (overlay в `overlays/`) |
| Sandbox в SKILL.md | `bash tools/sandbox/run.sh python` (потребительский sandbox) |
| Потребитель | junction `.cursor/skills/<name>` → `harness/skills/cc-1c/<name>` |

## meta-* overlay

Патчи LoadConfigFromFiles (`Number(D,0)`, `cfg:`, CR entities, …) хранятся в
`tools/cc-1c-skills-sync/overlays/meta-{edit,compile,validate}/`.
Обновление overlay — вручную после правок в `.py`, затем commit kit.

## Initial vendor (миграция)

Из пилота-потребителя: `tools/cc-1c-skills-sync/vendor-to-kit.py` (один раз).

Манифест: `last-sync.json`.
