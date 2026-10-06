// Feeds known-good and known-bad events to the guards so hook regressions fail the gate, in both
// directions: every deny/ask class has a case, and so do the reads that must stay allowed.
// Codex parity: reruns the cases through the .codex/hooks.json commands (Bash, file edits, every MCP
// tool), evaluates .codex/rules/factory.rules against the Bash cases, and checks .codex/config.toml
// against .mcp.json and the MCP guard (prompted tools = asked, disabled tools = denied, all 26 Studio
// tools classified).
// Also checks that tools/check.py and the edit hook flag the same secrets from secret-patterns.json.
// Dangerous command strings and fake credentials are assembled at runtime so this file never trips
// the guard or the secret scan itself.
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { findSecrets, secretPatterns } from "./lib.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const python = process.env.FACTORY_PYTHON || (process.platform === "win32" ? "python" : "python3");
// The tools mcp-for-blender 2.1.8 registers (FastMCP list_tools(); the last five are MCP-Apps UI tools).
const BLENDER_TOOLS = ["get_addon_status", "disable_telemetry", "get_scene_info", "execute_blender_code", "record_trajectory_feedback", "look", "generate_3d", "search_assets", "import_asset", "search_mentions", "open_viewport", "viewport_latest", "viewport_capture", "viewport_pick"];
// The 26 tools of the built-in Studio MCP server (create.roblox.com/docs/studio/mcp, updated 2026-10-02).
const STUDIO_TOOLS = [
	...["script_read", "multi_edit", "script_search", "script_grep"],
	...["generate_mesh", "generate_material", "generate_procedural_model", "wait_job_finished", "search_asset", "insert_asset", "upload_image", "store_image"],
	...["subagent", "search_game_tree", "inspect_instance", "execute_luau"],
	...["get_studio_state", "start_stop_play", "get_console_output", "screen_capture"],
	...["character_navigation", "user_keyboard_input", "user_mouse_input", "http_get", "skill", "list_roblox_studios"],
];

// Starlark subset used by .codex/rules: prefix_rule(name = "str" | [ ... ], ...) calls and comments.
function parseRules(text) {
	const tokens = [];
	const lexer = /\s+|#[^\n]*|"((?:[^"\\\n]|\\.)*)"|([A-Za-z_]\w*)|([()[\],=])|(.)/gy;
	for (let m; (m = lexer.exec(text)); ) {
		if (m[4] !== undefined) throw new Error(`.codex/rules: unexpected "${m[4]}"`);
		if (m[1] !== undefined) tokens.push({ str: JSON.parse(`"${m[1]}"`) });
		else if (m[2] ?? m[3]) tokens.push({ tok: m[2] ?? m[3] });
	}
	let i = 0;
	const expect = (tok) => {
		if (tokens[i]?.tok !== tok) throw new Error(`.codex/rules: expected "${tok}" at token ${i}`);
		i++;
	};
	const value = () => {
		if (tokens[i]?.str !== undefined) return tokens[i++].str;
		expect("[");
		const list = [];
		while (tokens[i]?.tok !== "]") {
			list.push(value());
			if (tokens[i]?.tok === ",") i++;
		}
		i++;
		return list;
	};
	const out = [];
	while (i < tokens.length) {
		if (tokens[i].tok !== "prefix_rule") throw new Error(`.codex/rules: only prefix_rule(...) is supported, got ${JSON.stringify(tokens[i])}`);
		i++;
		expect("(");
		const rule = { decision: "allow", match: [], not_match: [] };
		while (tokens[i]?.tok !== ")") {
			const key = tokens[i++].tok;
			expect("=");
			rule[key] = value();
			if (tokens[i]?.tok === ",") i++;
		}
		i++;
		if (!Array.isArray(rule.pattern) || !rule.pattern.length || !RANK_NAMES.includes(rule.decision)) throw new Error(`.codex/rules: bad rule ${JSON.stringify(rule)}`);
		rule.pattern = rule.pattern.map((p) => (Array.isArray(p) ? p : [p]));
		out.push(rule);
	}
	return out;
}
const RANK_NAMES = ["allow", "prompt", "forbidden"];

// Words of a plain command line (quotes removed), as for a rule example.
function shellWords(line) {
	return [...line.matchAll(/'([^']*)'|"([^"]*)"|(\S+)/g)].map((m) => m[1] ?? m[2] ?? m[3]);
}

// The commands Codex matches rules against: a plain command line (unquoted words, '...', and "..."
// without $ ` \) joined by && || ; | is split into its commands; anything else (variables,
// substitutions, redirections, globs, control flow, newlines) stays one opaque command (null).
function codexCommands(line) {
	const commands = [[]];
	const lexer = /[ \t]+|(&&|\|\||;|\|)|'([^']*)'|"([^"$`\\]*)"|([^\s'"$`\\<>|&;(){}[\]*?~!#\n]+)|(.)/gy;
	let word = null;
	const flush = () => {
		if (word !== null) commands[commands.length - 1].push(word);
		word = null;
	};
	for (let m; (m = lexer.exec(line)); ) {
		if (m[5] !== undefined) return null;
		if (m[1] !== undefined) {
			flush();
			commands.push([]);
		} else if (m[2] ?? m[3] ?? m[4]) word = (word ?? "") + (m[2] ?? m[3] ?? m[4]);
		else flush();
	}
	flush();
	if (commands.some((c) => !c.length || /^\w+=/.test(c[0]))) return null;
	return commands;
}
const R = ["ro", "jo"].join("");
const UP = ["up", "load"].join("");
const API = `https://${["apis", "roblox", "com"].join(".")}`;
const W = ["weppy", "project", "sync"].join("-");
const K = '-H "x-api-key: $RBX_KEY"';
// An owner record (the starter's publish-exceptions list) and its file name.
const OWN_LEAF = ["owner", "exceptions.json"].join("-");
const OWN = `release/${OWN_LEAF}`;

// Temporary repositories so a bare forced push resolves against a known branch.
const temp = mkdtempSync(join(tmpdir(), "hooks-selftest-"));
const repo = (branch) => {
	const dir = join(temp, branch.replace(/\W/g, "_"));
	spawnSync("git", ["init", "-q", "-b", branch, dir]);
	return dir;
};
const onMain = repo("main");
const onFeature = repo("claude/feature-x");
// Work branches whose repository config makes a push matching or mirrored.
const matchingRepo = repo("claude/matching");
spawnSync("git", ["-C", matchingRepo, "config", "push.default", "matching"]);
const mirrorRepo = repo("claude/mirror");
spawnSync("git", ["-C", mirrorRepo, "config", "remote.origin.mirror", "true"]);

const bash = (command, expected, cwd) => ["guard_bash.mjs", { tool_name: "Bash", tool_input: { command }, cwd }, expected];
const luau = (code, expected) => ["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__execute_luau", tool_input: { code } }, expected];
const tool = (name, expected) => ["guard_mcp.mjs", { tool_name: name, tool_input: {} }, expected];
const blenderPy = (code, expected) => ["guard_mcp.mjs", { tool_name: "mcp__blender__execute_blender_code", tool_input: { code } }, expected];
const mcp = (name, input, expected) => ["guard_mcp.mjs", { tool_name: name, tool_input: input }, expected];
// A file-edit event (Codex apply_patch, Claude Edit/Write), routed to guard_bash.mjs.
const fileEdit = (name, input, expected, cwd) => ["guard_bash.mjs", { tool_name: name, tool_input: input, cwd }, expected];
const patch = (...lines) => ["*** Begin Patch", ...lines, "*** End Patch"].join("\n");
// A case with a name (element 4), printed when it fails.
const named = (name, c) => Object.assign(c, { 4: name });

const cases = [
	// publishing tools
	bash(`${R} ${UP} --asset_id 1 default.project.json`, "deny"),
	bash(`${R} -v ${UP} --asset_id 1 default.project.json`, "deny"),
	bash(`${R} --verbose ${UP} --asset_id 1`, "deny"),
	bash(`${R}.exe ${UP} --asset_id 1 default.project.json`, "deny"),
	bash(`bash -c '${R} --color never ${UP} --asset_id 1'`, "deny"),
	bash(`npx ${R} ${UP} --asset_id 1`, "deny"),
	bash(`env RUST_LOG=debug ${R.toUpperCase()} ${UP.toUpperCase()} default.project.json`, "deny"),
	bash(`X=${R}; $X ${UP} --asset_id 1`, "deny"),
	bash(`"$(command -v ${R})" ${UP} --asset_id 1`, "deny"),
	bash(`bash <<'EOF'\n${R} ${UP} --asset_id 1\nEOF`, "deny"),
	bash(`echo '${R} ${UP} --asset_id 1' | sh`, "deny"),
	bash("mantle deploy --environment prod", "deny"),
	bash("tarmac sync --target=roblox", "deny"),
	bash("rbxcloud experience publish -f place.rbxl -p 1 -u 2 -t published", "deny"),
	bash("rbxcloud assets create --asset-type model-fbx --filepath prop.fbx", "deny"),
	bash("rbxcloud assets update --asset-type model-fbx --asset-id 123 --filepath prop.fbx", "deny"),
	bash("rbxcloud datastore set --datastore-name PlayerData --key 1 --data '{}' --universe-id 1", "deny"),
	bash("rbxcloud datastore delete --datastore-name PlayerData --key 1 --universe-id 1", "deny"),
	bash("rbxcloud datastore increment --datastore-name Coins --key 1 --universe-id 1", "deny"),
	bash("rbxcloud ordered-datastore update --datastore-name Top --id 1 --value 5 --universe-id 1", "deny"),
	bash("rbxcloud messaging publish --topic t --message hi --universe-id 1", "deny"),
	// Open Cloud writes: every curl body form, other clients, every production-data API
	bash("curl -X POST " + API + "/assets/v1/assets", "deny"),
	bash(`curl ${K} -F 'request={"assetType":"Model"}' -F "fileContent=@prop.fbx;type=model/fbx" ${API}/assets/v1/assets`, "deny"),
	bash(`curl --location '${API}/assets/v1/assets' --form 'request={}' --form 'fileContent=@prop.fbx'`, "deny"),
	bash(`curl --json @entry.json ${API}/cloud/v2/universes/1/data-stores/D/entries`, "deny"),
	bash(`curl -T place.rbxl '${API}/universes/v1/1/places/2/versions?versionType=Published'`, "deny"),
	bash(`curl --upload-file place.rbxl ${API}/universes/v1/1/places/2/versions`, "deny"),
	bash(`curl ${K} -d '{"value":1}' "${API}/datastores/v1/universes/1/standard-datastores/datastore/entries/entry?datastoreName=D&entryKey=k"`, "deny"),
	bash(`curl -sSd 5 "${API}/datastores/v1/universes/1/standard-datastores/datastore/entries/entry/increment?datastoreName=D&entryKey=k"`, "deny"),
	bash(`curl ${K} -X DELETE "${API}/datastores/v1/universes/1/standard-datastores/datastore/entries/entry?datastoreName=D&entryKey=k"`, "deny"),
	bash(`curl -XPOST ${API}/ordered-data-stores/v1/universes/1/orderedDataStores/Top/scopes/global/entries`, "deny"),
	bash(`curl ${API}/messaging-service/v1/universes/1/topics/t --data-raw '{"message":"hi"}'`, "deny"),
	bash(`curl --request PATCH ${API}/game-passes/v1/universes/1/game-passes/2`, "deny"),
	bash(`curl -X POST ${API}/developer-products/v1/universes/1/developer-products`, "deny"),
	bash(`wget --post-file=place.rbxl ${API}/universes/v1/1/places/2/versions`, "deny"),
	bash(`http ${API}/cloud/v2/universes/1/data-stores/D/entries value:=1`, "deny"),
	bash(`Invoke-RestMethod -Method Post -Uri ${API}/assets/v1/assets -InFile prop.fbx`, "deny"),
	bash(`powershell -Command "irm -Method Patch -Uri ${API}/cloud/v2/universes/1 -Body '{}'"`, "deny"),
	bash(`python3 -c "import requests; requests.post('${API}/assets/v1/assets')"`, "deny"),
	bash(`U=${API}/assets/v1/assets; curl -F fileContent=@prop.fbx "$U"`, "deny"),
	bash(`pwsh -EncodedCommand ${Buffer.from(`Invoke-RestMethod -Method Post -Uri ${API}/assets/v1/assets`, "utf16le").toString("base64")}`, "deny"),
	// PowerShell parameter abbreviations and splatting
	bash(`Invoke-RestMethod ${API}/assets/v1/assets -Met POST -Bod $b`, "deny"),
	bash(`irm -Uri ${API}/assets/v1/assets -Me Post -InF prop.fbx`, "deny"),
	bash(`pwsh -c "$p = @{Uri='${API}/assets/v1/assets'; Method='Post'}; irm @p"`, "deny"),
	// urllib sends a POST when given a body
	bash(`python3 -c "import urllib.request as u; u.urlopen('${API}/cloud/v2/universes/1', b'{}')"`, "deny"),
	bash(`python3 -c "import urllib.request as u; u.urlopen(u.Request('${API}/cloud/v2/universes/1', data=b'{}'))"`, "deny"),
	bash(`P=python3; $P -c "import requests; requests.put('${API}/cloud/v2/universes/1')"`, "deny"),
	// a write whose URL the guard cannot see is treated as a Roblox write
	bash("curl -F fileContent=@prop.fbx $ROBLOX_ASSETS_URL", "deny"),
	bash('curl -X POST "$(cat url.txt)" -d x', "deny"),
	bash("cat urls.txt | xargs curl -X POST", "deny"),
	bash(`curl -K request.cfg ${API}/assets/v1/assets`, "deny"),
	bash(`cat body.json | http ${API}/cloud/v2/universes/1/data-stores/D/entries`, "deny"),
	bash(`echo 'curl -F f=@prop.fbx ${API}/assets/v1/assets' | sh`, "deny"),
	// force pushes and deletions of protected branches, in any argument order
	bash("git push --force origin main", "deny"),
	bash("git push origin main --force", "deny"),
	bash("git push origin main -f", "deny"),
	bash("git push origin +main", "deny"),
	bash("git push origin HEAD:main --force", "deny"),
	bash("git push -fu origin refs/heads/master", "deny"),
	bash("git push --force-with-lease origin main", "deny"),
	bash("git push origin :main", "deny"),
	bash("git push origin --delete master", "deny"),
	bash("git push --mirror origin", "deny"),
	bash("git -C . push origin main --force", "deny"),
	bash("git push --force", "deny", onMain),
	bash("git push -f origin HEAD", "deny", onMain),
	// weppy-project-sync writes
	bash(`echo '{}' > ../${W}/config.json`, "deny"),
	bash(`echo '{}' >> ../${W}/config.json`, "deny"),
	bash(`echo x>../${W}/config.json`, "deny"),
	bash(`cp tools/x.json ../${W}/config.json`, "deny"),
	bash(`cat tools/x.json | tee ../${W}/config.json`, "deny"),
	bash(`sed -i 's/a/b/' ../${W}/config.json`, "deny"),
	bash(`rm -rf ../${W}`, "deny"),
	bash(`git -C ../${W} reset --hard`, "deny"),
	bash(`git -C ../${W} clean -fdx`, "deny"),
	bash(`git -C ../${W} checkout -- .`, "deny"),
	bash(`cd ../${W} && touch new.txt`, "deny"),
	bash(`git --git-dir ../${W}/.git reset --hard`, "deny"),
	bash(`git --git-dir=../${W}/.git update-ref refs/heads/main HEAD`, "deny"),
	bash(`GIT_DIR=../${W}/.git git commit --allow-empty -m x`, "deny"),
	bash(`export GIT_DIR=../${W}/.git; git reset --hard`, "deny"),
	bash(`git --work-tree=../${W} checkout -- .`, "deny"),
	bash(`git -C ../${W} fetch`, "deny"),
	bash(`git show HEAD:a.json > ../${W}/a.json`, "deny"),
	bash(`curl -o ../${W}/x.json https://example.com/x.json`, "deny"),
	bash(`wget -O ../${W}/x.json https://example.com/x.json`, "deny"),
	bash(`tar -xzf x.tgz -C ../${W}`, "deny"),
	bash(`unzip -o x.zip -d ../${W}`, "deny"),
	bash(`awk -i inplace '{print}' ../${W}/config.json`, "deny"),
	bash(`D=../${W}; rm -rf "$D"`, "deny"),
	bash(`for f in ../${W}/*; do rm "$f"; done`, "deny"),
	bash(`ls ../${W}/* | xargs rm`, "deny"),
	bash(`bash -c 'rm -rf "$1"' _ ../${W}`, "deny"),
	bash(`env -C ../${W} touch new.txt`, "deny"),
	bash("rm -rf ../weppy-*", "deny"),
	bash(`ln -s ../${W} linked`, "deny"),
	bash(`python3 -c "open('../${W}/a.json', 'w').write('x')"`, "deny"),
	bash(`powershell -Command "gci ../${W} | % { $_.Delete() }"`, "deny"),
	bash(`cd ../${W} && npm install`, "deny"),
	// must stay allowed: reads, normal pushes, branches that merely contain "main"
	bash(`curl https://${["apis", "roblox", "com"].join(".")}/cloud/v2/universes/1`, "allow"),
	bash(`curl -s ${K} "${API}/datastores/v1/universes/1/standard-datastores/datastore/entries/entry?datastoreName=D&entryKey=k"`, "allow"),
	bash(`curl -X GET ${API}/cloud/v2/universes/1 -o build/universe.json`, "allow"),
	bash(`powershell -Command "Invoke-RestMethod -Uri ${API}/cloud/v2/universes/1 -Headers @{'x-api-key'=$env:K}"`, "allow"),
	bash("rbxcloud datastore get --datastore-name PlayerData --key 1 --universe-id 1", "allow"),
	bash("rbxcloud datastore list-stores --universe-id 1", "allow"),
	bash(`rg -n "${API}/assets" docs -d 2`, "allow"),
	bash('git commit -m "guard: deny rbxcloud publish and mantle deploy"', "allow"),
	bash("curl -X POST http://127.0.0.1:3002/health", "allow"),
	bash("git push -f origin feature/main-menu", "allow"),
	bash("git push --force-with-lease origin claude/main-camera-fix", "allow"),
	bash("git push --force origin claude/fix-mainline", "allow"),
	bash("git push -u origin claude/factory-second-pass", "allow"),
	bash("git push origin main", "allow"),
	bash("git push --force", "allow", onFeature),
	bash("git push -f origin HEAD", "allow", onFeature),
	bash(`cat ../${W}/README.md > /tmp/readme.txt`, "allow"),
	bash(`ls ../${W} > /tmp/list.txt`, "allow"),
	bash(`cp ../${W}/config.json /tmp/config.json`, "allow"),
	bash(`git -C ../${W} status`, "allow"),
	bash(`git -C ../${W} log --oneline -5`, "allow"),
	bash(`rg -n TODO ../${W}`, "allow"),
	bash(`cd ../${W} && git status && cd - && git push -u origin claude/x`, "allow"),
	bash(`cat ../${W}/config.json | jq .name`, "allow"),
	bash(`find ../${W} -name '*.json' | xargs grep -l TODO`, "allow"),
	bash(`sed -n '1,20p' ../${W}/README.md`, "allow"),
	bash(`git -C ../${W} branch -a`, "allow"),
	bash(`git --git-dir=../${W}/.git log -3`, "allow"),
	bash(`git commit -m "hooks: keep ${W} read-only"`, "allow"),
	bash(`gh pr create --title "Guard ${W} writes" --body "Never modify ${W}/ from this repo."`, "allow"),
	bash(`tar -czf /tmp/w.tgz -C ../${W} .`, "allow"),
	bash(`rsync -a ../${W}/ /tmp/w/`, "allow"),
	bash(`for f in ../${W}/*.json; do cat "$f"; done`, "allow"),
	bash(`pushd ../${W} && git status && popd && touch new.txt`, "allow"),
	bash(`powershell -Command "Get-Content ../${W}/config.json | Select-String x"`, "allow"),
	bash(`rg -n "${R} ${UP}" tools .claude`, "allow"),
	bash(`grep -rn "${R} ${UP}" docs`, "allow"),
	bash("grep -rn rbxcloud docs tools", "allow"),
	bash(`curl -d x localhost:3000/a && echo ${API}`, "allow"),
	bash(`curl -m 10 -b cookies.txt ${API}/cloud/v2/universes/1`, "allow"),
	bash(`curl -e https://www.roblox.com -d x http://localhost:8080/echo`, "allow"),
	bash(`python3 -c "import json, urllib.request as u; data = json.load(u.urlopen('${API}/cloud/v2/universes/1'))"`, "allow"),
	bash("curl -X POST https://api.github.com/repos/x/y/issues -d '{}'", "allow"),
	bash("curl -fsSL https://raw.githubusercontent.com/x/y/main/install.sh | bash", "allow"),
	bash("lune run tests/run.luau", "allow"),
	bash(`${R} build fixtures/creator.project.json -o build/x.rbxl`, "allow"),
	bash("grep -rn purchase packages", "allow"),
	// Studio MCP tools and Luau
	tool("mcp__Roblox_Studio__insert_asset", "ask"),
	tool("mcp__Roblox_Studio__generate_mesh", "ask"),
	tool("mcp__Roblox_Studio__screen_capture", "allow"),
	luau('game:GetService("AssetService"):CreatePlaceAsync("x", 1)', "deny"),
	luau('game:GetService("AssetService"):CreatePlaceInPlayerInventoryAsync(p, "x", 1)', "deny"),
	luau('game:GetService("AssetService"):CreateAssetAsync(workspace.Model, Enum.AssetType.Model, {})', "deny"),
	luau('game:GetService("AssetService"):CreateAssetVersionAsync(workspace.Model, Enum.AssetType.Model, 123, {})', "deny"),
	luau('game:GetService("AssetService"):SavePlaceAsync()', "deny"),
	luau('game:GetService("MessagingService"):PublishAsync("t", "m")', "deny"),
	luau("MarketplaceService:PromptPurchase(p, 1)", "ask"),
	luau('game:GetService("MarketplaceService"):PromptProductPurchase(p, 1)', "ask"),
	luau("MarketplaceService:PromptGamePassPurchase(p, 1)", "ask"),
	luau("MarketplaceService:PromptBundlePurchase(p, 1)", "ask"),
	// prompts Studio does not safely mock are denied outright (subscriptions, Premium, transfers, bulk)
	luau("MarketplaceService:PromptPremiumPurchase(p)", "deny"),
	luau("MarketplaceService:PromptSubscriptionPurchase(p, 'EXP-1')", "deny"),
	luau("MarketplaceService:PromptRobloxSubscriptionPurchase(p, 'RBX-1')", "deny"),
	luau("MarketplaceService:PromptBulkPurchase(p, {}, {})", "deny"),
	luau("MarketplaceService:PromptRobuxTransferAsync(p, 10)", "deny"),
	luau("MarketplaceService:PromptCancelSubscription(p, 'EXP-1')", "ask"),
	luau("store:SetAsync('k', 1)", "ask"),
	luau('ds:UpdateAsync ("k", function(v) return v end)', "ask"),
	luau('queue:AddAsync("v", 60)', "ask"),
	luau('sortedMap:SetAsync("k", 1, 60)', "ask"),
	luau("print(workspace:GetChildren())", "allow"),
	luau("print(MarketplaceService:GetProductInfo(1), MarketplaceService:UserOwnsGamePassAsync(1, 2))", "allow"),
	luau("print(store:GetAsync('k'))", "allow"),
	// Blender MCP: paid generators and third-party asset libraries are denied (2.1.8 and 1.x names);
	// the vendor feedback upload asks
	...["generate_3d", "import_asset", "search_assets"].map((t) => tool(`mcp__blender__${t}`, "deny")),
	...["download_sketchfab_model", "search_polyhaven_assets", "get_sketchfab_model_preview", "generate_hyper3d_model_via_text", "generate_hunyuan3d_model", "poll_rodin_job_status", "import_generated_asset", "get_polyhaven_categories"].map((t) => tool(`mcp__blender__${t}`, "deny")),
	tool("mcp__blender__record_trajectory_feedback", "ask"),
	tool("mcp__blender_workbench__generate_3d", "deny"),
	...["get_scene_info", "look", "get_addon_status", "disable_telemetry", "get_sketchfab_status", "viewport_latest"].map((t) => tool(`mcp__blender__${t}`, "allow")),
	// execute_blender_code that reaches the network or a shell asks; ordinary bpy work passes
	blenderPy("import urllib.request\nurllib.request.urlretrieve('https://example.com/a.fbx', '/tmp/a.fbx')", "ask"),
	blenderPy("import bpy, requests\nrequests.post('https://example.com', data=b'x')", "ask"),
	blenderPy("from http import client\nc = client.HTTPSConnection('example.com')", "ask"),
	blenderPy("import socket\nsocket.create_connection(('example.com', 80))", "ask"),
	blenderPy("import subprocess\nsubprocess.run(['blender', '--version'])", "ask"),
	blenderPy("import os\nos.system('echo hi')", "ask"),
	blenderPy("from os import popen as p\np('ls')", "ask"),
	blenderPy("m = __import__('sock' + 'et')", "ask"),
	blenderPy("import importlib\nimportlib.import_module('subprocess')", "ask"),
	blenderPy("exec(open('/tmp/x.py').read())", "ask"),
	blenderPy("import bpy\nbpy.ops.wm.url_open(url='https://example.com')", "ask"),
	blenderPy("import bpy\nbpy.ops.extensions.package_install(repo_index=0, pkg_id='x')", "ask"),
	blenderPy("import bpy, bmesh, math\nbpy.ops.mesh.primitive_cube_add(size=2)\nprint(len(bpy.data.objects))", "allow"),
	blenderPy("import json, re\npat = re.compile(r'^SM_')\ndata = json.load(open('build/blender/qa.json'))", "allow"),
	blenderPy("import sys\nsys.path.insert(0, 'tools/blender')\nfrom bkit import ops\nops.apply_transforms(bpy.context.object)", "allow"),
	blenderPy("import bpy\nbpy.ops.export_scene.fbx(filepath='build/blender/prop.fbx')\nprint(bpy.context.preferences.system.memory_cache_limit)", "allow"),
	// Codex mode (lib.mjs): an ask becomes a deny whether Codex is named by flag or by its turn_id
	["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__insert_asset", tool_input: {} }, "deny", ["--client=codex"]],
	["guard_mcp.mjs", { tool_name: "mcp__blender__record_trajectory_feedback", tool_input: {}, turn_id: "t1" }, "deny"],
	["guard_mcp.mjs", { tool_name: "mcp__blender__look", tool_input: {}, turn_id: "t1" }, "allow"],
	// ---- regressions from the guards audit (HOOK-1 .. HOOK-8), named so a failure says which bypass is back
	// HOOK-1: curl and wget accept any unique prefix of a long option
	named("HOOK-1 curl --upload (prefix of --upload-file)", bash(`curl --upload place.rbxl '${API}/universes/v1/1/places/2/versions?versionType=Published'`, "deny")),
	named("HOOK-1 curl --js (prefix of --json)", bash(`curl --js '{"value":1}' ${API}/cloud/v2/universes/1/data-stores/D/entries`, "deny")),
	named("HOOK-1 curl --form-str (prefix of --form-string)", bash(`curl --form-str 'request={}' ${API}/assets/v1/assets`, "deny")),
	named("HOOK-1 curl --conf (prefix of --config, URL hidden)", bash("curl --conf req.cfg", "deny")),
	named("HOOK-1 curl --requ (ambiguous prefix judged as --request)", bash(`curl --requ POST ${API}/assets/v1/assets`, "deny")),
	named("HOOK-1 curl --expand-data", bash(`curl --variable %BODY --expand-data '{{BODY}}' ${API}/assets/v1/assets`, "deny")),
	named("HOOK-1 curl unknown option to a Roblox URL counts as a write", bash(`curl --frobnicate x ${API}/assets/v1/assets`, "deny")),
	named("HOOK-1 wget --post-d (prefix of --post-data)", bash(`wget --post-d='{}' ${API}/cloud/v2/universes/1/data-stores/D/entries`, "deny")),
	named("HOOK-1 wget --post-f (prefix of --post-file)", bash(`wget --post-f=place.rbxl ${API}/universes/v1/1/places/2/versions`, "deny")),
	named("HOOK-1 wget --meth/--body-f prefixes", bash(`wget --meth=PUT --body-f=place.rbxl ${API}/universes/v1/1/places/2/versions`, "deny")),
	named("HOOK-1 curl read-option prefixes stay allowed", bash(`curl --sil --fail-w --max-t 10 ${API}/cloud/v2/universes/1`, "allow")),
	named("HOOK-1 curl --no-<flag> stays allowed", bash(`curl --no-silent --no-progress-meter ${API}/cloud/v2/universes/1`, "allow")),
	named("HOOK-1 wget read-option prefixes stay allowed", bash(`wget --quie --output-d=/tmp/u.json ${API}/cloud/v2/universes/1`, "allow")),
	// HOOK-2: git push option prefixes, matching refspecs, push configuration, refspecs from $(...)
	named("HOOK-2 git push --force-w (prefix)", bash("git push --force-w origin main", "deny")),
	named("HOOK-2 git push ... --force-with-l (prefix, after the refspec)", bash("git push origin main --force-with-l", "deny")),
	named("HOOK-2 git push --mirr (prefix)", bash("git push --mirr origin", "deny")),
	named("HOOK-2 git push --dele (prefix)", bash("git push --dele origin main", "deny")),
	named("HOOK-2 git push --prune with a wildcard refspec", bash("git push --prune origin 'refs/heads/*:refs/heads/*'", "deny")),
	named("HOOK-2 forced matching refspec ':'", bash("git push -f origin :", "deny", onFeature)),
	named("HOOK-2 matching refspec '+:'", bash("git push origin +:", "deny", onFeature)),
	named("HOOK-2 git -c remote.origin.mirror=true", bash("git -c remote.origin.mirror=true push origin", "deny", onFeature)),
	named("HOOK-2 git -c push.default=matching", bash("git -c push.default=matching push -f origin", "deny", onFeature)),
	named("HOOK-2 git -c remote.origin.push=+main", bash("git -c remote.origin.push=+refs/heads/main:refs/heads/main push origin", "deny", onFeature)),
	named("HOOK-2 GIT_CONFIG_COUNT mirror", bash("GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.mirror GIT_CONFIG_VALUE_0=true git push origin", "deny", onFeature)),
	named("HOOK-2 git -c alias for a forced push", bash("git -c alias.p='push --force' p origin main", "deny")),
	named("HOOK-2 push config changed earlier in the line", bash("git config remote.origin.mirror true && git push origin", "deny", onFeature)),
	named("HOOK-2 repo push.default=matching", bash("git push -f origin", "deny", matchingRepo)),
	named("HOOK-2 repo remote.origin.mirror", bash("git push origin", "deny", mirrorRepo)),
	named("HOOK-2 $(git branch --show-current) on main", bash('git push -f origin "$(git branch --show-current)"', "deny", onMain)),
	named("HOOK-2 $(git rev-parse --abbrev-ref HEAD) on main", bash("git push --force origin $(git rev-parse --abbrev-ref HEAD)", "deny", onMain)),
	named("HOOK-2 forced refspec from an unknown variable", bash('git push -f origin "$BRANCH"', "deny", onFeature)),
	named("HOOK-2 $(git branch --show-current) on a work branch stays allowed", bash('git push -f origin "$(git branch --show-current)"', "allow", onFeature)),
	named("HOOK-2 unforced matching push stays allowed", bash("git push origin :", "allow", onFeature)),
	named("HOOK-2 git -c push.default=current stays allowed", bash("git -c push.default=current push -f origin", "allow", onFeature)),
	named("HOOK-2 --follow (prefix of --follow-tags) stays allowed", bash("git push --follow origin claude/x", "allow")),
	// HOOK-3: writes into the protected folder through flag clusters, old-style tar, prefixes, pipes
	named("HOOK-3 cp -rt", bash(`cp -rt ../${W} src.txt`, "deny")),
	named("HOOK-3 install -Dt", bash(`install -Dt ../${W} x.txt`, "deny")),
	named("HOOK-3 cp --t (prefix of --target-directory)", bash(`cp --t ../${W} src.txt`, "deny")),
	named("HOOK-3 install -d", bash(`install -d ../${W}/new`, "deny")),
	named("HOOK-3 tar old-style xCf", bash(`tar xCf ../${W} /tmp/x.tgz`, "deny")),
	named("HOOK-3 tar old-style xfC", bash(`tar xfC /tmp/x.tgz ../${W}`, "deny")),
	named("HOOK-3 tar --dir (prefix of --directory)", bash(`tar -xf /tmp/x.tgz --dir ../${W}`, "deny")),
	named("HOOK-3 sort -uo", bash(`sort -uo ../${W}/list.txt ../${W}/list.txt`, "deny")),
	named("HOOK-3 sort --out= (prefix of --output)", bash(`sort --out=../${W}/list.txt in.txt`, "deny")),
	named("HOOK-3 sed --in (prefix of --in-place)", bash(`sed --in 's/a/b/' ../${W}/config.json`, "deny")),
	named("HOOK-3 diff | patch", bash(`diff -u ${W}/config.json /tmp/new.json | patch -p0`, "deny")),
	named("HOOK-3 git diff | git apply", bash(`git diff --no-index ${W}/config.json /tmp/new.json | git apply`, "deny")),
	named("HOOK-3 git -c core.fsmonitor under a read-only subcommand", bash(`git -c core.fsmonitor='touch x' -C ../${W} status`, "deny")),
	named("HOOK-3 rename fed file names by a pipe", bash(`find ../${W} -name '*.bak' | rename 's/\\.bak$//'`, "deny")),
	named("HOOK-3 patch reading a diff from a file", bash(`patch -p0 < /tmp/fix.diff && git -C ../${W} status`, "deny")),
	named("HOOK-3 tar old-style create elsewhere stays allowed", bash(`tar czf /tmp/w.tgz ../${W}`, "allow")),
	named("HOOK-3 sort -uo elsewhere stays allowed", bash(`sort -uo /tmp/list.txt ../${W}/list.txt`, "allow")),
	named("HOOK-3 cp -rt elsewhere stays allowed", bash(`cp -rt /tmp/out ../${W}/src`, "allow")),
	// HOOK-4: every string in a Studio tool's input is checked, whatever the field is called
	named("HOOK-4 execute_luau with an unknown field name", ["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__execute_luau", tool_input: { command: 'game:GetService("AssetService"):SavePlaceAsync()' } }, "deny"]),
	named("HOOK-4 multi_edit DataStore write", ["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__multi_edit", tool_input: { file_path: "game.ServerScriptService.Test", edits: [{ old_string: "", new_string: 'game:GetService("DataStoreService"):GetDataStore("D"):SetAsync("k", 1)' }] } }, "ask"]),
	named("HOOK-4 multi_edit purchase prompt", ["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__multi_edit", tool_input: { edits: [{ new_string: "MarketplaceService:PromptProductPurchase(p, 1)" }] } }, "ask"]),
	named("HOOK-4 multi_edit publish", ["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__multi_edit", tool_input: { edits: [{ new_string: 'game:GetService("AssetService"):SavePlaceAsync()' }] } }, "deny"]),
	named("HOOK-4 multi_edit that removes a write stays allowed", ["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__multi_edit", tool_input: { edits: [{ old_string: 'store:SetAsync("k", 1)', new_string: 'print("removed")' }] } }, "allow"]),
	named("HOOK-4 script_search for an API name stays allowed", ["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__script_search", tool_input: { query: "SetAsync" } }, "allow"]),
	// HOOK-5: global options before the subcommand, xargs/parallel input, computed subcommands, asphalt
	named("HOOK-5 tarmac --auth before sync", bash('tarmac --auth "$COOKIE" sync --target roblox', "deny")),
	named("HOOK-5 tarmac --auth before upload-image", bash("tarmac --auth abc upload-image icon.png", "deny")),
	named("HOOK-5 subcommand from xargs input", bash(`echo ${UP} --asset_id 1 | xargs ${R}`, "deny")),
	named("HOOK-5 subcommand from parallel input", bash(`parallel ${R} ::: ${UP}`, "deny")),
	named("HOOK-5 rbxcloud verb from xargs input", bash("echo create | xargs rbxcloud assets", "deny")),
	named("HOOK-5 computed subcommand", bash(`${R} "$(echo ${UP})" --asset_id 1`, "deny")),
	named("HOOK-5 asphalt sync", bash("asphalt sync", "deny")),
	named("HOOK-5 asphalt upload", bash("asphalt upload icon.png --type image", "deny")),
	named("HOOK-5 asphalt sync --dry-run stays allowed", bash("asphalt sync --dry-run", "allow")),
	named("HOOK-5 xargs with a read-only subcommand stays allowed", bash(`ls fixtures/*.project.json | xargs -n1 ${R} build -o /tmp/x.rbxl`, "allow")),
	named("HOOK-5 tarmac --auth with a local target stays allowed", bash("tarmac --auth abc sync --target debug", "allow")),
	// HOOK-6: wrappers, runners, inline interpreter code, httpie spellings, Blender and Luau writes
	named("HOOK-6 setsid", bash(`setsid ${R} ${UP} --asset_id 1`, "deny")),
	named("HOOK-6 flock", bash(`flock /tmp/l ${R} ${UP} --asset_id 1`, "deny")),
	named("HOOK-6 flock -c", bash(`flock /tmp/l -c '${R} ${UP} --asset_id 1'`, "deny")),
	named("HOOK-6 uv run", bash(`uv run ${R} ${UP} --asset_id 1`, "deny")),
	named("HOOK-6 script -qc", bash(`script -qc "${R} ${UP} --asset_id 1" /dev/null`, "deny")),
	named("HOOK-6 cmd /c start", bash(`cmd /c start ${R} ${UP} --asset_id 1`, "deny")),
	named("HOOK-6 Start-Process", bash(`powershell -Command "Start-Process ${R} -ArgumentList '${UP} --asset_id 1'"`, "deny")),
	named("HOOK-6 python os.system starts a publishing tool", bash(`python3 -c "import os; os.system('${R} ${UP} --asset_id 1')"`, "deny")),
	named("HOOK-6 node execSync starts mantle deploy", bash(`node -e "require('child_process').execSync('mantle deploy')"`, "deny")),
	named("HOOK-6 python subprocess curl -XPOST", bash(`python3 -c "import subprocess; subprocess.run(['curl','-XPOST','${API}/assets/v1/assets'])"`, "deny")),
	named("HOOK-6 python -m httpie", bash(`python3 -m httpie POST ${API}/cloud/v2/universes/1/data-stores/D/entries value:=1`, "deny")),
	named("HOOK-6 uvx --from httpie http", bash(`uvx --from httpie http POST ${API}/cloud/v2/universes/1/data-stores/D/entries value:=1`, "deny")),
	named("HOOK-6 httpie --ssl takes a value", bash(`http --ssl tls1.2 POST ${API}/cloud/v2/universes/1/data-stores/D/entries value:=1`, "deny")),
	named("HOOK-6 httpie --ssl then a data item", bash(`http --ssl tls1.2 ${API}/cloud/v2/universes/1/data-stores/D/entries value:=1`, "deny")),
	named("HOOK-6 git -c core.pager starts a publishing tool", bash(`git -c core.pager='${R} ${UP} --asset_id 1' log`, "deny")),
	named("HOOK-6 Blender subprocess starts a publishing tool", blenderPy(`import subprocess; subprocess.run(['${R}','${UP}','--asset_id','1'])`, "deny")),
	named("HOOK-6 Blender requests.post to a Roblox web API", blenderPy(`import requests; requests.post('${API}/assets/v1/assets', files={'f': open('a.fbx', 'rb')})`, "deny")),
	named("HOOK-6 Blender curl -X POST to a Roblox web API", blenderPy(`import os; os.system('curl -X POST ${API}/assets/v1/assets -F f=@a.fbx')`, "deny")),
	named("HOOK-6 Luau HttpService RequestAsync POST to Open Cloud", luau(`game:GetService("HttpService"):RequestAsync({Url="${API}/cloud/v2/universes/1/data-stores/D/entries", Method="POST", Body="{}"})`, "deny")),
	named("HOOK-6 Luau HttpService PostAsync to Open Cloud", luau(`HttpService:PostAsync("${API}/messaging-service/v1/universes/1/topics/t", "{}")`, "deny")),
	named("HOOK-6 Luau HttpService GetAsync stays allowed", luau(`print(game:GetService("HttpService"):GetAsync("${API}/cloud/v2/universes/1"))`, "allow")),
	named("HOOK-6 code piped into python", bash(`echo "import os; os.system('${R} ${UP} --asset_id 1')" | python3`, "deny")),
	named("HOOK-6 event data piped into a node script stays allowed", bash(`echo '{"tool_input":{"command":"curl -X POST ${API}/assets/v1/assets"}}' | node tools/hooks/guard_bash.mjs`, "allow")),
	named("HOOK-6 uv run of a test stays allowed", bash("uv run pytest -q tools", "allow")),
	named("HOOK-6 python -m http.server stays allowed", bash("python3 -m http.server 8000 --bind 127.0.0.1", "allow")),
	// HOOK-7: size cap (a hook that times out lets the command run); near-cap timing is checked below
	named("HOOK-7 command over 64 KiB is denied", bash("echo ok\n".repeat(10000), "deny")),
	named("HOOK-7 too many pushes to resolve in time", bash("git push -f\n".repeat(40), "deny", onFeature)),
	// HOOK-8: routine commands that were false positives
	named("HOOK-8 git commit -am naming the folder", bash(`git commit -am "${W}/ stays read-only"`, "allow")),
	named("HOOK-8 git commit --mess= naming the folder", bash(`git commit --mess="${W}/ stays read-only"`, "allow")),
	named("HOOK-8 urlopen(url, None, timeout) is a GET", bash(`python3 -c "import urllib.request as u, json; print(json.load(u.urlopen('${API}/cloud/v2/universes/1', None, 10)))"`, "allow")),
	named("HOOK-8 git add of a path in the folder is still denied", bash(`git add ../${W}/x.json`, "deny")),
	// ---- second guard pass (2026-10), named GUARD-*: package registries, MCP classes, owner records
	// Package registries: publishing, yanking and tokens are denied; installs and lookups pass.
	named("GUARD-1 wally publish", bash("wally publish", "deny")),
	named("GUARD-1 wally login --token", bash("wally login --token abc", "deny")),
	named("GUARD-1 wally logout", bash("wally logout", "deny")),
	named("GUARD-1 wally -v publish", bash("wally -v publish", "deny")),
	named("GUARD-1 wally publish behind a runner", bash("mise exec wally publish", "deny")),
	named("GUARD-1 wally subcommand from xargs input", bash("echo publish | xargs wally", "deny")),
	named("GUARD-1 pesde publish", bash("pesde publish -y", "deny")),
	named("GUARD-1 pesde yank", bash("pesde yank scope/name@1.0.0", "deny")),
	named("GUARD-1 pesde deprecate", bash("pesde deprecate scope/name", "deny")),
	named("GUARD-1 pesde auth login", bash("pesde auth login", "deny")),
	named("GUARD-1 pesde auth --index before login", bash("pesde auth --index default login", "deny")),
	named("GUARD-1 pesde auth token prints a secret", bash("pesde auth token", "deny")),
	named("GUARD-1 pesde auth logout", bash("pesde auth logout", "deny")),
	named("GUARD-1 inline script runs wally publish", bash(`python3 -c "import os; os.system('wally publish')"`, "deny")),
	named("GUARD-1 Blender Python runs pesde publish", blenderPy("import subprocess; subprocess.run(['pesde', 'publish', '-y'])", "deny")),
	named("GUARD-1 wally install stays allowed", bash("wally install", "allow")),
	named("GUARD-1 wally package stays allowed", bash("wally package --output build/pkg.zip", "allow")),
	named("GUARD-1 pesde install and add stay allowed", bash("pesde install && pesde add wally#scope/name", "allow")),
	named("GUARD-1 pesde auth whoami stays allowed", bash("pesde auth whoami", "allow")),
	named("GUARD-1 rokit add of the wally tool stays allowed", bash("rokit add UpliftGames/wally", "allow")),
	// Studio MCP: all 26 tools classified; subagent asks; skill/wait_job_finished/search_asset are reads.
	...["skill", "wait_job_finished", "search_asset", "list_roblox_studios"].map((t) => named(`GUARD-2 Studio ${t} stays allowed`, tool(`mcp__Roblox_Studio__${t}`, "allow"))),
	named("GUARD-2 Studio search_asset query naming write APIs stays allowed", mcp("mcp__Roblox_Studio__search_asset", { query: "SetAsync PromptProductPurchase SavePlaceAsync" }, "allow")),
	named("GUARD-2 Studio skill by name stays allowed", mcp("mcp__Roblox_Studio__skill", { name: "rbx-perf-profiling" }, "allow")),
	named("GUARD-2 Studio subagent asks", mcp("mcp__Roblox_Studio__subagent", { type: "playtest", prompt: "walk to the spawn and report" }, "ask")),
	named("GUARD-2 Studio subagent is denied in Codex", ["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__subagent", tool_input: { type: "explore" } }, "deny", ["--client=codex"]]),
	named("GUARD-2 Studio http_get asks", tool("mcp__Roblox_Studio__http_get", "ask")),
	named("GUARD-2 Studio play and input tools stay allowed", tool("mcp__Roblox_Studio__start_stop_play", "allow")),
	named("GUARD-2 unknown Studio tool asks", tool("mcp__Roblox_Studio__set_place_settings", "ask")),
	named("GUARD-2 unknown Studio tool with publish code is denied", mcp("mcp__Roblox_Studio__run_code", { code: 'game:GetService("AssetService"):SavePlaceAsync()' }, "deny")),
	named("GUARD-2 Luau PromptRobuxTransfer in a multi_edit is denied", mcp("mcp__Roblox_Studio__multi_edit", { edits: [{ new_string: "MarketplaceService:PromptRobuxTransferAsync(p, 10)" }] }, "deny")),
	// Blender MCP: unknown tools ask; code tools of another Blender server (Blender Lab) are checked as code.
	named("GUARD-3 unknown Blender tool asks", tool("mcp__blender__frobnicate_scene", "ask")),
	named("GUARD-3 Blender Lab execute_blender_code with plain bpy stays allowed", mcp("mcp__blender_lab__execute_blender_code", { code: "import bpy\nprint(len(bpy.data.objects))" }, "allow")),
	named("GUARD-3 Blender Lab execute_blender_code_for_cli reaching the network asks", mcp("mcp__blender_lab__execute_blender_code_for_cli", { code: "import urllib.request\nurllib.request.urlopen('https://example.com')" }, "ask")),
	// Other MCP servers (connectors, plugins, ChatGPT apps): ask (deny in Codex); GitHub reads pass.
	named("GUARD-4 claude.ai connector tool asks", tool("mcp__claude_ai_Figma__create_new_file", "ask")),
	named("GUARD-4 Codex app tool asks", tool("mcp__codex_apps__gmail__send_email", "ask")),
	named("GUARD-4 plugin MCP tool asks", tool("mcp__plugin_linear_linear__create_issue", "ask")),
	named("GUARD-4 GitHub read stays allowed", mcp("mcp__github__get_file_contents", { owner: "o", repo: "r", path: "README.md" }, "allow")),
	named("GUARD-4 GitHub plugin search stays allowed", tool("mcp__plugin_github_github__search_code", "allow")),
	named("GUARD-4 GitHub pull_request_read stays allowed", tool("mcp__github__pull_request_read", "allow")),
	named("GUARD-4 GitHub write asks", tool("mcp__github__create_pull_request", "ask")),
	named("GUARD-4 GitHub merge asks", tool("mcp__github__merge_pull_request", "ask")),
	named("GUARD-4 unknown MCP tool is denied in Codex", ["guard_mcp.mjs", { tool_name: "mcp__codex_apps__gmail__send_email", tool_input: {}, turn_id: "t1" }, "deny"]),
	named("GUARD-4 GitHub read stays allowed in Codex", ["guard_mcp.mjs", { tool_name: "mcp__github__list_issues", tool_input: {}, turn_id: "t1" }, "allow"]),
	// Purchases and store writes through the kits' own adapters, where the engine API name never shows:
	// asked like the call they wrap (denied in Codex); read-only use of the same adapters passes.
	named("GUARD-6 CommerceRoblox.prompt under an alias asks", luau('local CR = require(game.ReplicatedStorage.Packages.GameKit.CommerceRoblox)\nCR.prompt(game:GetService("MarketplaceService"), catalog, "subscription_a", player)', "ask")),
	named("GUARD-6 CommerceRoblox prompt through ctx.kit asks", luau('ctx.kit("GameKit/CommerceRoblox").prompt(market, catalog, "pass_a", p, { policy = allow }, ctx.env)', "ask")),
	named("GUARD-6 CommerceRoblox prompt by string key asks", luau('local CR = require(kits.CommerceRoblox)\nCR["prompt"](market, catalog, "pass_a", p)', "ask")),
	named("GUARD-6 CommerceRoblox prompt is denied in Codex", ["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__execute_luau", tool_input: { code: "local CR = require(kits.CommerceRoblox)\nCR.prompt(market, catalog, 'pass_a', p)" } }, "deny", ["--client=codex"]]),
	named("GUARD-6 LeaderboardRoblox writes = true and submit asks", luau('local LB = require(kits.LeaderboardRoblox)\nlocal b = LB.new("board_a", { writes = true }, EnvRoblox.studio())\nb:submit("1", 10)', "ask")),
	named("GUARD-6 LeaderboardRoblox writes = true alone asks", luau('_G.board = require(kits.LeaderboardRoblox).new("board_a", { writes = true }, env)', "ask")),
	named("GUARD-6 LeaderboardRoblox remove asks", luau('local b = require(kits.LeaderboardRoblox).new("board_a", opts, env)\nprint(b:remove("1"))', "ask")),
	named("GUARD-6 LiveBoardRoblox map written by LiveBoard submit asks", luau('local board = LiveBoard.new(LiveBoardRoblox.map("round_scores", env), { ttl = 600 }, env)\nboard:submit("1", 10)', "ask")),
	named("GUARD-6 MemoryQueueRoblox push asks", luau('local mq = MemoryQueueRoblox.new(game:GetService("MemoryStoreService"), { name = "q" }, env)\nmq:push(ticket)', "ask")),
	named("GUARD-6 MemoryQueueRoblox ack asks", luau("local mq = require(kits.MemoryQueueRoblox).new(mss, { name = 'q' }, env)\nmq:ack(readId)", "ask")),
	named("GUARD-6 MemoryQueueRoblox cycle asks", luau("local mq = require(kits.MemoryQueueRoblox).new(mss, { name = 'q' }, env)\nmq:cycle({}, onMatch)", "ask")),
	named("GUARD-6 PlayerDataRoblox allowStudioDataStores asks", luau('local backend = PlayerDataRoblox.chooseBackend({ storeName = "d", allowStudioDataStores = true }, env)', "ask")),
	named("GUARD-6 PlayerData DataStore backend asks", luau('local backend = PlayerData.dataStoreBackend(dss:GetDataStore("d"), { serverId = "s", now = now }, env)', "ask")),
	named("GUARD-6 PlayerData ProfileStore backend asks", luau('local backend = PlayerData.profileStoreBackend(ProfileStore, "d", {})', "ask")),
	named("GUARD-6 RobloxReceiptAdapter.store asks", luau('local ledger = ReceiptLedger.new({ store = RobloxReceiptAdapter.store(dss:GetDataStore("r")) })', "ask")),
	named("GUARD-6 PlayerDataRoblox chooseBackend with kind datastore asks", luau('local backend = PlayerDataRoblox.chooseBackend({ storeName = "d", kind = "datastore" }, env)', "ask")),
	named("GUARD-6 PlayerDataRoblox chooseBackend with kind profilestore set beforehand asks", luau("local opts = { storeName = 'd', ['kind'] = 'profilestore', profileStore = ProfileStore }\nlocal backend = require(kits.PlayerDataRoblox).chooseBackend(opts, env)", "ask")),
	named("GUARD-6 ReceiptLedger process asks", luau('local ledger = ReceiptLedger.new({ store = dss:GetDataStore("r"), namespace = "n", universeId = 1, products = products })\nprint(ledger:process(receipt))', "ask")),
	named("GUARD-6 RobloxReceiptAdapter handler over a ledger asks", luau("local handle = RobloxReceiptAdapter.handler(ReceiptLedger.new(opts), nil, Enum)\nprint(handle(receipt))", "ask")),
	named("GUARD-6 ReceiptLedger process is denied in Codex", ["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__execute_luau", tool_input: { code: "local ledger = require(kits.ReceiptLedger).new(opts)\nledger:process(receipt)" } }, "deny", ["--client=codex"]]),
	named("GUARD-6 CommerceRoblox price and ownership reads stay allowed", luau("local CR = require(kits.CommerceRoblox)\nlocal provider = CR.priceProvider(ms, nil, env)\nprint(provider:price(product), CR.priceLevels(ms, { 1 }))", "allow")),
	named("GUARD-6 InteractRoblox.prompt without CommerceRoblox stays allowed", luau('local prompt = InteractRoblox.prompt(target, env.roblox, { action = "Use" })', "allow")),
	named("GUARD-6 LeaderboardRoblox reads stay allowed", luau('local b = require(kits.LeaderboardRoblox).new("board_a", { writes = false }, env)\nlocal rows = b:top(10)\ntable.remove(rows, 1)\nprint(b:get("1"), b.options.writes == true)', "allow")),
	named("GUARD-6 LiveBoardRoblox direction stays allowed", luau('print(LiveBoardRoblox.direction("Ascending"), LiveBoard.new(LiveBoardRoblox.map("r", env), nil, env):top(5))', "allow")),
	named("GUARD-6 MemoryQueueRoblox size stays allowed", luau("print(require(kits.MemoryQueueRoblox).new(mss, { name = 'q' }, env):size())", "allow")),
	named("GUARD-6 PlayerDataRoblox chooseBackend with kind memory stays allowed", luau('local backend, kind = PlayerDataRoblox.chooseBackend({ storeName = "d", kind = "memory" }, env)\nprint(kind == "datastore")', "allow")),
	named("GUARD-6 ReceiptLedger reads stay allowed", luau("local RL = require(kits.ReceiptLedger)\nlocal ledger = RL.new({ store = fakeStore, namespace = 'n', universeId = 1, products = {} })\nprint(ledger:key(1), RL.DEFAULT_RETENTION_DAYS)", "allow")),
	named("GUARD-6 PlayerDataRoblox memory backend stays allowed", luau('local backend, kind = PlayerDataRoblox.chooseBackend({ storeName = "d", allowStudioDataStores = false }, env)\nprint(kind, PlayerData.memoryBackend({ serverId = "studio" }))', "allow")),
	// Owner records (release/owner-*.json): only the owner writes, moves or deletes them.
	named("GUARD-5 owner record: redirect", bash(`echo '{}' > ${OWN}`, "deny")),
	named("GUARD-5 owner record: append", bash(`echo '{}' >> ${OWN}`, "deny")),
	named("GUARD-5 owner record: tee", bash(`jq '.items=[]' /tmp/x.json | tee ${OWN}`, "deny")),
	named("GUARD-5 owner record: cp onto it", bash(`cp /tmp/forged.json ${OWN}`, "deny")),
	named("GUARD-5 owner record: mv into the release folder", bash(`mv /tmp/${OWN_LEAF} release/`, "deny")),
	named("GUARD-5 owner record: sed -i", bash(`sed -i 's/false/true/' ${OWN}`, "deny")),
	named("GUARD-5 owner record: rm -f", bash(`rm -f ${OWN}`, "deny")),
	named("GUARD-5 owner record: touch another record", bash("touch release/owner-signoff.json", "deny")),
	named("GUARD-5 owner record: glob of records", bash("rm release/owner-*.json", "deny")),
	named("GUARD-5 owner record: release/* glob", bash("sed -i s/a/b/ release/*", "deny")),
	named("GUARD-5 owner record: inside the release folder", bash("cd release && echo '{}' > owner-signoff.json", "deny")),
	named("GUARD-5 owner record: rm * inside a release folder", bash("cd templates/starter/release && rm *", "deny")),
	named("GUARD-5 owner record: the starter template copy", bash(`printf '{}' > templates/starter/${OWN}`, "deny")),
	named("GUARD-5 owner record: python writes it", bash(`python3 -c "open('${OWN}', 'w').write('{}')"`, "deny")),
	named("GUARD-5 owner record: xargs rm", bash("ls release/owner-*.json | xargs rm", "deny")),
	named("GUARD-5 owner record: PowerShell Set-Content", bash(`powershell -Command "Set-Content ${OWN} '{}'"`, "deny")),
	named("GUARD-5 owner record: git checkout of an older version", bash(`git checkout HEAD~1 -- ${OWN}`, "deny")),
	named("GUARD-5 owner record: git restore", bash(`git restore ${OWN}`, "deny")),
	named("GUARD-5 owner record: path in a variable", bash(`F=${OWN}; echo '{}' > "$F"`, "deny")),
	named("GUARD-5 owner record: for loop over records", bash(`for f in release/owner-*.json; do echo '{}' > "$f"; done`, "deny")),
	named("GUARD-5 owner record: Codex apply_patch update", fileEdit("apply_patch", { command: patch(`*** Update File: ${OWN}`, "@@", '-  "items": []', '+  "items": ["x"]') }, "deny")),
	named("GUARD-5 owner record: Codex apply_patch add (array input)", fileEdit("apply_patch", { command: ["apply_patch", patch(`*** Add File: templates/starter/${OWN}`, "+{}")] }, "deny")),
	named("GUARD-5 owner record: Codex apply_patch move onto it", fileEdit("apply_patch", { input: patch("*** Update File: /tmp/x.json", `*** Move to: ${OWN}`) }, "deny")),
	named("GUARD-5 owner record: Codex apply_patch delete", fileEdit("apply_patch", { patch: patch(`*** Delete File: ${OWN}`) }, "deny")),
	named("GUARD-5 protected folder: Codex apply_patch into it", fileEdit("apply_patch", { command: patch(`*** Add File: ../${W}/x.json`, "+{}") }, "deny")),
	named("GUARD-5 owner record: Claude Write", fileEdit("Write", { file_path: `/work/game/${OWN}`, content: "{}" }, "deny")),
	named("GUARD-5 owner record: Claude Edit", fileEdit("Edit", { file_path: OWN, old_string: "a", new_string: "b" }, "deny")),
	named("GUARD-5 owner record: cat and jq stay allowed", bash(`cat ${OWN} && jq . ${OWN}`, "allow")),
	named("GUARD-5 owner record: copy elsewhere stays allowed", bash(`cp ${OWN} /tmp/owner-copy.json`, "allow")),
	named("GUARD-5 owner record: git diff, add and commit stay allowed", bash(`git diff ${OWN} && git add ${OWN} && git commit -m "Owner sign-off"`, "allow")),
	named("GUARD-5 owner record: rg for it stays allowed", bash(`rg -n "${OWN}" docs tools`, "allow")),
	named("GUARD-5 release report writes stay allowed", bash("mkdir -p release && echo '{}' > release/report.json", "allow")),
	named("GUARD-5 release check run stays allowed", bash("python3 templates/starter/tools/release_check.py --root /tmp/game --out release/report.json", "allow")),
	named("GUARD-5 owner-named file outside release stays allowed", bash("echo '{}' > /tmp/owner-notes.json", "allow")),
	named("GUARD-5 apply_patch of ordinary files stays allowed", fileEdit("apply_patch", { command: patch("*** Update File: release/report.json", "@@", "-a", "+b", "*** Add File: docs/notes.md", "+x") }, "allow")),
	named("GUARD-5 Write whose content shows a patch stays allowed", fileEdit("Write", { file_path: "docs/notes.md", content: patch(`*** Update File: ${OWN}`) }, "allow")),
	// Copies under fixtures/ or tests/ are test data for the release check, not owner records.
	named("GUARD-5 fixture record: redirect stays allowed", bash(`mkdir -p fixtures/release/good/release && echo '{}' > fixtures/release/good/${OWN}`, "allow")),
	named("GUARD-5 fixture record: cd into a fixture release folder stays allowed", bash("cd tests/fixtures/release && printf '{}' > owner-signoff.json", "allow")),
	named("GUARD-5 fixture record: cp and rm stay allowed", bash(`cp ${OWN} fixtures/release/bad/${OWN} && rm -f fixtures/release/old/release/owner-*.json`, "allow")),
	named("GUARD-5 fixture record: Codex apply_patch stays allowed", fileEdit("apply_patch", { command: patch(`*** Add File: fixtures/release/bad/${OWN}`, "+{}") }, "allow")),
	named("GUARD-5 fixture record: Claude Write below the project stays allowed", fileEdit("Write", { file_path: `/work/game/fixtures/release/good/${OWN}`, content: "{}" }, "allow", "/work/game")),
	named("GUARD-5 fixture record: .. out of fixtures", bash(`echo '{}' > fixtures/../${OWN}`, "deny")),
	named("GUARD-5 fixture record: .. out of tests into the template", bash(`cp /tmp/x.json tests/../templates/starter/${OWN}`, "deny")),
	named("GUARD-5 fixture record: cd out of fixtures into release", bash("cd fixtures/release && cd ../../release && echo '{}' > owner-signoff.json", "deny")),
	named("GUARD-5 fixture record: Claude Write with .. out of fixtures", fileEdit("Write", { file_path: `/work/game/fixtures/../${OWN}`, content: "{}" }, "deny", "/work/game")),
	named("GUARD-5 fixture record: Claude Write outside the project", fileEdit("Write", { file_path: `/elsewhere/fixtures/x/${OWN}`, content: "{}" }, "deny", "/work/game")),
	named("GUARD-5 fixture record: python names a project record", bash(`python3 -c "open('fixtures/x/${OWN}', 'w'); open('${OWN}', 'w')"`, "deny")),
];

let failed = 0;
let firstFailure = "";
const fail = (msg) => {
	failed++;
	firstFailure ||= msg;
	console.log(`FAIL ${msg}`);
};
// Cases rely on these being unset (a URL in an unset variable is treated as a Roblox URL).
const hookEnv = { ...process.env };
for (const k of ["ROBLOX_ASSETS_URL", "X", "D", "F", "P", "BRANCH", "COOKIE", "BODY", "GIT_DIR", "GIT_WORK_TREE", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS"]) delete hookEnv[k];
const run = (file, args, event, options = {}) =>
	new Promise((done) => {
		const child = spawn(file, args, { env: hookEnv, ...options });
		let stdout = "";
		let stderr = "";
		child.stdout.on("data", (d) => (stdout += d));
		child.stderr.on("data", (d) => (stderr += d));
		child.on("error", (err) => (stderr += err.message));
		child.on("close", (status) => done({ status, stdout, stderr }));
		child.stdin.end(JSON.stringify(event));
	});
const runAll = async (jobs) => {
	const out = [];
	let next = 0;
	await Promise.all(
		Array.from({ length: 8 }, async () => {
			while (next < jobs.length) {
				const k = next++;
				out[k] = await jobs[k]();
			}
		}),
	);
	return out;
};
const verdict = (r) => (r.status !== 0 ? `error ${r.status}: ${(r.stderr || "").split("\n")[0]}` : r.stdout ? JSON.parse(r.stdout).hookSpecificOutput.permissionDecision : "allow");
const label = (script, event, name) => `${name ? `[${name}] ` : ""}${script} ${event.tool_name.startsWith("mcp__") ? event.tool_name + " " : ""}${JSON.stringify(event.tool_input).slice(0, 100)}${event.cwd ? " (cwd " + event.cwd + ")" : ""}`;

const results = await runAll(cases.map(([script, event, , args = []]) => () => run(process.execPath, [join(here, script), ...args], event)));
for (const [k, [script, event, expected, , name]] of cases.entries()) {
	const got = verdict(results[k]);
	if (got !== expected) fail(`${label(script, event, name)}: expected ${expected}, got ${got}`);
}
console.log(`${cases.length - failed}/${cases.length} hook cases (${cases.filter((c) => /^HOOK-/.test(c[4] ?? "")).length} named audit regressions, ${cases.filter((c) => /^GUARD-/.test(c[4] ?? "")).length} named second-pass cases)`);

// HOOK-7: the largest commands the guard accepts (just under its 64 KiB cap) are decided well inside
// the hook timeout (5 s in .claude/settings.json, 10 s in .codex/hooks.json); a timed-out hook lets
// the command run. Each shape ends in a publish command, so the whole text must be parsed.
const nearCap = {
	lines: (n) => "echo line\n".repeat(n),
	heredocs: (n) => Array.from({ length: n }, (_, i) => `cat <<E${i}\nbody\nE${i}\n`).join(""),
	pipes: (n) => "cat a | grep x && ".repeat(n),
	nested: (n) => `bash -c "${"echo x; ".repeat(n)}${R} ${UP}"; `,
};
let slowest = 0;
for (const [shape, make] of Object.entries(nearCap)) {
	let n = 1;
	while (make(n * 2).length + 40 < 64 * 1024) n *= 2;
	while (make(n + 16).length + 40 < 64 * 1024) n += 16;
	const command = `${make(n)}${R} ${UP} --asset_id 1`;
	const t0 = Date.now();
	const r = spawnSync(process.execPath, [join(here, "guard_bash.mjs")], { input: JSON.stringify({ tool_name: "Bash", tool_input: { command } }), encoding: "utf8", env: hookEnv });
	const ms = Date.now() - t0;
	slowest = Math.max(slowest, ms);
	if (verdict(r) !== "deny" || ms > 2500) fail(`[HOOK-7 near-cap ${shape}] ${command.length} chars: expected deny within 2500 ms, got ${verdict(r)} in ${ms} ms`);
}
console.log(`near-cap commands (${Object.keys(nearCap).length} shapes, just under 64 KiB) denied in at most ${slowest} ms`);

// ---- Codex parity --------------------------------------------------------------------------------
// The same cases through the hook commands .codex/hooks.json configures: the matcher must route each
// tool to the same guard, the command must start it from the repository root as Codex's shell would
// (sh -c; cmd /c with commandWindows on Windows), and the verdict must match, except that an ask is
// a deny in Codex.
const codexHooks = JSON.parse(readFileSync(join(repoRoot, ".codex", "hooks.json"), "utf8")).hooks.PreToolUse;
const codexRun = (event) => {
	const entries = codexHooks.filter((e) => new RegExp(e.matcher).test(event.tool_name));
	if (entries.length !== 1 || entries[0].hooks.length !== 1) return null;
	const h = entries[0].hooks[0];
	const codexEvent = { session_id: "selftest", turn_id: "selftest-turn", hook_event_name: "PreToolUse", tool_use_id: "call_selftest", model: "selftest", permission_mode: "default", cwd: repoRoot, ...event };
	if (process.platform === "win32") return () => run("cmd.exe", ["/d", "/s", "/c", h.commandWindows ?? h.command], codexEvent, { cwd: repoRoot, windowsVerbatimArguments: true });
	return () => run("sh", ["-c", h.command], codexEvent, { cwd: repoRoot });
};
const codexCases = cases.filter(([, , , args]) => !args);
const codexResults = await runAll(codexCases.map(([, event]) => codexRun(event) ?? (async () => ({ status: -1, stdout: "", stderr: "no single .codex/hooks.json PreToolUse entry matches this tool" }))));
let codexOk = 0;
for (const [k, [script, event, expected]] of codexCases.entries()) {
	const h = codexHooks.find((e) => new RegExp(e.matcher).test(event.tool_name))?.hooks[0] ?? {};
	const want = expected === "ask" ? "deny" : expected;
	const got = verdict(codexResults[k]);
	const routed = [h.command, h.commandWindows].every((c) => c?.includes(`tools/hooks/${script}`) && c.includes("--client=codex"));
	if (!routed) fail(`.codex/hooks.json sends ${event.tool_name} to "${h.command}" / "${h.commandWindows}", not tools/hooks/${script} --client=codex`);
	else if (got !== want) fail(`codex ${label(script, event, codexCases[k][4])}: expected ${want}, got ${got}`);
	else codexOk++;
}
console.log(`${codexOk}/${codexCases.length} hook cases through .codex/hooks.json (asks become denies)`);

// Codex execution-policy rules (.codex/rules/factory.rules). Codex splits a plain command line
// (words and quotes joined by && || ; |) and matches each command against the prefix rules; a line
// with variables, substitutions, redirections, globs or control flow is one opaque command that no
// prefix rule matches, so only the hook covers it. Every plain deny case headed by a publishing tool
// or `git push` must be forbidden or prompted by the rules, and no allow case may be forbidden.
// With the Codex CLI on PATH (or CODEX_BIN), each decision is also compared with
// `codex execpolicy check`, which validates the rules file the same way Codex does at startup.
const rulesFile = join(repoRoot, ".codex", "rules", "factory.rules");
let rules = [];
try {
	rules = parseRules(readFileSync(rulesFile, "utf8"));
} catch (err) {
	fail(err.message);
}
const RANK = { allow: 1, prompt: 2, forbidden: 3 };
const matches = (rule, argv) => rule.pattern.length <= argv.length && rule.pattern.every((alts, i) => alts.includes(argv[i]));
const strictest = (decisions) => decisions.filter(Boolean).sort((a, b) => RANK[b] - RANK[a])[0] ?? null;
const ruleDecision = (argv) => strictest(rules.filter((r) => matches(r, argv)).map((r) => r.decision));
for (const r of rules) {
	for (const ex of r.match) if (!matches(r, shellWords(ex))) fail(`${rulesFile}: match example "${ex}" does not match its rule ${JSON.stringify(r.pattern)}`);
	for (const ex of r.not_match) if (matches(r, shellWords(ex))) fail(`${rulesFile}: not_match example "${ex}" matches its rule ${JSON.stringify(r.pattern)}`);
}
const RULE_HEADS = /^(rojo|rojo\.exe|mantle|tarmac|rbxcloud|asphalt|npx|bunx|pnpx|wally|wally\.exe|pesde|pesde\.exe)$/;
// Owner-record writes a prefix rule can see: a writer or git checkout/restore whose first argument
// (after at most one option) is the documented record.
const ownerRuleShaped = (a) => {
	const i = /^(tee|rm|touch|truncate|shred|unlink)$/.test(a[0]) ? 1 : a[0] === "git" && /^(checkout|restore)$/.test(a[1]) ? 2 : -1;
	return i > 0 && (a[i] === OWN || (String(a[i]).startsWith("-") && a[i + 1] === OWN));
};
const checked = new Map(); // argv JSON -> our decision, for the codex cross-check
let ruleCovered = 0;
let ruleShaped = 0;
let hookOnly = 0;
let prompted = 0;
for (const [script, event, expected] of cases) {
	if (script !== "guard_bash.mjs" || event.tool_name !== "Bash") continue;
	const argvs = codexCommands(event.tool_input.command) ?? [];
	for (const argv of argvs) checked.set(JSON.stringify(argv), ruleDecision(argv));
	const worst = strictest(argvs.map(ruleDecision));
	if (expected === "allow") {
		if (worst === "forbidden") fail(`.codex/rules forbids an allowed command: ${event.tool_input.command}`);
		if (worst === "prompt") prompted++;
	} else if (!argvs.some((a) => RULE_HEADS.test(a[0]) || (a[0] === "git" && a[1] === "push") || ownerRuleShaped(a))) hookOnly++;
	// A plain `git push` denied only because of the repository's own config (a mirror remote) cannot be
	// told apart by a prefix rule; only the hook reads that config.
	else if (worst === null && event.cwd === mirrorRepo) hookOnly++;
	else {
		ruleShaped++;
		if (worst === "forbidden" || worst === "prompt") ruleCovered++;
		else fail(`.codex/rules lets a denied publishing, registry or owner-record command through: ${event.tool_input.command}`);
	}
}
console.log(`${ruleCovered}/${ruleShaped} plain publish/upload/registry/owner-record/force-push deny cases forbidden or prompted by .codex/rules (${hookOnly} more are hook-only: URLs, variables, nested scripts); ${prompted} allow cases prompted, none forbidden`);
const codexBin = process.env.CODEX_BIN || "codex";
const codexVersion = spawnSync(codexBin, ["--version"], { encoding: "utf8" });
if (codexVersion.status === 0) {
	let same = 0;
	for (const [key, ours] of checked) {
		const r = spawnSync(codexBin, ["execpolicy", "check", "--rules", rulesFile, "--", ...JSON.parse(key)], { encoding: "utf8" });
		const theirs = r.status === 0 ? (JSON.parse(r.stdout).decision ?? null) : `error: ${(r.stderr || "").split("\n")[0]}`;
		if (theirs === ours) same++;
		else fail(`codex execpolicy check -- ${JSON.parse(key).join(" ")}: codex says ${theirs}, self-test parser says ${ours}`);
	}
	console.log(`${same}/${checked.size} rule decisions identical to \`codex execpolicy check\` (${codexVersion.stdout.trim()})`);
} else console.log(`codex CLI not found: rules evaluated by the self-test parser only (set CODEX_BIN to cross-check)`);

// .codex/config.toml mirrors .mcp.json (same servers, commands, args, env), prompts natively for
// exactly the tools the MCP guard asks for and disables exactly the tools it denies, so a session
// whose hooks are not yet trusted still asks or never sees them. Every Studio tool must have an
// explicit class in the guard (not the "does not classify" fallback).
const tomlRead = spawnSync(python, ["-c", "import json, sys, tomllib; print(json.dumps(tomllib.load(open(sys.argv[1], 'rb'))))", join(repoRoot, ".codex", "config.toml")], { encoding: "utf8" });
const codexConfig = tomlRead.status === 0 ? JSON.parse(tomlRead.stdout) : null;
if (!codexConfig) fail(`.codex/config.toml could not be read with ${python} (tomllib): ${tomlRead.error?.message || tomlRead.stderr}`);
else {
	const sandbox = { approval_policy: codexConfig.approval_policy, sandbox_mode: codexConfig.sandbox_mode, network_access: codexConfig.sandbox_workspace_write?.network_access };
	if (JSON.stringify(sandbox) !== JSON.stringify({ approval_policy: "on-request", sandbox_mode: "workspace-write", network_access: false })) fail(`.codex/config.toml must keep on-request approvals, workspace-write and no network, got ${JSON.stringify(sandbox)}`);
	const claudeServers = JSON.parse(readFileSync(join(repoRoot, ".mcp.json"), "utf8")).mcpServers;
	const codexServers = codexConfig.mcp_servers ?? {};
	const pick = (s) => JSON.stringify({ command: s.command, args: s.args ?? [], env: s.env ?? {} });
	for (const name of new Set([...Object.keys(claudeServers), ...Object.keys(codexServers)]))
		if (!claudeServers[name] || !codexServers[name] || pick(claudeServers[name]) !== pick(codexServers[name])) fail(`MCP server "${name}" differs between .mcp.json and .codex/config.toml`);
	const prompts = new Set(Object.entries(codexServers).flatMap(([s, c]) => Object.entries(c.tools ?? {}).filter(([, t]) => t.approval_mode === "prompt").map(([t]) => `mcp__${s}__${t}`)));
	const disabled = new Set(Object.entries(codexServers).flatMap(([s, c]) => (c.disabled_tools ?? []).map((t) => `mcp__${s}__${t}`)));
	if (STUDIO_TOOLS.length !== 26 || new Set(STUDIO_TOOLS).size !== 26) fail(`STUDIO_TOOLS must list the 26 Studio MCP tools once each, got ${STUDIO_TOOLS.length}`);
	const settings = JSON.parse(readFileSync(join(repoRoot, ".claude", "settings.json"), "utf8")).permissions;
	const claudeRule = (name) => (settings.deny ?? []).includes(name) ? "deny" : settings.ask.includes(name) ? "ask" : settings.allow.includes(name) ? "allow" : null;
	const known = new Set([...settings.allow, ...settings.ask, ...(settings.deny ?? [])].filter((p) => p.startsWith("mcp__")));
	if (codexServers.blender) for (const t of BLENDER_TOOLS) known.add(`mcp__blender__${t}`);
	if (codexServers.Roblox_Studio) for (const t of STUDIO_TOOLS) known.add(`mcp__Roblox_Studio__${t}`);
	for (const t of [...prompts, ...disabled]) known.add(t);
	const names = [...known].sort();
	const asked = await runAll(names.map((name) => () => run(process.execPath, [join(here, "guard_mcp.mjs")], { tool_name: name, tool_input: {} })));
	let agree = 0;
	names.forEach((name, i) => {
		const v = verdict(asked[i]);
		const reason = v === "ask" || v === "deny" ? JSON.parse(asked[i].stdout).hookSpecificOutput.permissionDecisionReason : "";
		if ((v === "ask") !== prompts.has(name)) fail(`${name}: guard_mcp says ${v} but .codex/config.toml ${prompts.has(name) ? "prompts" : "does not prompt"}`);
		else if ((v === "deny") !== disabled.has(name)) fail(`${name}: guard_mcp says ${v} but .codex/config.toml ${disabled.has(name) ? "disables" : "does not disable"} it`);
		else if (/does not classify/.test(reason)) fail(`${name}: guard_mcp has no class for this tool`);
		// .claude/settings.json may leave a tool unlisted (Claude then prompts), but a rule it lists must match the guard.
		else if (claudeRule(name) && claudeRule(name) !== v) fail(`${name}: .claude/settings.json says ${claudeRule(name)} but guard_mcp says ${v}`);
		else agree++;
	});
	console.log(`.codex/config.toml: ${Object.keys(codexServers).length} MCP servers identical to .mcp.json; ${agree}/${names.length} tools (all ${STUDIO_TOOLS.length} Studio tools) classified, prompted in Codex exactly when guard_mcp asks and disabled exactly when it denies, and no .claude/settings.json rule disagrees`);
}

// Secret patterns: one sample per label, flagged identically by this hook library and tools/check.py.
const rep = (c, n) => c.repeat(n);
const samples = [
	["Roblox .ROBLOSECURITY cookie", `.ROBLOSECURITY=_|${"WARNING"}:-DO-NOT-SHARE-THIS.--Sharing|${rep("F", 40)}`],
	["Roblox Open Cloud API key", `curl -H "${"x-api"}-key: ${rep("A", 48)}" ${API}/cloud/v2/universes/1`],
	["Roblox Open Cloud API key", `ROBLOX_${"API"}_KEY=${rep("C", 60)}`],
	["Roblox Open Cloud API key", `rbxcloud datastore get --api-${"key"} ${rep("E", 52)}`],
	["private key", `-----BEGIN ${"OPENSSH PRIVATE"} KEY-----`],
	["GitHub token", `token = "${"ghp"}_${rep("a", 36)}"`],
	["GitHub token", `token = "${"github"}_pat_${rep("B", 70)}"`],
	["Anthropic API key", `${"sk-ant"}-api03-${rep("x", 40)}`],
	["OpenAI API key", `${"sk-proj"}-${rep("y", 48)}`],
	["AWS access key", `${"AKIA"}ABCDEFGHIJKLMNOP`],
	["AWS secret key", `${"aws_secret"}_access_key = ${rep("z", 40)}`],
	["Slack token", `${"xoxb"}-${rep("1", 24)}`],
	["Slack webhook", `https://hooks.${"slack"}.com/services/T${rep("0", 8)}/B${rep("0", 8)}/${rep("w", 24)}`],
	["Google API key", `${"AIza"}${rep("q", 35)}`],
	[null, 'curl -H "x-api-key: $RBX_KEY" https://example.invalid'],
	[null, "ROBLOX_API_KEY: ${{ secrets.ROBLOX_API_KEY }}"],
	[null, "ghp_short sk-short AKIAshort"],
];
const labels = new Set(secretPatterns().map(([, label]) => label));
for (const label of labels) if (!samples.some(([l]) => l === label)) fail(`secret-patterns.json label "${label}" has no self-test sample`);
const pyScript = [
	"import json, sys",
	"sys.path.insert(0, sys.argv[1])",
	"import check",
	"patterns = check.load_secret_patterns()",
	"print(json.dumps([check.find_secrets(t, patterns) for t in json.load(sys.stdin)]))",
].join("\n");
const py = spawnSync(python, ["-c", pyScript, join(here, "..")], { input: JSON.stringify(samples.map(([, t]) => t)), encoding: "utf8" });
const pyLabels = py.status === 0 ? JSON.parse(py.stdout) : null;
if (!pyLabels) fail(`tools/check.py secret patterns could not be evaluated with ${python}: ${py.error?.message || py.stderr}`);
samples.forEach(([label, sample], i) => {
	const js = findSecrets(sample).sort();
	const pyl = pyLabels ? [...pyLabels[i]].sort() : js;
	if (label === null ? js.length : !js.includes(label)) fail(`edit hook secret scan on sample ${i}: expected ${label ?? "nothing"}, got [${js}]`);
	if (JSON.stringify(js) !== JSON.stringify(pyl)) fail(`secret scan disagrees on sample ${i}: edit hook [${js}], check.py [${pyl}]`);
});

// The edit hook reports a planted credential back to Claude (exit 2).
const planted = join(temp, "planted.md");
writeFileSync(planted, `${samples[1][1]}\n`);
const edit = spawnSync("node", [join(here, "fast_on_edit.mjs")], {
	input: JSON.stringify({ tool_name: "Write", tool_input: { file_path: planted } }),
	encoding: "utf8",
	env: { ...process.env, CLAUDE_PROJECT_DIR: temp },
});
if (edit.status !== 2 || !edit.stderr.includes("Roblox Open Cloud API key")) fail(`fast_on_edit on a planted key: exit ${edit.status}, ${edit.stderr.trim()}`);
console.log(`${samples.length} secret samples checked against the edit hook and tools/check.py`);

rmSync(temp, { recursive: true, force: true });
// Last line names the first failure, so a gate that shows only the tail still says what broke.
if (failed) console.log(`FAILED ${failed} check(s); first: ${firstFailure}`);
process.exit(failed ? 1 : 0);
