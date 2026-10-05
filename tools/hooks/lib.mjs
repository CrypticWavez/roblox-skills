// Shared helpers for Claude Code hooks (Node, so they run the same on Windows and Linux).
import { readFileSync } from "node:fs";

export function readEvent() {
	try {
		return JSON.parse(readFileSync(0, "utf8") || "{}");
	} catch {
		return {};
	}
}

// Credentials that must never land in the repo, logs or records.
export const SECRET_PATTERNS = [
	[/_\|WARNING:-DO-NOT-SHARE-THIS/, "Roblox .ROBLOSECURITY cookie"],
	[/-----BEGIN [A-Z ]*PRIVATE KEY-----/, "private key"],
	[/\bghp_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{60,}/, "GitHub token"],
	[/\bsk-ant-[A-Za-z0-9_-]{20,}/, "Anthropic API key"],
	[/\bsk-(proj-)?[A-Za-z0-9_-]{32,}/, "OpenAI-style API key"],
	[/\bAKIA[0-9A-Z]{16}\b/, "AWS access key"],
	[/\bxox[baprs]-[A-Za-z0-9-]{10,}/, "Slack token"],
	[/x-api-key["']?\s*[:=]\s*["'][A-Za-z0-9+/=_-]{40,}["']/i, "Roblox Open Cloud API key"],
];

export function findSecrets(text) {
	return SECRET_PATTERNS.filter(([re]) => re.test(text)).map(([, label]) => label);
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
