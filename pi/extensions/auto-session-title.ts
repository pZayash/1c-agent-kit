/**
 * auto-session-title — автоматически называет новую сессию pi коротким
 * заголовком-суммаризацией первой задачи пользователя.
 *
 * Установка: этот файл в ~/.pi/agent/extensions/auto-session-title.ts
 * (глобально) или <проект>/.pi/extensions/ (локально). Подхватывается
 * автоматически, работает в TUI, RPC (ACP/Zed) и print-режимах.
 *
 * Поведение:
 * - срабатывает один раз за сессию и только если имя ещё не задано;
 * - ручное /name (или --name) всегда имеет приоритет;
 * - вызов модели идёт в фоне и не задерживает ответ агента;
 * - любая ошибка генерации тихо игнорируется.
 *
 * Требуется pi >= 0.81 (ExtensionAPI.setSessionName / modelRegistry.complete).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const MAX_TITLE_CHARS = 60;
const MAX_TASK_CHARS = 6000;

const TITLE_PROMPT = [
	"You create short titles for coding-agent chat sessions.",
	"Read the user's task below and produce a title for this session.",
	"Rules:",
	"- Write the title in the same language as the task.",
	"- 3 to 8 words, at most 60 characters.",
	"- Describe the goal, not the tools.",
	"- No quotes, no trailing punctuation, no prefixes like 'Title:'.",
	"Reply with the title only.",
].join("\n");

function sanitizeTitle(raw: string): string | null {
	const firstLine = raw
		.split(/\r?\n/)
		.map((line) => line.trim())
		.find((line) => line.length > 0);
	if (!firstLine) return null;

	let title = firstLine
		.replace(/^[#>*\-\s]+/, "")
		.replace(/^(?:title|заголовок|название)\s*[:：-]\s*/i, "")
		.replace(/^["'«»“”`]+/, "")
		.replace(/["'«»“”`]+$/, "")
		.replace(/[.,;:!?]+$/, "")
		.trim();

	if (title.length > MAX_TITLE_CHARS) {
		title = title
			.slice(0, MAX_TITLE_CHARS)
			.replace(/\s+\S*$/, "")
			.trim();
	}

	return title.length > 0 ? title : null;
}

export default function (pi: ExtensionAPI) {
	let firstTask: string | null = null;
	let attempted = false;

	const reset = () => {
		firstTask = null;
		attempted = false;
	};

	pi.on("session_start", () => {
		reset();
	});

	// Запоминаем первую пользовательскую реплику, но не тратим на неё модель:
	// заголовок генерируем после первого завершённого хода.
	pi.on("input", (event) => {
		if (firstTask !== null || attempted) return;
		if (event.source === "extension") return;
		const text = event.text.trim();
		if (!text || text.startsWith("/")) return;
		firstTask = text.slice(0, MAX_TASK_CHARS);
	});

	pi.on("agent_settled", (_event, ctx) => {
		if (attempted || firstTask === null) return;
		attempted = true;

		const task = firstTask;
		if (pi.getSessionName()) return;

		// Fire-and-forget: не блокируем завершение хода и ACP session/prompt.
		void (async () => {
			try {
				const model = ctx.model;
				if (!model) return;
				if (!ctx.modelRegistry.hasConfiguredAuth(model)) return;

				const response = await ctx.modelRegistry.complete(model, {
					messages: [
						{
							role: "user",
							content: [
								{
									type: "text",
									text: `${TITLE_PROMPT}\n\n<task>\n${task}\n</task>`,
								},
							],
							timestamp: Date.now(),
						},
					],
				});

				// Пользователь мог переименовать сессию, пока шёл вызов модели.
				if (pi.getSessionName()) return;

				const text = response.content
					.filter((part): part is { type: "text"; text: string } => part.type === "text")
					.map((part) => part.text)
					.join("\n");

				const title = sanitizeTitle(text);
				if (title) pi.setSessionName(title);
			} catch {
				// best-effort: ошибки генерации заголовка не должны ломать сессию
			}
		})();
	});
}
