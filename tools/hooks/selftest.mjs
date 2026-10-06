// Feeds known-good and known-bad events to the guards so hook regressions fail the gate, in both
// directions: every deny/ask class has a case, and so do the reads that must stay allowed.
// Also checks that tools/check.py and the edit hook flag the same secrets from secret-patterns.json.
// Dangerous command strings and fake credentials are assembled at runtime so this file never trips
// the guard or the secret scan itself.
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { findSecrets, secretPatterns } from "./lib.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const R = ["ro", "jo"].join("");
const UP = ["up", "load"].join("");
const API = `https://${["apis", "roblox", "com"].join(".")}`;
const W = ["weppy", "project", "sync"].join("-");
const K = '-H "x-api-key: $RBX_KEY"';

// Temporary repositories so a bare forced push resolves against a known branch.
const temp = mkdtempSync(join(tmpdir(), "hooks-selftest-"));
const repo = (branch) => {
	const dir = join(temp, branch.replace(/\W/g, "_"));
	spawnSync("git", ["init", "-q", "-b", branch, dir]);
	return dir;
};
const onMain = repo("main");
const onFeature = repo("claude/feature-x");

const bash = (command, expected, cwd) => ["guard_bash.mjs", { tool_name: "Bash", tool_input: { command }, cwd }, expected];
const luau = (code, expected) => ["guard_mcp.mjs", { tool_name: "mcp__Roblox_Studio__execute_luau", tool_input: { code } }, expected];
const tool = (name, expected) => ["guard_mcp.mjs", { tool_name: name, tool_input: {} }, expected];

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
	luau("MarketplaceService:PromptPremiumPurchase(p)", "ask"),
	luau("MarketplaceService:PromptSubscriptionPurchase(p, 'EXP-1')", "ask"),
	luau("MarketplaceService:PromptBulkPurchase(p, {}, {})", "ask"),
	luau("MarketplaceService:PromptRobuxTransferAsync(p, 10)", "ask"),
	luau("store:SetAsync('k', 1)", "ask"),
	luau('ds:UpdateAsync ("k", function(v) return v end)', "ask"),
	luau('queue:AddAsync("v", 60)', "ask"),
	luau('sortedMap:SetAsync("k", 1, 60)', "ask"),
	luau("print(workspace:GetChildren())", "allow"),
	luau("print(MarketplaceService:GetProductInfo(1), MarketplaceService:UserOwnsGamePassAsync(1, 2))", "allow"),
	luau("print(store:GetAsync('k'))", "allow"),
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
for (const k of ["ROBLOX_ASSETS_URL", "X", "D", "P", "GIT_DIR", "GIT_WORK_TREE"]) delete hookEnv[k];
const runHook = (script, event) =>
	new Promise((done) => {
		const child = spawn(process.execPath, [join(here, script)], { env: hookEnv });
		let stdout = "";
		let stderr = "";
		child.stdout.on("data", (d) => (stdout += d));
		child.stderr.on("data", (d) => (stderr += d));
		child.on("close", (status) => done({ status, stdout, stderr }));
		child.stdin.end(JSON.stringify(event));
	});
const results = [];
let next = 0;
await Promise.all(
	Array.from({ length: 8 }, async () => {
		while (next < cases.length) {
			const k = next++;
			results[k] = await runHook(cases[k][0], cases[k][1]);
		}
	}),
);
for (const [k, [script, event, expected]] of cases.entries()) {
	const r = results[k];
	const got = r.status !== 0 ? `error ${r.status}: ${(r.stderr || "").split("\n")[0]}` : r.stdout ? JSON.parse(r.stdout).hookSpecificOutput.permissionDecision : "allow";
	if (got !== expected) fail(`${script} ${JSON.stringify(event.tool_input).slice(0, 100)}${event.cwd ? " (cwd " + event.cwd + ")" : ""}: expected ${expected}, got ${got}`);
}
console.log(`${cases.length - failed}/${cases.length} hook cases`);

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
const python = process.env.FACTORY_PYTHON || (process.platform === "win32" ? "python" : "python3");
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
