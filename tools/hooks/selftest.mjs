// Feeds known-good and known-bad events to the guards so hook regressions fail the gate.
// Dangerous command strings are assembled at runtime so this file never trips the guard itself.
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const R = ["ro", "jo"].join("");
const cases = [
	["guard_bash.mjs", { tool_input: { command: `${R} upload --asset_id 1 default.project.json` } }, "deny"],
	["guard_bash.mjs", { tool_input: { command: "curl -X POST https://apis.roblox.com/assets/v1/assets" } }, "deny"],
	["guard_bash.mjs", { tool_input: { command: "git push --force origin main" } }, "deny"],
	["guard_bash.mjs", { tool_input: { command: "curl https://apis.roblox.com/cloud/v2/universes/1" } }, "allow"],
	["guard_bash.mjs", { tool_input: { command: "lune run tests/run.luau" } }, "allow"],
	["guard_bash.mjs", { tool_input: { command: `${R} build fixtures/creator.project.json -o build/x.rbxl` } }, "allow"],
	["guard_bash.mjs", { tool_input: { command: "grep -rn purchase packages" } }, "allow"],
	["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__insert_asset", tool_input: {} }, "ask"],
	["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__generate_mesh", tool_input: {} }, "ask"],
	[
		"guard_mcp.mjs",
		{ tool_name: "mcp__Roblox_Studio__execute_luau", tool_input: { code: 'game:GetService("AssetService"):CreatePlaceAsync("x", 1)' } },
		"deny",
	],
	["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__execute_luau", tool_input: { code: "store:SetAsync('k', 1)" } }, "ask"],
	["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__execute_luau", tool_input: { code: "print(workspace:GetChildren())" } }, "allow"],
	["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__screen_capture", tool_input: {} }, "allow"],
];
let failed = 0;
for (const [script, event, expected] of cases) {
	const r = spawnSync("node", [join(here, script)], { input: JSON.stringify(event), encoding: "utf8" });
	const got = r.stdout ? JSON.parse(r.stdout).hookSpecificOutput.permissionDecision : "allow";
	if (got !== expected) {
		failed++;
		console.log(`FAIL ${script} ${JSON.stringify(event.tool_input).slice(0, 80)}: expected ${expected}, got ${got}`);
	}
}
console.log(`${cases.length - failed}/${cases.length} hook cases`);
process.exit(failed ? 1 : 0);
