// Shared helpers for the Claude Code and Codex hooks (Node, so they run the same on Windows and Linux).
import { readFileSync } from "node:fs";

// Codex (0.160) PreToolUse hooks can block only with "deny": an "ask" is reported as unsupported and
// the tool call then runs. So under Codex every ask becomes a deny. Codex is recognised by the
// --client=codex flag that .codex/hooks.json passes, or by the turn_id field Codex events carry.
let codex = process.argv.includes("--client=codex");

export function readEvent() {
	try {
		const event = JSON.parse(readFileSync(0, "utf8") || "{}");
		codex ||= event.turn_id !== undefined;
		return event;
	} catch {
		return {};
	}
}

// ---- shared by guard_bash (inline scripts) and guard_mcp (Blender Python, Luau) ---------------------
export const ROBLOX_HOST = /\b(?:[a-z0-9-]+\.)*ro(?:blox|proxy)\.com\b/i;
// Code that sends a body or a POST/PUT/PATCH/DELETE.
export const SCRIPT_WRITE = new RegExp(
	[
		String.raw`(?:\.|->|::)\s*(?:post|put|patch|delete)(?:_?form|async)?\s*\(`, // requests.post( axios.put( $ua->post( Net::HTTP.post( client.PostAsync( HttpService:PostAsync(
		String.raw`\bmethod\s*(?:[:=]|=>)\s*:?["'\x60]?(?:post|put|patch|delete)\b`, // fetch {method: 'POST'}, Request(method="PUT"), RequestAsync({Method="POST"})
		String.raw`\brequest\s*\(\s*["'\x60](?:post|put|patch|delete)["'\x60]`, // http.client / urllib3 / requests.request("POST", ...)
		String.raw`-Method\s*:?\s*["']?(?:post|put|patch|delete)\b`,
		String.raw`[(,]\s*data\s*=`, // urllib.request.Request(url, data=...) sends a POST
		String.raw`\burlopen\s*\(\s*(?:[^(),]|\([^()]*\))+,\s*(?!timeout\s*=|context\s*=|cafile\s*=|capath\s*=|cadefault\s*=|None\b)[^\s)]`, // urlopen(url, body)
		String.raw`::(?:Post|Put|Patch|Delete)\b`, // Net::HTTP::Post
		String.raw`\bUpload(?:File|Data|String|Values)(?:Async|TaskAsync)?\b`, // .NET WebClient
		String.raw`HttpMethod\]?\s*(?:\.|::)\s*(?:Post|Put|Patch|Delete)\b`,
		String.raw`\bCURLOPT_(?:POST|POSTFIELDS|CUSTOMREQUEST|UPLOAD|PUT)\b`,
	].join("|"),
	"i",
);
// Code (inline scripts, Blender Python) that starts a publishing tool, e.g. os.system('rojo upload')
// or subprocess.run(['rbxcloud', 'assets', 'create', ...]).
export const CODE_PUBLISH = /\brojo(?:\.exe)?\b[^\n]{0,80}?\bupload\b|\bmantle\b[^\n]{0,40}?\b(?:deploy|destroy)\b|\btarmac\b[^\n]{0,80}?\b(?:upload-image|sync)\b|\basphalt\b[^\n]{0,40}?\b(?:sync|upload)\b|\brbxcloud\b[^\n]{0,80}?\b(?:publish|create|update|set|delete|increment|remove|archive|restore|execute|send)\b/i;
// Code that runs an HTTP command-line client with a write flag (subprocess.run(['curl', '-XPOST', url])).
export const CODE_HTTP_CLI_WRITE = /\b(?:curl|wget|xh|https?(?!:))\b[^\n]{0,200}?(?:-X\s*['"]?\s*(?:POST|PUT|PATCH|DELETE)\b|--?(?:data|form|json|upload|post|body|method)\b|\bPOST\b|['"]-[dFT]['"])/i;

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

// PreToolUse decision helper: "deny" blocks, "ask" forces a confirmation prompt (a deny in Codex).
export function decide(decision, reason) {
	if (decision === "ask" && codex) {
		decision = "deny";
		reason += " Codex hooks cannot ask, so this is blocked in Codex: run it from Claude Code (which asks) or have Ethan do it by hand.";
	}
	process.stdout.write(
		JSON.stringify({
			hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: decision, permissionDecisionReason: reason },
		}),
	);
	process.exit(0);
}
