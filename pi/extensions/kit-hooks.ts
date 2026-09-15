/**
 * kit-hooks — адаптер kit-agent для pi (TUI + RPC/ACP: bb, Zed).
 *
 * Источники истины — в kit, этот файл — тонкий адаптер:
 *   harness/tools/kit-agent/kit_agent.py  — session-start подсказки
 *   harness/tools/kit-agent/guards.json   — guard-правила для bash-команд
 *
 * Поведение:
 * - session_start: один фоновый вызов ядра (таймаут 15с). Непустой вывод →
 *   notify (TUI/RPC) + разовый инжект в контекст на первом промпте
 *   (before_agent_start).
 * - tool_call (bash): оценка команды по guards.json in-process (regex,
 *   без subprocess). block → { block: true }; warn → notify, пропускаем.
 * - /kit — ручной прогон session-start проверок.
 *
 * Адаптер НИКОГДА не роняет сессию: любые ошибки → тихий no-op.
 * Раскладка в потребителя: .pi/extensions → harness/pi/extensions
 * (kit-layout alias pi-extensions).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import * as path from "node:path";

interface GuardRule {
	id: string;
	match: string;
	action: "block" | "warn";
	message: string;
}

interface CompiledGuard {
	re: RegExp;
	rule: GuardRule;
}

const CORE_TIMEOUT_MS = 15_000;

export default function (pi: ExtensionAPI) {
	let corePath: string | null = null;
	let harnessDir: string | null = null;
	let guards: CompiledGuard[] = [];
	let pendingHint: string | null = null;

	function init(cwd: string): void {
		const rel = process.env.HARNESS_REL || "harness";
		const harness = path.join(cwd, rel);
		const core = path.join(harness, "tools", "kit-agent", "kit_agent.py");
		if (!existsSync(core)) return; // kit не подключен — тихий no-op
		harnessDir = harness;
		corePath = core;
		try {
			const raw = readFileSync(
				path.join(harness, "tools", "kit-agent", "guards.json"),
				"utf8",
			);
			const parsed = JSON.parse(raw) as { rules: GuardRule[] };
			guards = parsed.rules.flatMap((rule) => {
				try {
					return [{ re: new RegExp(rule.match), rule }];
				} catch {
					return [];
				}
			});
		} catch {
			guards = [];
		}
	}

	function runCoreSessionStart(cwd: string, onHint: (hint: string) => void): void {
		if (!corePath) return;
		execFile(
			"python",
			[corePath, "session-start", "--root", cwd],
			{ timeout: CORE_TIMEOUT_MS },
			(err, stdout) => {
				if (err || !stdout || !stdout.trim()) return;
				onHint(stdout.trim());
			},
		);
	}

	pi.on("session_start", async (_event, ctx) => {
		try {
			init(ctx.cwd);
			if (!corePath) return;
			runCoreSessionStart(ctx.cwd, (hint) => {
				pendingHint = hint;
				if (ctx.hasUI) ctx.ui.notify(hint, "warning");
			});
		} catch {
			/* no-op */
		}
	});

	pi.on("before_agent_start", async (_event, _ctx) => {
		if (!pendingHint) return undefined;
		const hint = pendingHint;
		pendingHint = null;
		return {
			message: {
				customType: "kit-hooks",
				content: `[kit-agent] Состояние harness:\n${hint}`,
				display: true,
			},
		};
	});

	pi.on("tool_call", async (event, ctx) => {
		try {
			if (event.toolName !== "bash" || guards.length === 0) return undefined;
			const cmd = (event.input as { command?: string })?.command;
			if (!cmd) return undefined;
			for (const { re, rule } of guards) {
				if (!re.test(cmd)) continue;
				if (rule.action === "block") {
					return { block: true, reason: `BLOCK [${rule.id}]: ${rule.message}` };
				}
				if (ctx.hasUI) ctx.ui.notify(`WARN [${rule.id}]: ${rule.message}`, "warning");
			}
		} catch {
			/* no-op */
		}
		return undefined;
	});

	pi.registerCommand("kit", {
		description: "kit-agent: прогнать session-start проверки harness",
		handler: async (_args, ctx) => {
			if (!corePath) init(ctx.cwd);
			if (!corePath) {
				if (ctx.hasUI) ctx.ui.notify("kit не подключен (нет harness/)", "info");
				return;
			}
			execFile(
				"python",
				[corePath, "session-start", "--root", ctx.cwd],
				{ timeout: CORE_TIMEOUT_MS },
				(err, stdout) => {
					if (!ctx.hasUI) return;
					if (err) {
						ctx.ui.notify("kit-agent: ошибка ядра (no-op)", "warning");
					} else if (stdout && stdout.trim()) {
						ctx.ui.notify(stdout.trim(), "warning");
					} else {
						ctx.ui.notify("kit-agent: harness в порядке", "info");
					}
				},
			);
		},
	});
}
