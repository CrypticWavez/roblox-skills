// PreToolUse guard for Bash. Every rule denies; there is no ask path. Denied:
//  - publishing and uploads: rojo upload (global flags and rojo.exe included), mantle deploy/destroy,
//    tarmac sync --target roblox / upload-image, and every rbxcloud subcommand except get*/list*/help;
//  - write requests to Roblox web APIs (*.roblox.com, apis.roblox.com Open Cloud included): curl with
//    -X/--request other than GET/HEAD/OPTIONS or any body (-d/--data*, -F/--form*, --json, -T/--upload-file),
//    wget --post-*/--body-*/--method, httpie with a write method or data items, Invoke-RestMethod /
//    Invoke-WebRequest with -Method Post|Put|Patch|Delete, -Body, -InFile or -Form, and inline
//    scripts calling .post()/.put()/.patch()/.delete(). This covers asset uploads, place publishing,
//    DataStore/OrderedDataStore/MessagingService writes, game passes and developer products.
//    Plain GET reads pass;
//  - force pushes (--force, -f, --force-with-lease, +refspec, --mirror) and deletions whose
//    destination is a protected branch (main, master). Force pushes to other branches, such as an
//    agent's own claude/* work branch, are allowed. A forced push with no refspec is resolved
//    against the current branch and its upstream, and denied when that cannot be resolved;
//  - writes into weppy-project-sync/: redirections, rm/mv/cp/tee/touch/... targets, sed -i, find
//    -delete, inline-script writes, and git subcommands other than read-only ones run there.
//    Reads (cat, ls, rg, git status/log/diff, copying out of it) pass.
// Command lines are parsed into simple commands (tools/hooks/shell.mjs) so argument order, quoting
// and nesting (bash -c, eval, $(...), powershell -Command) do not matter. Hooks never publish anything.
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { isAbsolute, resolve } from "node:path";
import { decide, readEvent } from "./lib.mjs";
import { commandName, parseCommands } from "./shell.mjs";

// Fail closed: a bug in this guard must block the command, not wave it through.
process.on("uncaughtException", (err) => decide("deny", `guard_bash.mjs failed (${err.message}); fix the hook (node tools/hooks/selftest.mjs) before retrying.`));

const event = readEvent();
const text = String(event.tool_input?.command || "");
const baseCwd = event.cwd || process.cwd();
const commands = parseCommands(text);
// The raw text plus every parsed word, so decoded nested scripts (powershell -EncodedCommand) count too.
const allText = [text, ...commands.flatMap((c) => [...c.argv, ...c.redirs.map((r) => `${r.target}\n${r.body ?? ""}`)])].join("\n");
const APPROVAL = "SETUP_ONLY forbids publishing, uploads, spending and production-data writes without Ethan's explicit approval.";

function deny(why) {
	decide("deny", `Blocked by factory guard: ${why}. ${APPROVAL}`);
}

const positionals = (args, valueOpts = []) => {
	const out = [];
	for (let i = 0; i < args.length; i++) {
		if (valueOpts.includes(args[i])) i++;
		else if (!args[i].startsWith("-") || args[i] === "-") out.push(args[i]);
	}
	return out;
};

// ---- publish / upload tools ------------------------------------------------------------------
// Raw-text backstop for the one-line place publish, in case a form escapes the parser.
if (/\brojo(\.exe)?\b(\s+-\S+)*\s+upload\b/i.test(allText)) deny("rojo upload publishes a place");

for (const { argv } of commands) {
	const name = commandName(argv[0]);
	const args = argv.slice(1);
	if (name === "rojo" && positionals(args, ["--color", "--colour"])[0] === "upload") deny("rojo upload publishes a place");
	if (name === "mantle" && ["deploy", "destroy"].includes(positionals(args)[0])) deny(`mantle ${positionals(args)[0]} changes a live experience`);
	if (name === "tarmac") {
		const sub = positionals(args, ["--target"])[0];
		const target = args.find((a, i) => args[i - 1] === "--target" || a.startsWith("--target="));
		if (sub === "upload-image" || (sub === "sync" && /roblox/i.test(target || ""))) deny("tarmac uploads assets to Roblox");
	}
	if (name === "rbxcloud") {
		const [group, verb] = positionals(args);
		const read = group === undefined || group === "help" || verb === undefined || verb === "help" || /^(get|list)(-|$)/.test(verb);
		if (!read) deny(`rbxcloud ${group} ${verb} writes to Roblox (only get*/list*/help subcommands are allowed)`);
	}
}

// ---- write requests to Roblox web APIs ------------------------------------------------------
const ROBLOX_HOST = /\b(?:[a-z0-9-]+\.)*ro(?:blox|proxy)\.com\b/i;
const WRITE_METHOD = /^(POST|PUT|PATCH|DELETE)$/i;
const READ_METHOD = /^(GET|HEAD|OPTIONS)$/i;
const splitEq = (a) => {
	const k = a.indexOf("=");
	return k < 0 ? [a, undefined] : [a.slice(0, k), a.slice(k + 1)];
};

function curlWrites(args) {
	const CURL_VALUE_SHORT = new Set("AbcCDeEHKmoPQrtuUwxyYz".split(""));
	let method = null;
	let body = false;
	let upload = false;
	let get = false;
	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		if (a.startsWith("--")) {
			const [n, v] = splitEq(a);
			if (n === "--request") method = v ?? args[++i] ?? "";
			else if (/^--data(-[a-z]+)?$/.test(n)) body = true;
			else if (["--json", "--form", "--form-string", "--upload-file"].includes(n)) upload = true;
			else if (n === "--get") get = true;
			continue;
		}
		if (!a.startsWith("-") || a.length < 2) continue;
		for (let k = 1; k < a.length; k++) {
			const ch = a[k];
			if (ch === "X") {
				method = a.slice(k + 1) || args[++i] || "";
				break;
			}
			if (ch === "d" || ch === "F" || ch === "T") {
				if (ch === "d") body = true;
				else upload = true;
				if (k === a.length - 1) i++;
				break;
			}
			if (ch === "G") get = true;
			else if (CURL_VALUE_SHORT.has(ch)) {
				if (k === a.length - 1) i++;
				break;
			}
		}
	}
	if (upload) return true;
	if (method !== null) return !READ_METHOD.test(method.trim());
	return body && !get;
}

function wgetWrites(args) {
	let method = null;
	for (let i = 0; i < args.length; i++) {
		const [n, v] = splitEq(args[i]);
		if (["--post-data", "--post-file", "--body-data", "--body-file"].includes(n)) return true;
		if (n === "--method") method = v ?? args[++i] ?? "";
	}
	return method !== null && !READ_METHOD.test(method);
}

function httpieWrites(args) {
	const VALUE = ["-a", "--auth", "-A", "--auth-type", "--session", "--session-read-only", "-o", "--output", "--verify", "--cert", "--cert-key", "--proxy", "-p", "--print", "--pretty", "-s", "--style", "--timeout", "--max-redirects", "--boundary", "--default-scheme", "--format-options", "--raw"];
	if (args.some((a) => a === "--raw" || a.startsWith("--raw="))) return true;
	const pos = positionals(args, VALUE);
	let method = null;
	if (pos.length > 1 && /^[a-z]+$/i.test(pos[0])) method = pos.shift();
	if (method) return !READ_METHOD.test(method);
	return pos.slice(1).some((item) => {
		const m = /==|:=@|:=|=@|@|=|:/.exec(item);
		return m !== null && m[0] !== "==" && m[0] !== ":";
	});
}

function powershellWrites(args) {
	let method = null;
	let body = false;
	for (let i = 0; i < args.length; i++) {
		const m = /^-(\w+)(?::(.+))?$/.exec(args[i]);
		if (!m) continue;
		const n = m[1].toLowerCase();
		if (n === "method" || n === "custommethod") method = m[2] ?? args[i + 1] ?? "";
		else if (["body", "infile", "form"].includes(n)) body = true;
	}
	if (method !== null) return !READ_METHOD.test(method);
	return body;
}

const HTTP_CLIENTS = {
	curl: (a) => curlWrites(a) || powershellWrites(a), // curl is an Invoke-WebRequest alias in Windows PowerShell
	wget: (a) => wgetWrites(a) || powershellWrites(a),
	wget2: wgetWrites,
	http: httpieWrites,
	https: httpieWrites,
	xh: httpieWrites,
	xhs: httpieWrites,
	"invoke-restmethod": powershellWrites,
	"invoke-webrequest": powershellWrites,
	irm: powershellWrites,
	iwr: powershellWrites,
};

if (ROBLOX_HOST.test(allText)) {
	for (const { argv } of commands) {
		const check = HTTP_CLIENTS[commandName(argv[0])];
		if (!check) continue;
		const hosts = argv.slice(1).flatMap((a) => [...a.matchAll(/https?:\/\/([^/\s'"?#]+)/gi)].map((m) => m[1]));
		const targetsRoblox = hosts.length ? hosts.some((h) => ROBLOX_HOST.test(h)) : true; // URL in a variable: assume Roblox
		if (targetsRoblox && check(argv.slice(1))) deny("write request (POST/PUT/PATCH/DELETE or a request body) to a Roblox web API: Open Cloud assets, places, DataStores, OrderedDataStores, MessagingService, game passes and developer products are production data");
	}
	const interpreter = commands.some(({ argv }) => /^(python[\d.]*|py|node|deno|bun|ruby|perl|php|pwsh|powershell)$/.test(commandName(argv[0])));
	const SCRIPT_WRITE = /\.(post|put|patch|delete)\s*\(|\bmethod\s*[:=]\s*["'`]?(post|put|patch|delete)\b|\brequest\s*\(\s*["'](post|put|patch|delete)["']|-Method\s+["']?(post|put|patch|delete)\b/i;
	if (interpreter && SCRIPT_WRITE.test(allText)) deny("inline script sends a write request to a Roblox web API");
}

// ---- force pushes to protected branches ------------------------------------------------------
const PROTECTED = /^(main|master)$/i;
const isProtected = (ref) => {
	const name = String(ref || "").replace(/^\+/, "").replace(/^refs\/heads\//, "").replace(/^heads\//, "");
	return PROTECTED.test(name) || name.includes("*");
};

function git(dir, args) {
	const r = spawnSync("git", ["-C", dir, ...args], { encoding: "utf8", timeout: 2000 });
	return r.status === 0 ? r.stdout.trim() : null;
}

// Where a bare `git push` goes: the current branch (push.default simple/current) and its upstream.
function defaultDestinations(dir) {
	const branch = git(dir, ["symbolic-ref", "--short", "-q", "HEAD"]);
	if (!branch) return null;
	const merge = git(dir, ["config", "--get", `branch.${branch}.merge`]);
	return [branch, merge].filter(Boolean);
}

// git's global options before the subcommand.
function gitInvocation(args, cwd) {
	let dir = cwd;
	let i = 0;
	for (; i < args.length; i++) {
		const a = args[i];
		if (a === "-C") dir = resolve(dir, args[++i] || ".");
		else if (["-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix"].includes(a)) {
			if (a === "--work-tree") dir = resolve(dir, args[i + 1] || ".");
			i++;
		} else if (a.startsWith("--work-tree=")) dir = resolve(dir, a.slice(12));
		else if (!a.startsWith("-")) break;
	}
	return { dir, sub: args[i], rest: args.slice(i + 1) };
}

function checkPush(rest, dir) {
	let force = false;
	let del = false;
	let all = false;
	const lease = [];
	const pos = [];
	for (let i = 0; i < rest.length; i++) {
		const a = rest[i];
		if (a === "--") {
			pos.push(...rest.slice(i + 1));
			break;
		}
		if (a.startsWith("--")) {
			const [n, v] = splitEq(a);
			if (n === "--force") force = true;
			else if (n === "--force-with-lease") {
				force = true;
				if (v) lease.push(v.split(":")[0]);
			} else if (n === "--mirror") deny("git push --mirror overwrites every remote branch, including main/master");
			else if (n === "--delete") del = true;
			else if (n === "--all" || n === "--branches") all = true;
			else if (["--repo", "--receive-pack", "--exec", "--push-option"].includes(n) && v === undefined) i++;
			continue;
		}
		if (a.startsWith("-") && a.length > 1) {
			for (let k = 1; k < a.length; k++) {
				if (a[k] === "f") force = true;
				else if (a[k] === "d") del = true;
				else if (a[k] === "o") {
					if (k === a.length - 1) i++;
					break;
				}
			}
			continue;
		}
		pos.push(a);
	}
	const why = "force-push or deletion of a protected branch (main/master); force pushes are allowed only to other branches";
	if (force && lease.some(isProtected)) deny(why);
	const refspecs = pos.slice(1);
	let current;
	const currentBranch = () => (current ??= git(dir, ["symbolic-ref", "--short", "-q", "HEAD"]));
	for (const spec of refspecs) {
		const plus = spec.startsWith("+");
		const body = plus ? spec.slice(1) : spec;
		const colon = body.indexOf(":");
		const src = colon < 0 ? body : body.slice(0, colon);
		let dst = colon < 0 || body.slice(colon + 1) === "" ? src : body.slice(colon + 1);
		if (colon >= 0 && src === "") {
			if (isProtected(dst)) deny(why);
			continue;
		}
		if (dst === "HEAD" || dst === "@") dst = currentBranch();
		if ((force || plus || del) && (dst === null || isProtected(dst))) deny(why);
	}
	if (!refspecs.length && force) {
		if (all) deny(`${why} (--all includes them)`);
		const dests = defaultDestinations(dir);
		if (dests === null) deny(`${why}; the destination of a forced push without a refspec could not be resolved, so name the branch explicitly`);
		if (dests.some(isProtected)) deny(why);
	}
}

// ---- weppy-project-sync is read-only -----------------------------------------------------------
const WEPPY = /weppy-project-sync/i;
const WRITE_ANY_ARG = new Set(["rm", "rmdir", "mv", "tee", "touch", "truncate", "mkdir", "chmod", "chown", "chgrp", "dd", "shred", "unlink", "patch", "del", "erase", "rd", "ren", "rename", "move", "remove-item", "ri", "set-content", "sc", "add-content", "ac", "out-file", "new-item", "ni", "move-item", "mi", "rename-item", "rni", "clear-content", "clc"]);
const WRITE_DEST = new Set(["cp", "copy", "copy-item", "cpi", "rsync", "scp", "install", "ln", "unzip"]);
const GIT_READ = new Set(["status", "log", "diff", "show", "rev-parse", "ls-files", "ls-tree", "ls-remote", "blame", "grep", "describe", "shortlog", "cat-file", "rev-list", "name-rev", "show-ref", "for-each-ref", "help", "version"]);

// The path a copy-like command writes to.
function destination(name, args) {
	const flag = { unzip: ["-d"], "copy-item": ["-destination"], cpi: ["-destination"], copy: ["-destination"], rsync: [], scp: [] }[name] ?? ["-t", "--target-directory"];
	const t = args.findIndex((a) => flag.includes(a.toLowerCase()));
	if (t >= 0) return args[t + 1] || "";
	const attached = args.find((a) => a.startsWith("--target-directory="));
	if (attached) return attached.split("=")[1];
	if (name === "unzip") return ".";
	const pos = positionals(args, ["-S", "--suffix"]);
	return pos.length > 1 ? pos[pos.length - 1] : "";
}

// git arguments that can name paths (commit messages are text, not paths).
function gitPathArgs(rest) {
	const out = [];
	for (let i = 0; i < rest.length; i++) {
		if (["-m", "--message", "-F", "--file"].includes(rest[i])) i++;
		else if (!/^(-m.|--message=|--file=)/.test(rest[i])) out.push(rest[i]);
	}
	return out;
}

let cwd = baseCwd;
let inWeppy = WEPPY.test(baseCwd);
let previous = { cwd, inWeppy };
const weppyAnywhere = WEPPY.test(allText) || inWeppy;
for (const { argv, redirs, viaXargs } of commands) {
	const name = commandName(argv[0]);
	const args = argv.slice(1);
	if (["cd", "pushd", "chdir", "set-location", "sl"].includes(name)) {
		const target = positionals(args)[0] || "~";
		const here = { cwd, inWeppy };
		if (target === "-") ({ cwd, inWeppy } = previous);
		else {
			const stays = inWeppy && !isAbsolute(target) && !/^(~|\.\.|[A-Za-z]:)/.test(target);
			inWeppy = WEPPY.test(target) || stays;
			cwd = target.startsWith("~") ? resolve(homedir(), target.replace(/^~[/\\]?/, "") || ".") : resolve(cwd, target);
		}
		previous = here;
		continue;
	}
	if (name === "git") {
		const { dir, sub, rest } = gitInvocation(args, cwd);
		if (sub === "push") checkPush(rest, dir);
		const touchesWeppy = WEPPY.test(dir) || inWeppy || gitPathArgs(rest).some((a) => WEPPY.test(a));
		if (weppyAnywhere && touchesWeppy && sub && !GIT_READ.has(sub)) deny(`git ${sub} would modify weppy-project-sync/, which is outside this setup's ownership`);
		continue;
	}
	if (!weppyAnywhere) continue;
	const hit = (s) => WEPPY.test(s) || (inWeppy && !isAbsolute(s) && !/^(~|\.\.|\/dev\/)/.test(s));
	const weppyDeny = (what) => decide("deny", `weppy-project-sync/ is outside this setup's ownership; do not modify it (${what}).`);
	for (const r of redirs) if (r.op.includes(">") && !(r.op.endsWith("&") && /^\d*-?$/.test(r.target)) && hit(r.target)) weppyDeny(`redirect ${r.op} ${r.target}`);
	const pathArgs = args.filter((a) => !a.startsWith("-"));
	if (WRITE_ANY_ARG.has(name) && (viaXargs || pathArgs.some(hit))) weppyDeny(name);
	if (WRITE_DEST.has(name)) {
		const dest = destination(name, args);
		if (hit(dest) || (viaXargs && !dest)) weppyDeny(`${name} into it`);
	}
	const inPlace = { sed: /^-[nEsrzu]*i|^--in-place/, perl: /^-[pnlaws0]*i/ }[name];
	if (inPlace && args.some((a) => inPlace.test(a)) && (viaXargs || pathArgs.some(hit))) weppyDeny(`${name} -i`);
	if (name === "find" && args.some((a) => WEPPY.test(a)) && args.includes("-delete")) weppyDeny("find -delete");
	if (/^(python[\d.]*|py|node|deno|bun|ruby|perl|php)$/.test(name)) {
		const code = [...args, ...redirs.map((r) => r.body || "")].join("\n");
		const WRITES = /\b(write\w*|append\w*|unlink\w*|remove\w*|rmtree|rm(Sync|dir\w*)?|rename\w*|mkdir\w*|makedirs|truncate\w*|move\w*|chmod\w*)\b|open\s*\([^)]*,\s*["'][wax]|mode\s*=\s*["'][wax]/i;
		if (WEPPY.test(code) && WRITES.test(code)) weppyDeny("inline script writes");
	}
}
process.exit(0);
