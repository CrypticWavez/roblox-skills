// Shared helpers for Claude Code hooks (Node, so they run the same on Windows and Linux).
import { readFileSync } from "node:fs";

export function readEvent() {
	try {
		return JSON.parse(readFileSync(0, "utf8") || "{}");
	} catch {
		return {};
	}
}

// Credentials that must never land in the repo, logs or records. The list lives in
// secret-patterns.json so tools/check.py scans for exactly the same set. It is loaded lazily:
// the PreToolUse guards import this module and must not depend on that file.
export const SECRET_PATTERNS_FILE = new URL("./secret-patterns.json", import.meta.url);
let patterns;
export function secretPatterns() {
	patterns ??= JSON.parse(readFileSync(SECRET_PATTERNS_FILE, "utf8")).patterns.map((p) => [new RegExp(p.pattern, p.flags || ""), p.label]);
	return patterns;
}

export function findSecrets(text) {
	return [...new Set(secretPatterns().filter(([re]) => re.test(text)).map(([, label]) => label))];
}

// PreToolUse decision helper: "deny" blocks, "ask" forces a confirmation prompt.
export function decide(decision, reason) {
	process.stdout.write(
		JSON.stringify({
			hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: decision, permissionDecisionReason: reason },
		}),
	);
	process.exit(0);
}
