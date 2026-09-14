# pi overlay

Ресурсы [pi](https://pi.dev) для потребителей kit. Каталог линкуется в `.pi/`
потребителя скриптом [`scripts/link-pi-roots.*`](../scripts/) при
`bootstrap-kit`.

- `extensions/` → `.pi/extensions/` (auto-discovery pi). Сейчас:
  `auto-session-title.ts` — короткое имя сессии по первой задаче
  (TUI / RPC / print).
- `scripts/` — host-level утилиты, **не** линкуются:
  `patch-pi-acp-session-title.mjs` — проброс `session_info_changed` в ACP
  (Zed) для переименования чата.

Навыки pi берёт из `.agents/skills` (линк `link-editor-roots`), prompt
templates — из `.pi/prompts` (линк на `.cursor/commands`), контекст — из
`AGENTS.md`. Канон: [docs/ai/pi-harness.md](../docs/ai/pi-harness.md).
