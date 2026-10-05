// PreToolUse guard for Bash. Blocks commands that publish, upload, spend or rewrite shared
// history; asks before production DataStore/Open Cloud writes. Hooks never publish anything.
import { decide, readEvent } from "./lib.mjs";

const cmd = readEvent().tool_input?.command || "";
const DENY = [
	[/\brojo\s+upload\b/, "rojo upload publishes a place"],
	[/\b(mantle|rbxcloud)\b[^\n]*\b(deploy|publish|upload|create)\b/i, "deploy/publish/upload tool"],
	[/\btarmac\s+sync\b[^\n]*--target\s+roblox/i, "tarmac sync uploads assets"],
	[/apis\.roblox\.com\/(universes|assets|cloud)[^\s'"]*/i, "Roblox Open Cloud write endpoint", (c) => /-X\s*(POST|PUT|PATCH|DELETE)|--request\s+(POST|PUT|PATCH|DELETE)|--data|-d\s|Invoke-RestMethod|Invoke-WebRequest/i.test(c)],
	[/\bgit\s+push\b[^\n]*(--force\b|-f\b)[^\n]*\b(main|master)\b/, "force-push to main"],
];
for (const [re, why, extra] of DENY) {
	if (re.test(cmd) && (!extra || extra(cmd))) decide("deny", `Blocked by factory guard: ${why}. SETUP_ONLY forbids publishing, uploads and spending without Ethan's explicit approval.`);
}
if (/weppy-project-sync/.test(cmd) && /\b(rm|mv|del|Remove-Item|>)\b/.test(cmd)) {
	decide("deny", "weppy-project-sync/ is outside this setup's ownership; do not modify it.");
}
process.exit(0);
