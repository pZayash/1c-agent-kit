## Старт сессии и guard-правила (kit)

В начале сессии выполни:

```bash
python harness/tools/kit-agent/kit_agent.py session-start
```

Пустой вывод — всё в порядке. Непустой — следуй подсказкам (обычно: обновить
harness и `bash harness/scripts/bootstrap-kit.sh .`, или закоммитить bump
gitlink).

Перед bash-командами с `git`/`rm` по путям kit (`harness/`, `.cursor/`, `.pi/`,
`.agents/`, `.claude/`) и перед `openspec init` / `rtk init` проверяй команду:

```bash
python harness/tools/kit-agent/kit_agent.py check-command "<команда>"
```

exit 1 — команда запрещена (вывод объясняет канон, например promote вместо
blob). `WARN` — можно, но прочти предупреждение. В pi и Kilo/OpenCode эти
правила применяет автоматика (`.pi/extensions/kit-hooks.ts`,
`.kilo/plugin/`), и каждое срабатывание пишется friction-сигналом в
`memory/rule-friction/` (канон: `memory-format.md` § Разлад, разбор —
skill `evolve`). Session-start отдельно напомнит про неразобранные сигналы.
