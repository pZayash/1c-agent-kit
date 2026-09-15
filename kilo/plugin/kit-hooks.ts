/**
 * kit-hooks — адаптер kit-agent для Kilo Code / OpenCode (plugin API).
 *
 * Источники истины — в kit (этот файл только адаптер):
 *   harness/tools/kit-agent/kit_agent.py  — session-start подсказки
 *   harness/tools/kit-agent/guards.json   — guard-правила для bash-команд
 *
 * Поведение:
 * - событие `session.created` → один фоновый вызов ядра; непустой вывод
 *   складывается в pendingHint;
 * - `experimental.chat.system.transform` → разовый инжект pendingHint в
 *   system prompt (это единственный документированный канал контекста;
 *   вызовы защищены проверкой формы output — API экспериментальный);
 * - `tool.execute.before` (bash) → оценка guards.json in-process;
 *   block → throw (Kilo прерывает вызов), warn → пропускаем.
 *
 * Адаптер НИКОГДА не роняет сессию: любая ошибка → тихий no-op.
 * Раскладка: .kilo/plugin → harness/kilo/plugin (kit-layout alias).
 *
 * Kilo = OpenCode-семейство (манифест: engines.opencode), поэтому этот же
 * adapter-паттерн применим к OpenCode без изменений логики.
 */

import type { Plugin } from "@kilocode/plugin";
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

const server: Plugin = async ({ directory, worktree }) => {
	const cwd = worktree || directory || process.cwd();
	const rel = process.env.HARNESS_REL || "harness";
	const harness = path.join(cwd, rel);
	const core = path.join(harness, "tools", "kit-agent", "kit_agent.py");

	let guards: CompiledGuard[] = [];
	let pendingHint: string | null = null;
	let hintInjected = false;

	if (existsSync(core)) {
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

	function runCore(): void {
		if (!existsSync(core)) return;
		execFile(
			"python",
			[core, "session-start", "--root", cwd],
			{ timeout: CORE_TIMEOUT_MS },
			(err, stdout) => {
				try {
					if (err || !stdout || !stdout.trim()) return;
					pendingHint = stdout.trim();
				} catch {
					/* no-op */
				}
			},
		);
	}

	function recordFriction(ruleId: string, kind: "block" | "warn", cmd: string): void {
		if (!existsSync(core)) return;
		// fire-and-forget: сигнал в memory/rule-friction (канон kit)
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

	return {
		event: async ({ event }: { event: { type?: string } }) => {
			try {
				if (event?.type === "session.created") runCore();
			} catch {
				/* no-op */
			}
		},

		"experimental.chat.system.transform": async (
			_input: unknown,
			output: { system?: string[] } | undefined,
		) => {
			try {
				if (!pendingHint || hintInjected) return;
				if (!output || !Array.isArray(output.system)) return;
				output.system.push(`[kit-agent] Состояние harness:\n${pendingHint}`);
				hintInjected = true;
			} catch {
				/* no-op */
			}
		},

		"tool.execute.before": async (
			input: { tool?: string },
			output: { args?: Record<string, unknown> } | undefined,
		) => {
			try {
				if (guards.length === 0) return;
				const args = output?.args;
				if (!args) return;
				const cmd =
					typeof args.command === "string"
						? args.command
						: typeof args.cmd === "string"
							? (args.cmd as string)
							: null;
				if (!cmd) return;
				for (const { re, rule } of guards) {
					if (!re.test(cmd)) continue;
					recordFriction(rule.id, rule.action, cmd);
					if (rule.action === "block") {
						throw new Error(`BLOCK [${rule.id}]: ${rule.message}`);
					}
					// warn: не блокируем (в plugin API нет документированного notify)
				}
			} catch (e) {
				// Отличаем наш block от внутренних ошибок адаптера: block
				// мы бросаем осознанно и он должен прервать вызов.
				if (e instanceof Error && e.message.startsWith("BLOCK [")) throw e;
			}
		},
	};
};

export default { id: "kit-hooks", server };
