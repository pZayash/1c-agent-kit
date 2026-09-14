#!/usr/bin/env node
/**
 * Идемпотентно добавляет в pi-acp проброс события pi `session_info_changed`
 * в ACP `session_info_update` (title). Без этого Zed не переименовывает
 * открытый чат, хотя имя уже записано в файл сессии pi.
 *
 * Запуск:  node ~/.pi/agent/patch-pi-acp-session-title.mjs
 *
 * Правка теряется при обновлении pi-acp из registry Zed — просто запустите
 * скрипт снова. Когда в pi-acp появится поддержка (upstream PR
 * "feat(acp): name sessions from initial prompts"), скрипт станет no-op
 * и его можно удалить.
 */

import { copyFileSync, existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const NEEDLE =
	'      default:\n        break;\n    }\n  }\n  async handleExtensionUiRequest(ev) {';

const INSERT =
	'      case "session_info_changed": {\n' +
	'        const name = typeof ev.name === "string" ? ev.name.trim() : "";\n' +
	"        if (name) {\n" +
	"          this.emit({\n" +
	'            sessionUpdate: "session_info_update",\n' +
	"            title: name,\n" +
	'            updatedAt: (/* @__PURE__ */ new Date()).toISOString()\n' +
	"          });\n" +
	"        }\n" +
	"        break;\n" +
	"      }\n";

const MARKER = 'case "session_info_changed"';

function findCandidates() {
	const roots = [];
	const local = process.env.LOCALAPPDATA;
	if (local) roots.push(join(local, "Zed", "external_agents", "registry"));
	// macOS / Linux
	roots.push(join(homedir(), ".local", "share", "zed", "external_agents", "registry"));
	roots.push(join(homedir(), "Library", "Application Support", "Zed", "external_agents", "registry"));

	const out = [];
	const stack = [...roots.filter(existsSync)];
	while (stack.length) {
		const dir = stack.pop();
		let entries;
		try {
			entries = readdirSync(dir, { withFileTypes: true });
		} catch {
			continue;
		}
		for (const e of entries) {
			const p = join(dir, e.name);
			if (e.isDirectory()) {
				stack.push(p);
			} else if (e.isFile() && e.name === "index.js" && p.replace(/\\/g, "/").includes("/pi-acp/dist/")) {
				out.push(p);
			}
		}
	}
	return out;
}

const candidates = findCandidates();
if (candidates.length === 0) {
	console.error("pi-acp dist/index.js не найден. Установлен ли pi-acp в Zed registry?");
	process.exit(1);
}

let patched = 0;
let already = 0;

for (const file of candidates) {
	const src = readFileSync(file, "utf8");
	if (src.includes(MARKER)) {
		console.log("уже пропатчен:", file);
		already++;
		continue;
	}
	if (!src.includes(NEEDLE)) {
		console.warn("не найден якорь (другая версия pi-acp?):", file);
		continue;
	}

	const backup = `${file}.orig`;
	if (!existsSync(backup)) copyFileSync(file, backup);

	writeFileSync(file, src.replace(NEEDLE, INSERT + NEEDLE), "utf8");
	console.log("пропатчен:", file);
	if (statSync(file).size === 0) {
		console.error("результат пустой — восстановите из", backup);
		process.exit(1);
	}
	patched++;
}

console.log(`\nГотово: пропатчено ${patched}, уже было ${already}.`);
console.log("Перезапустите чат/агента в Zed, чтобы изменения подхватились.");
