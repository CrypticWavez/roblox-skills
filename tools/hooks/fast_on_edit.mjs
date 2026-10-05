// FAST_ON_EDIT tier (PostToolUse on Edit/Write/MultiEdit). Checks only the touched file and
// finishes in well under a second: secret scan, JSON validity, StyLua check for Luau,
// SKILL.md frontmatter, and a reminder when a skill is edited outside .agents/skills.
// Exit 2 sends the message back to Claude; it never blocks or rewrites anything.
import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { basename, relative, sep } from "node:path";
import { findSecrets, readEvent } from "./lib.mjs";

const event = readEvent();
const file = event.tool_input?.file_path;
if (!file || !existsSync(file)) process.exit(0);
const root = process.env.CLAUDE_PROJECT_DIR || process.cwd();
const rel = relative(root, file).split(sep).join("/");
const problems = [];
let text = "";
try {
	text = readFileSync(file, "utf8");
} catch {
	process.exit(0);
}

const secrets = findSecrets(text);
if (secrets.length) problems.push(`possible secret (${secrets.join(", ")}) in ${rel}: remove it and rotate the credential`);

if (file.endsWith(".json")) {
	try {
		JSON.parse(text);
	} catch (err) {
		problems.push(`invalid JSON in ${rel}: ${err.message}`);
	}
}

if (file.endsWith(".luau") || file.endsWith(".lua")) {
	const stylua = spawnSync("stylua", ["--check", file], { cwd: root, encoding: "utf8", timeout: 5000 });
	if (stylua.error === undefined && stylua.status === 1) problems.push(`${rel} is not StyLua-formatted: run \`stylua ${rel}\``);
	if (stylua.status === 2) problems.push(`StyLua could not parse ${rel}: ${(stylua.stderr || "").split("\n")[0]}`);
}

if (basename(file) === "SKILL.md") {
	if (!text.startsWith("---\n") && !text.startsWith("---\r\n")) problems.push(`${rel}: SKILL.md must start with --- frontmatter`);
	if (rel.startsWith(".claude/skills/")) problems.push(`${rel} is generated: edit .agents/skills/ and run \`python3 tools/sync_skills.py\``);
}

if (problems.length) {
	process.stderr.write(problems.join("\n") + "\n");
	process.exit(2);
}
