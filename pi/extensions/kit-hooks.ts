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

	function runCoreSessionStart(
		cwd: string,
		onHint: (hint: string) => void,
	): void {
		const core = corePath;
		if (!core) return;
		execFile(
			"python",
			[core, "session-start", "--root", cwd],
			{ timeout: CORE_TIMEOUT_MS },
			(err, stdout) => {
				// Никогда не трогаем ctx/host-объекты здесь: после завершения
				// сессии/команды они становятся stale. Только данные.
				try {
					if (err || !stdout || !stdout.trim()) return;
					onHint(stdout.trim());
				} catch {
					/* no-op */
				}
			},
		);
	}

	pi.on("session_start", async (_event, ctx) => {
		try {
			init(ctx.cwd);
			if (!corePath) return;
			const hasUI = ctx.hasUI;
			const ui = ctx.ui;
			runCoreSessionStart(ctx.cwd, (hint) => {
				pendingHint = hint;
				if (!hasUI) return;
				try {
					ui.notify(hint, "warning");
				} catch {
					/* stale ui — skip */
				}
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

	function recordFriction(
		cwd: string,
		ruleId: string,
		kind: "block" | "warn",
		cmd: string,
	): void {
		const core = corePath;
		if (!core) return;
		// fire-and-forget: сигнал в memory/rule-friction (канон kit), не ждём
		execFile(
			"python",
			[
				core,
				"record-friction",
				"--root",
				cwd,
				"--rule-id",
				ruleId,
				"--kind",
				kind,
				"--command",
				cmd.slice(0, 300),
			],
			{ timeout: 5000 },
			() => {
				/* best-effort */
			},
		);
	}

	pi.on("tool_call", async (event, ctx) => {
		try {
			if (event.toolName !== "bash" || guards.length === 0) return undefined;
			const cmd = (event.input as { command?: string })?.command;
			if (!cmd) return undefined;
			const cwd = ctx.cwd;
			const hasUI = ctx.hasUI;
			const ui = ctx.ui;
			for (const { re, rule } of guards) {
				if (!re.test(cmd)) continue;
				recordFriction(cwd, rule.id, rule.action, cmd);
				if (rule.action === "block") {
					return { block: true, reason: `BLOCK [${rule.id}]: ${rule.message}` };
				}
				if (hasUI) {
					try {
						ui.notify(`WARN [${rule.id}]: ${rule.message}`, "warning");
					} catch {
						/* stale ui — skip */
					}
				}
			}
		} catch {
			/* no-op */
		}
		return undefined;
	});

	pi.registerCommand("kit", {
		description: "kit-agent: прогнать session-start проверки harness",
		handler: async (_args, ctx) => {
			try {
				if (!corePath) init(ctx.cwd);
				if (!corePath) {
					if (ctx.hasUI) ctx.ui.notify("kit не подключен (нет harness/)", "info");
					return;
				}
				const cwd = ctx.cwd;
				const hasUI = ctx.hasUI;
				const ui = ctx.ui;
				const core = corePath;
				execFile(
					"python",
					[core, "session-start", "--root", cwd],
					{ timeout: CORE_TIMEOUT_MS },
					(err, stdout) => {
						// ctx в колбэке может быть stale — работаем только с
						// зафиксированными hasUI/ui, любые сбои — no-op.
						try {
							if (!hasUI) return;
							if (err) {
								ui.notify("kit-agent: ошибка ядра (no-op)", "warning");
							} else if (stdout && stdout.trim()) {
								ui.notify(stdout.trim(), "warning");
							} else {
								ui.notify("kit-agent: harness в порядке", "info");
							}
						} catch {
							/* stale ui — skip */
						}
					},
				);
			} catch {
				/* no-op */
			}
		},
	});
}
