// PreToolUse guard for Bash. Every rule denies; there is no ask path. Denied:
//  - publishing and uploads: rojo upload (global flags and rojo.exe included), mantle deploy/destroy,
//    tarmac sync --target roblox / upload-image, and every rbxcloud subcommand except get*/list*/help,
//    also when started through npx/pnpm/yarn/bunx or a command name held in a variable;
//  - write requests to Roblox web APIs (*.roblox.com, apis.roblox.com Open Cloud included): curl with
//    -X/--request other than GET/HEAD/OPTIONS or any body (-d/--data*, -F/--form*, --json,
//    -T/--upload-file, -K/--config), wget --post-*/--body-*/--method, httpie with a write method, data
//    items or a stdin body, Invoke-RestMethod / Invoke-WebRequest with -Method Post|Put|Patch|Delete,
//    -Body, -InFile or -Form (any unambiguous abbreviation such as -Met/-Bod/-InF) or splatted
//    parameters, and inline scripts (python/node/ruby/perl/php/pwsh/...) that send a body or a
//    POST/PUT/PATCH/DELETE: requests/httpx/axios .post(), fetch {method}, urllib Request(data=...)
//    or urlopen(url, body), WebClient.Upload*, curl_setopt POST. This covers asset uploads, place
//    publishing, DataStore/OrderedDataStore/MessagingService writes, game passes and developer
//    products. A write whose URL is not visible (an unset variable, a curl config file, xargs input)
//    is treated as a Roblox write. Plain GET reads and writes to other literal hosts pass;
//  - force pushes (--force, -f, --force-with-lease, +refspec, --mirror) and deletions whose
//    destination is a protected branch (main, master). Force pushes to other branches, such as an
//    agent's own claude/* work branch, are allowed. A forced push with no refspec is resolved
//    against the current branch and its upstream, and denied when that cannot be resolved;
//  - anything that may write into weppy-project-sync/. When a command line names that directory (or
//    runs inside it), each command that names it, runs in it, or takes paths from input must be a
//    known read-only command (cat, ls, rg, grep, head, diff, jq, find without -delete, sed/awk
//    without in-place or write commands, ...), a copy whose destination is elsewhere, or a read-only
//    git subcommand (status, log, diff, show, ...; git -C, --git-dir, --work-tree, GIT_DIR and
//    GIT_WORK_TREE all count). Everything else is denied: redirections into it, rm/mv/tee/touch,
//    curl -o, wget -O, tar -C, unzip -d, awk -i inplace, interpreters, build tools, git writes.
//    Variables assigned in the same command line (D=..., export, for, read, $1, PowerShell $x = ...)
//    are followed; a value that comes from input counts as naming it.
// Command lines are parsed into simple commands (tools/hooks/shell.mjs) so argument order, quoting
// and nesting (bash -c, eval, $(...), heredocs and echo piped into a shell, powershell -Command) do
// not matter. Residual risk: scripts in files, aliases, and paths or URLs produced by programs.
// Hooks never publish anything.
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
function weppyDeny(what) {
	decide("deny", `weppy-project-sync/ is outside this setup's ownership; do not modify it (${what}). Read it with cat/ls/rg/git log, or copy files out of it.`);
}

const positionals = (args, valueOpts = []) => {
	const out = [];
	for (let i = 0; i < args.length; i++) {
		if (valueOpts.includes(args[i])) i++;
		else if (!args[i].startsWith("-") || args[i] === "-") out.push(args[i]);
	}
	return out;
};
const splitEq = (a) => {
	const k = a.indexOf("=");
	return k < 0 ? [a, undefined] : [a.slice(0, k), a.slice(k + 1)];
};

// ---- variables assigned in this command line ---------------------------------------------------
// name -> { value, tainted }. tainted: the value comes from input or another program's output.
const vars = new Map();
const INPUT_VARS = /^(\d+|[@*_]|PSItem|input|args|REPLY)$/i;
let cwd = { path: baseCwd, unknown: false };

// Expands $NAME, ${NAME...}, $env:NAME. Unknown names stay as text (so they still look unresolved).
function expandWord(word) {
	let tainted = false;
	const value = String(word).replace(/\$\{([A-Za-z_]\w*|\d+|[@*])[^}]*\}|\$env:([A-Za-z_]\w*)|\$([A-Za-z_]\w*|\d|[@*])/gi, (m, braced, env, plain) => {
		const name = braced ?? env ?? plain;
		const known = vars.get(name) ?? [...vars].find(([k]) => k.toLowerCase() === name.toLowerCase())?.[1];
		if (known) {
			tainted ||= known.tainted;
			return known.value;
		}
		if (!env && INPUT_VARS.test(name)) {
			tainted = true;
			return m;
		}
		if (name === "PWD") return cwd.path;
		if (name === "HOME") return homedir();
		if (process.env[name] !== undefined) return process.env[name];
		return m;
	});
	if (/\$\(|`/.test(value)) tainted = true; // command substitution: a program's output
	return { value, tainted, unresolved: /\$|`/.test(value) };
}
const assign = (name, raw) => vars.set(name, expandWord(raw));

// ---- publish / upload tools ----------------------------------------------------------------------
const PUBLISH_TOOLS = new Set(["rojo", "mantle", "tarmac", "rbxcloud"]);
const RUNNERS = new Set(["npx", "bunx", "pnpx", "pnpm", "yarn", "npm", "rokit", "aftman", "foreman", "mise", "asdf", "proto", "cargo", "dotnet"]);
const PUBLISH_VERBS = /^(upload|upload-image|deploy|destroy|publish|sync)$/i;

function checkPublishTool(tool, args) {
	const pos = (opts) => positionals(args, opts).map((p) => p.toLowerCase());
	if (tool === "rojo" && pos(["--color", "--colour"])[0] === "upload") deny("rojo upload publishes a place");
	if (tool === "mantle" && ["deploy", "destroy"].includes(pos()[0])) deny(`mantle ${pos()[0]} changes a live experience`);
	if (tool === "tarmac") {
		const sub = pos(["--target"])[0];
		const target = args.find((a, i) => args[i - 1] === "--target" || a.startsWith("--target="));
		if (sub === "upload-image" || (sub === "sync" && /roblox/i.test(target || ""))) deny("tarmac uploads assets to Roblox");
	}
	if (tool === "rbxcloud") {
		const [group, verb] = pos();
		const read = group === undefined || group === "help" || verb === undefined || verb === "help" || /^(get|list)(-|$)/.test(verb);
		if (!read) deny(`rbxcloud ${group} ${verb} writes to Roblox (only get*/list*/help subcommands are allowed)`);
	}
}

// ---- write requests to Roblox web APIs -----------------------------------------------------------
const ROBLOX_HOST = /\b(?:[a-z0-9-]+\.)*ro(?:blox|proxy)\.com\b/i;
const READ_METHOD = /^(GET|HEAD|OPTIONS)$/i;

const CURL_SHORT_VALUE = new Set("AbcCDdeEFHKmoPQrtTuUwxXyYz".split(""));
const CURL_LONG_VALUE = new Set(
	(
		"abstract-unix-socket alt-svc aws-sigv4 cacert capath cert cert-type ciphers config connect-timeout connect-to " +
		"continue-at cookie cookie-jar create-file-mode curves data data-ascii data-binary data-raw data-urlencode delegation " +
		"dns-interface dns-ipv4-addr dns-ipv6-addr dns-servers doh-url dump-header ech egd-file engine etag-compare etag-save " +
		"expect100-timeout form form-string ftp-account ftp-alternative-to-user ftp-method ftp-port ftp-ssl-ccc-mode " +
		"happy-eyeballs-timeout-ms haproxy-clientip header hostpubmd5 hostpubsha256 hsts interface ip-tos json keepalive-time " +
		"key key-type krb libcurl limit-rate local-port login-options mail-auth mail-from mail-rcpt max-filesize max-redirs " +
		"max-time netrc-file noproxy oauth2-bearer output output-dir pass pinnedpubkey preproxy proto proto-default proto-redir " +
		"proxy proxy-cacert proxy-capath proxy-cert proxy-cert-type proxy-ciphers proxy-header proxy-key proxy-key-type " +
		"proxy-pass proxy-pinnedpubkey proxy-service-name proxy-tls13-ciphers proxy-tlsauthtype proxy-tlspassword " +
		"proxy-tlsuser proxy-user proxy1.0 pubkey quote random-file range rate referer request request-target resolve retry " +
		"retry-delay retry-max-time sasl-authzid service-name socks4 socks4a socks5 socks5-gssapi-service socks5-hostname " +
		"speed-limit speed-time stderr telnet-option tftp-blksize time-cond tls-max tls13-ciphers tlsauthtype tlspassword " +
		"tlsuser trace trace-ascii trace-config unix-socket upload-file url url-query user user-agent variable vlan-priority write-out"
	)
		.split(" ")
		.map((n) => `--${n}`),
);

function curlRequest(args) {
	const r = { writes: false, urls: [], unknown: false };
	let method = null;
	let body = false;
	let get = false;
	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		if (a.startsWith("--")) {
			const [n, attached] = splitEq(a);
			const v = attached ?? (CURL_LONG_VALUE.has(n) ? (args[++i] ?? "") : undefined);
			if (n === "--request") method = v;
			else if (/^--data(-[a-z]+)?$/.test(n)) body = true;
			else if (["--json", "--form", "--form-string", "--upload-file"].includes(n)) r.writes = true;
			else if (n === "--get") get = true;
			else if (n === "--url") r.urls.push(v);
			else if (n === "--config") r.writes = r.unknown = true;
			continue;
		}
		if (!a.startsWith("-") || a.length < 2) {
			r.urls.push(a);
			continue;
		}
		for (let k = 1; k < a.length; k++) {
			const ch = a[k];
			if (ch === "G") get = true;
			if (!CURL_SHORT_VALUE.has(ch)) continue;
			const v = k < a.length - 1 ? a.slice(k + 1) : (args[++i] ?? "");
			if (ch === "X") method = v;
			else if (ch === "d") body = true;
			else if (ch === "F" || ch === "T") r.writes = true;
			else if (ch === "K") r.writes = r.unknown = true;
			break;
		}
	}
	if (method !== null) r.writes ||= !READ_METHOD.test(method.trim());
	else r.writes ||= body && !get;
	return r;
}

const WGET_SHORT_VALUE = new Set("oaeiBtOTwQUPDXIARl".split(""));
const WGET_LONG_VALUE = new Set(
	(
		"output-file append-output execute input-file base config tries output-document timeout dns-timeout connect-timeout " +
		"read-timeout wait waitretry quota bind-address limit-rate user password header user-agent referer post-data post-file " +
		"body-data body-file method load-cookies save-cookies directory-prefix cut-dirs default-page level accept reject domains " +
		"exclude-domains include-directories exclude-directories ca-certificate ca-directory certificate private-key " +
		"certificate-type private-key-type secure-protocol http-user http-password proxy-user proxy-password " +
		"restrict-file-names progress rejected-log warc-file local-encoding remote-encoding max-redirect retry-on-http-error"
	)
		.split(" ")
		.map((n) => `--${n}`),
);

function wgetRequest(args) {
	const r = { writes: false, urls: [], unknown: false };
	let method = null;
	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		let n;
		let v;
		if (a.startsWith("--")) {
			[n, v] = splitEq(a);
			if (v === undefined && WGET_LONG_VALUE.has(n)) v = args[++i] ?? "";
		} else if (a.startsWith("-") && a.length > 1) {
			const k = [...a.slice(1)].findIndex((ch) => WGET_SHORT_VALUE.has(ch));
			if (k < 0) continue;
			n = `-${a[k + 1]}`;
			v = k + 2 < a.length ? a.slice(k + 2) : (args[++i] ?? "");
		} else {
			r.urls.push(a);
			continue;
		}
		if (["--post-data", "--post-file", "--body-data", "--body-file"].includes(n)) r.writes = true;
		else if (n === "--method") method = v;
		else if ((n === "-e" || n === "--execute") && /\b(post_data|post_file|body_data|body_file|method)\s*=/i.test(v)) r.writes = true;
		else if (n === "-i" || n === "--input-file" || n === "--config") r.unknown = true;
	}
	if (method !== null) r.writes ||= !READ_METHOD.test(method.trim());
	return r;
}

function httpieRequest(args, rec) {
	const VALUE = ["-a", "--auth", "-A", "--auth-type", "--session", "--session-read-only", "-o", "--output", "--verify", "--cert", "--cert-key", "--proxy", "-p", "--print", "--pretty", "-s", "--style", "--timeout", "--max-redirects", "--boundary", "--default-scheme", "--format-options", "--raw"];
	const pos = positionals(args, VALUE);
	let method = null;
	if (pos.length > 1 && /^[a-z]+$/i.test(pos[0])) method = pos.shift();
	const r = { writes: false, urls: pos.slice(0, 1), unknown: false };
	const stdinBody = (rec.piped || rec.redirs.some((x) => x.op === "<" || x.op.startsWith("<<"))) && !args.some((a) => a === "-I" || a === "--ignore-stdin");
	if (args.some((a) => a === "--raw" || a.startsWith("--raw="))) r.writes = true;
	else if (method) r.writes = !READ_METHOD.test(method);
	else
		r.writes =
			stdinBody ||
			pos.slice(1).some((item) => {
				const m = /==|:=@|:=|=@|@|=|:/.exec(item);
				return m !== null && m[0] !== "==" && m[0] !== ":";
			});
	return r;
}

// Invoke-RestMethod / Invoke-WebRequest. PowerShell accepts any unambiguous prefix of a parameter
// name (-Met, -Bod, -InF), so names are matched by prefix. minPrefix guards the curl/wget aliases.
const PS_SWITCHES = "usebasicparsing usedefaultcredentials disablekeepalive passthru skipcertificatecheck skipheadervalidation allowunencryptedauthentication noproxy preserveauthorizationonredirect resume skiphttperrorcheck allowinsecureredirect proxyusedefaultcredentials followrellink preservehttpmethodonredirect verbose debug".split(" ");
function psRequest(args, minPrefix = 1) {
	const r = { writes: false, urls: [], unknown: false };
	let method = null;
	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		const m = /^-([A-Za-z]\w*)(?::([\s\S]*))?$/.exec(a);
		if (!m) {
			if (/^@[A-Za-z_]\w*$/.test(a)) r.writes = r.unknown = true; // splatted parameters: cannot be checked
			else if (!a.startsWith("-")) r.urls.push(a);
			continue;
		}
		const n = m[1].toLowerCase();
		const is = (full) => n.length >= minPrefix && full.startsWith(n);
		const value = m[2] ?? (PS_SWITCHES.some((s) => s.startsWith(n)) ? undefined : args[++i]);
		if (is("method") || is("custommethod")) method = value ?? "";
		else if (is("body") || is("infile") || is("form")) r.writes = true;
		else if (n.length >= 2 && "uri".startsWith(n)) r.urls.push(value ?? "");
	}
	if (method !== null) r.writes ||= !READ_METHOD.test(method.replace(/^["']|["']$/g, "").trim());
	return r;
}

const merge = (...rs) => ({ writes: rs.some((r) => r.writes), urls: rs.flatMap((r) => r.urls), unknown: rs.some((r) => r.unknown) });
const HTTP_CLIENTS = {
	curl: (a) => merge(curlRequest(a), psRequest(a, 3)), // curl and wget are Invoke-WebRequest aliases in Windows PowerShell
	wget: (a) => merge(wgetRequest(a), psRequest(a, 3)),
	wget2: wgetRequest,
	http: httpieRequest,
	https: httpieRequest,
	xh: httpieRequest,
	xhs: httpieRequest,
	"invoke-restmethod": (a) => psRequest(a),
	"invoke-webrequest": (a) => psRequest(a),
	irm: (a) => psRequest(a),
	iwr: (a) => psRequest(a),
};

function hostOf(url) {
	const s = url.trim().replace(/^["']+|["']+$/g, "");
	const m = /^[a-z][\w+.-]*:\/\/([^/?#]*)/i.exec(s);
	return (m ? m[1] : /^[^/?#\s]*/.exec(s)[0]).replace(/^.*@/, "").replace(/:\d*$/, "");
}

function checkHttp(name, args, rec) {
	const req = HTTP_CLIENTS[name](args, rec);
	if (!req.writes) return;
	let unknown = req.unknown || req.urls.some((u) => /[$`]/.test(hostOf(u)));
	if (rec.viaXargs && (!req.urls.length || req.urls.some((u) => u.includes("{}")) || ROBLOX_HOST.test(allText))) unknown = true;
	if (unknown) deny(`write request (${name}) to a URL this guard cannot see (variable, config file or input); write the literal URL. Roblox web API writes are production data`);
	if (req.urls.some((u) => ROBLOX_HOST.test(hostOf(u))))
		deny("write request (POST/PUT/PATCH/DELETE or a request body) to a Roblox web API: Open Cloud assets, places, DataStores, OrderedDataStores, MessagingService, game passes and developer products are production data");
}

const INTERPRETER = /^(python[\d.]*|py|pypy[\d.]*|node|nodejs|deno|bun|ruby|perl|php|pwsh|powershell|lune|lua|luajit|osascript|rscript|tclsh|jshell)$/;
const SCRIPT_WRITE = new RegExp(
	[
		String.raw`(?:\.|->|::)\s*(?:post|put|patch|delete)(?:_?form|async)?\s*\(`, // requests.post( axios.put( $ua->post( Net::HTTP.post( client.PostAsync(
		String.raw`\bmethod\s*(?:[:=]|=>)\s*:?["'\x60]?(?:post|put|patch|delete)\b`, // fetch {method: 'POST'}, Request(method="PUT")
		String.raw`\brequest\s*\(\s*["'\x60](?:post|put|patch|delete)["'\x60]`, // http.client / urllib3 / requests.request("POST", ...)
		String.raw`-Method\s*:?\s*["']?(?:post|put|patch|delete)\b`,
		String.raw`[(,]\s*data\s*=`, // urllib.request.Request(url, data=...) sends a POST
		String.raw`\burlopen\s*\(\s*(?:[^(),]|\([^()]*\))+,\s*(?!timeout\s*=|context\s*=|cafile\s*=|capath\s*=|cadefault\s*=)[^\s)]`, // urlopen(url, body)
		String.raw`::(?:Post|Put|Patch|Delete)\b`, // Net::HTTP::Post
		String.raw`\bUpload(?:File|Data|String|Values)(?:Async|TaskAsync)?\b`, // .NET WebClient
		String.raw`HttpMethod\]?\s*(?:\.|::)\s*(?:Post|Put|Patch|Delete)\b`,
		String.raw`\bCURLOPT_(?:POST|POSTFIELDS|CUSTOMREQUEST|UPLOAD|PUT)\b`,
	].join("|"),
	"i",
);
const ROBLOX_ENV = /(?:environ|getenv|env)\W{1,4}\w*(?:ROBLOX|RBX|OPEN_?CLOUD)\w*/i;

// ---- force pushes to protected branches ----------------------------------------------------------
const PROTECTED = /^(main|master)$/i;
const isProtected = (ref) => {
	const name = String(ref || "")
		.replace(/^\+/, "")
		.replace(/^refs\/heads\//, "")
		.replace(/^heads\//, "");
	return PROTECTED.test(name) || name.includes("*");
};

function git(inv, args) {
	const pre = ["-C", inv.dir, ...(inv.gitDir ? [`--git-dir=${resolve(inv.dir, inv.gitDir)}`] : [])];
	const r = spawnSync("git", [...pre, ...args], { encoding: "utf8", timeout: 2000 });
	return r.status === 0 ? r.stdout.trim() : null;
}

// Where a bare `git push` goes: the current branch (push.default simple/current) and its upstream.
function defaultDestinations(inv) {
	const branch = git(inv, ["symbolic-ref", "--short", "-q", "HEAD"]);
	if (!branch) return null;
	const merge = git(inv, ["config", "--get", `branch.${branch}.merge`]);
	return [branch, merge].filter(Boolean);
}

// git's global options before the subcommand.
function gitInvocation(args, dir) {
	let gitDir = null;
	let workTree = null;
	let i = 0;
	for (; i < args.length; i++) {
		const a = args[i];
		const [n, v] = splitEq(a);
		if (a === "-C") dir = resolvePath(dir, args[++i] ?? ".");
		else if (n === "--git-dir") gitDir = v ?? args[++i] ?? "";
		else if (n === "--work-tree") workTree = v ?? args[++i] ?? "";
		else if (["-c", "--namespace", "--config-env", "--super-prefix", "--list-cmds"].includes(a)) i++;
		else if (!a.startsWith("-")) break;
	}
	return { dir, gitDir, workTree, sub: args[i], rest: args.slice(i + 1) };
}

function checkPush(inv) {
	const rest = inv.rest;
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
	const currentBranch = () => (current ??= git(inv, ["symbolic-ref", "--short", "-q", "HEAD"]));
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
		const dests = defaultDestinations(inv);
		if (dests === null) deny(`${why}; the destination of a forced push without a refspec could not be resolved, so name the branch explicitly`);
		if (dests.some(isProtected)) deny(why);
	}
}

// ---- weppy-project-sync is read-only ---------------------------------------------------------------
const WEPPY = /weppy-project-sync/i;
const WEPPY_DIR = /(^|[\\/])weppy-project-sync([\\/]|$)/i;
// The name as a path component (../weppy-project-sync/x, --dir=weppy-project-sync, -Cweppy-project-sync),
// not inside prose such as a PR body ("never modify weppy-project-sync").
const WEPPY_PATH = /(?:^|[\\/=:'"(,]|^-[A-Za-z]+)weppy-project-sync(?=$|[\\/'"\s;,)])/i;

// A glob component that could expand to weppy-project-sync (../weppy-*, ../*project-sync). Words
// with whitespace are prose or scripts, not paths.
function globHitsWeppy(s) {
	if (/\s/.test(s)) return false;
	return String(s)
		.split(/[\\/]/)
		.some((c) => {
			if (!/[*?[]/.test(c) || c.replace(/\*|\?|\[[^\]]*\]/g, "").length < 3) return false;
			let re = "";
			for (let i = 0; i < c.length; i++) {
				if (c[i] === "*") re += ".*";
				else if (c[i] === "?") re += ".";
				else if (c[i] === "[" && c.indexOf("]", i) > i) {
					re += c.slice(i, c.indexOf("]", i) + 1).replace(/^\[!/, "[^");
					i = c.indexOf("]", i);
				} else re += c[i].replace(/[.+^${}()|[\]\\]/g, "\\$&");
			}
			try {
				return new RegExp(`^${re}$`, "i").test("weppy-project-sync");
			} catch {
				return false; // not a valid glob class, so the shell would not expand it either
			}
		});
}
const pathy = (s) => WEPPY_PATH.test(s) || globHitsWeppy(s);

const weppyAnywhere = WEPPY.test(allText) || WEPPY_DIR.test(baseCwd) || commands.some((c) => [...c.argv, ...c.redirs.map((r) => r.target)].some(globHitsWeppy));

const READ_ONLY = new Set(
	(
		"cat tac less more head tail nl wc ls dir vdir tree exa eza lsd stat file du df find fd fdfind grep egrep fgrep zgrep rg ag ack " +
		"diff cmp comm cut tr column fold fmt paste join expand unexpand rev sort uniq jq yq xxd od hexdump strings bat batcat " +
		"md5sum sha1sum sha224sum sha256sum sha384sum sha512sum b2sum cksum shasum sum realpath readlink basename dirname pwd " +
		"echo printf test [ [[ true false : type which whereis hash id whoami date sleep uname hostname env printenv lsattr " +
		"getfacl namei sed awk gawk mawk nawk exit return break continue shift wait set shopt unset alias " +
		"get-content gc get-childitem gci select-string sls test-path resolve-path rvpa get-item gi get-itemproperty gp " +
		"get-filehash get-acl measure-object measure format-hex fhx compare-object compare select-object where-object foreach-object " +
		"% ? sort-object group-object format-list fl format-table ft out-string out-host convertto-json convertfrom-json " +
		"write-output write-host split-path join-path get-location gl findstr fc where"
	).split(" "),
);
const COPY_LIKE = new Set(["cp", "copy", "copy-item", "cpi", "rsync", "scp", "install", "robocopy", "xcopy"]);
const SCRIPT_RUNNER = new RegExp(`${INTERPRETER.source}|^(bash|sh|zsh|dash|ksh|fish|ash|mksh|busybox|cmd|wsl|source|\\.|make|gmake)$`);
const GIT_READ = new Set(
	(
		"status log diff show rev-parse ls-files ls-tree ls-remote blame annotate grep describe shortlog cat-file rev-list " +
		"name-rev show-ref for-each-ref help version whatchanged merge-base cherry range-diff check-ignore check-attr var " +
		"count-objects show-branch verify-commit verify-tag diff-tree diff-files diff-index"
	).split(" "),
);

function gitReadOnly(sub, rest) {
	if (GIT_READ.has(sub)) return true;
	const pos = rest.filter((a) => !a.startsWith("-"));
	const has = (re) => rest.some((a) => re.test(a));
	switch (sub) {
		case "branch":
			return !has(/^-[a-zA-Z]*[dDmMcCfu]|^--(delete|move|copy|force|set-upstream|unset-upstream|edit-description|track|no-track|create-reflog)/) && (pos.length === 0 || has(/^(-l|--list|--contains|--no-contains|--merged|--no-merged|--points-at)$/));
		case "remote":
			return pos.length === 0 || ["show", "get-url"].includes(pos[0]);
		case "stash":
			return ["list", "show"].includes(pos[0]);
		case "worktree":
			return pos[0] === "list";
		case "tag":
			return !has(/^-[a-zA-Z]*[dfasu]|^--(delete|force|annotate|sign)/) && (pos.length === 0 || has(/^(-l|--list|--contains|--points-at|--merged|--no-merged)/));
		case "config":
			return ["get", "list"].includes(pos[0]) || (has(/^(--get(-all|-regexp|-urlmatch|-color|colorbool)?|-l|--list)$/) && !has(/^(--(add|unset|unset-all|replace-all|rename-section|remove-section|edit)|-e)$/));
		case "reflog":
			return pos.length === 0 || pos[0] === "show";
		case "notes":
			return ["list", "show"].includes(pos[0]);
		case "submodule":
			return pos.length === 0 || ["status", "summary"].includes(pos[0]);
		default:
			return false;
	}
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

const SED_WRITE = /(?:^|[;{}\n])\s*(?:\d+|\$|\/(?:[^/\\\n]|\\.)*\/)?(?:,\s*(?:\d+|\$|\/(?:[^/\\\n]|\\.)*\/))?\s*[wWe](?:\s|$)|\/[gpiImMe0-9]*[we](?:\s|;|$)/;

// Destination of a copy-like command, or null when it cannot be told.
function copyDestination(name, args) {
	if (["copy-item", "cpi", "copy"].includes(name)) {
		const pos = [];
		for (let i = 0; i < args.length; i++) {
			const m = /^-([A-Za-z]+)(?::([\s\S]*))?$/.exec(args[i]);
			if (!m) pos.push(args[i]);
			else if ("destination".startsWith(m[1].toLowerCase())) return m[2] ?? args[i + 1] ?? "";
			else if (!["force", "recurse", "passthru", "container", "whatif", "confirm"].some((s) => s.startsWith(m[1].toLowerCase())) && m[2] === undefined) i++;
		}
		return pos[1] ?? null;
	}
	if (name === "robocopy" || name === "xcopy") return args.filter((a) => !a.startsWith("/"))[1] ?? null;
	const t = args.findIndex((a) => a === "-t" || a === "--target-directory");
	if (t >= 0) return args[t + 1] ?? "";
	const attached = args.find((a) => a.startsWith("--target-directory=") || /^-t./.test(a));
	if (attached) return attached.startsWith("-t") && !attached.startsWith("--") ? attached.slice(2) : attached.split("=")[1];
	const pos = positionals(args, ["-S", "--suffix", "-e", "--rsh", "-m", "--mode", "-o", "--owner", "-g", "--group"]);
	return pos.length > 1 ? pos[pos.length - 1] : null;
}

function tarVerdict(args, hit, inHere) {
	let letters = "";
	let file = null;
	const dirs = [];
	let exec = false;
	const words = [...args];
	if (words[0] && !words[0].startsWith("-")) words[0] = `-${words[0]}`; // old style: tar xzf a.tgz
	for (let i = 0; i < words.length; i++) {
		const a = words[i];
		const [n, v] = splitEq(a);
		if (n === "--directory") dirs.push(v ?? words[++i] ?? "");
		else if (n === "--file") file = v ?? words[++i] ?? "";
		else if (/^--(extract|get)$/.test(n)) letters += "x";
		else if (/^--(create|append|update|delete|concatenate|catenate)$/.test(n)) letters += "c";
		else if (/^--(to-command|use-compress-program|checkpoint-action|info-script|new-volume-script|rsh-command)$/.test(n)) exec = true;
		else if (/^-[A-Za-z]/.test(a) && !a.startsWith("--")) {
			for (let k = 1; k < a.length; k++) {
				const ch = a[k];
				if (ch === "f" || ch === "C" || ch === "I") {
					const value = k < a.length - 1 ? a.slice(k + 1) : (words[++i] ?? "");
					if (ch === "f") file = value;
					else if (ch === "C") dirs.push(value);
					else exec = true;
					break;
				}
				letters += "xcrud".includes(ch) ? (ch === "x" ? "x" : "c") : "";
			}
		}
	}
	if (exec) return "tar runs a helper command";
	if (letters.includes("x") && (dirs.length ? dirs.some(hit) : inHere)) return "tar extracts into it";
	if (letters.includes("c") && file !== null && hit(file)) return "tar writes an archive into it";
	return null;
}

// Why a command (outside git) may write into weppy-project-sync, or null.
function weppyVerdict(name, ex, rec, inHere) {
	if (rec.carrier) return null; // its script text was parsed into the commands that follow
	const args = ex.map((e) => e.value);
	const rel = (s) => !isAbsolute(s) && !/^(~|[A-Za-z]:[\\/]|\\\\|\/dev\/)/.test(s);
	const hitArg = (e) => pathy(e.value) || e.tainted;
	const hit = (s) => pathy(s) || /[$`]/.test(s) || (inHere && rel(s));
	// PowerShell is a full language (method calls, .NET statics) this parser cannot follow, so in a
	// line that names weppy-project-sync every PowerShell statement must be a read-only cmdlet.
	const touching = ex.some(hitArg) || inHere || rec.viaXargs || rec.nameTainted || rec.mode === "ps";
	if (READ_ONLY.has(name)) {
		if (!touching && !rec.piped) return null;
		const optVal = (opts) => args.flatMap((a, i) => (opts.includes(a) ? [args[i + 1] ?? ""] : opts.filter((o) => o.startsWith("--") && a.startsWith(`${o}=`)).map((o) => a.slice(o.length + 1))));
		if (name === "find" && args.some((a) => /^-(delete|fprint0?|fprintf|fls)$/.test(a)) && touching) return "find -delete/-fprint";
		if (name === "sed" && touching && (args.some((a) => /^-[a-zA-Z]*i|^--in-place/.test(a) || a === "-f" || a.startsWith("--file")) || args.some((a) => SED_WRITE.test(a)))) return "sed in place or with a w/e command";
		if (/^(g|m|n)?awk$/.test(name) && touching && (args.some((a) => /^-[a-zA-Z]*[if]$|^--(include|file|load)/.test(a)) || args.some((a) => /system\s*\(|[>|]/.test(a)))) return `${name} with -i/-f or output redirection`;
		if (name === "sort" && [...optVal(["-o", "--output"]), ...args.filter((a) => /^-o./.test(a)).map((a) => a.slice(2))].some(hit)) return "sort -o";
		if (name === "uniq" && positionals(args, ["-f", "-s", "-w"]).slice(1).some(hit)) return "uniq output file";
		if (name === "yq" && touching && args.some((a) => /^(-i|--inplace)$/.test(a))) return "yq -i";
		if (name === "xxd" && positionals(args, ["-c", "-g", "-l", "-o", "-s", "-n"]).slice(1).some(hit)) return "xxd output file";
		if (name === "tree" && optVal(["-o"]).some(hit)) return "tree -o";
		if (name === "rg" && touching && args.some((a) => a === "--pre" || a.startsWith("--pre="))) return "rg --pre runs a command";
		return null;
	}
	if (COPY_LIKE.has(name)) {
		if (name === "cp" && touching && args.some((a) => /^--(link|symbolic-link)$/.test(a) || /^-[a-zA-Z]*[ls]/.test(a))) return "cp -l/-s links files to it";
		if (name === "rsync" && args.some((a) => a.startsWith("--remove-source-files") || a.startsWith("--link-dest")) && touching) return "rsync --remove-source-files/--link-dest";
		if (/^(robocopy|xcopy)$/.test(name) && touching && args.some((a) => /^\/mov/i.test(a))) return `${name} /MOV`;
		const dest = copyDestination(name, args);
		if (dest === null ? rec.viaXargs || (inHere && touching) : hit(dest)) return `${name} into it`;
		return null;
	}
	if (name === "tar") return touching ? tarVerdict(args, hit, inHere) : null;
	if (name === "unzip") {
		if (args.some((a) => /^-[a-zA-Z]*[lvtpcZ]/.test(a) && !/^-d/.test(a))) return null; // list / test / to stdout
		const d = args.findIndex((a) => a === "-d");
		const dest = d >= 0 ? args[d + 1] : args.find((a) => /^-d./.test(a))?.slice(2);
		return (dest === undefined ? inHere : hit(dest)) ? "unzip into it" : null;
	}
	const scriptish = SCRIPT_RUNNER.test(name);
	const mentions = scriptish && (args.some((a) => WEPPY.test(a)) || rec.redirs.some((r) => WEPPY.test(r.body ?? "") || (r.op === "<<<" && WEPPY.test(r.target))));
	if (touching || mentions || (rec.piped && (scriptish || rec.mode === "ps"))) return `${name || "command"} is not a known read-only command`;
	return null;
}

function resolvePath(base, target) {
	if (/^[A-Za-z]:[\\/]|^\\\\/.test(target)) return target;
	if (target.startsWith("~")) return resolve(homedir(), target.replace(/^~[/\\]?/, "") || ".");
	return resolve(base, target);
}

// The directory after `cd target`; unknown (treated as inside weppy-project-sync) when the target
// comes from input or an unset variable in a line that names it.
const enter = (from, target) => ({ path: resolvePath(from.path, target.value), unknown: from.unknown || (weppyAnywhere && (target.tainted || target.unresolved)) });

// ---- one pass over the parsed commands -------------------------------------------------------------
let previous = { ...cwd };
let sawInterpreter = false;
const stack = [];
const inDir = (c) => c.unknown || WEPPY_DIR.test(c.path);

for (const rec of commands) {
	let argv = rec.argv.map((w) => expandWord(w));
	const assigns = rec.assigns.map(([n, v]) => [n, expandWord(v)]);
	// PowerShell assignment: $x = <expression>. Record it; the right-hand side still runs.
	if (rec.mode === "ps" && /^\$[A-Za-z_]\w*$/.test(rec.argv[0] ?? "") && rec.argv[1] === "=") {
		vars.set(rec.argv[0].slice(1), expandWord(rec.argv.slice(2).join(" ")));
		argv = argv.slice(2);
	}
	if (!rec.argv.length) for (const [n, v] of assigns) vars.set(n, v);
	const name = commandName(argv[0]?.value);
	const computed = Boolean(argv[0] && (argv[0].tainted || argv[0].unresolved));
	sawInterpreter ||= computed || INTERPRETER.test(name);
	const ex = argv.slice(1);
	const args = ex.map((e) => e.value);
	const here = rec.chdir === null ? cwd : enter(cwd, expandWord(rec.chdir)); // env -C dir, sudo -D dir
	const inHere = weppyAnywhere && inDir(here);

	// Redirections into weppy-project-sync, for every command (git included).
	if (weppyAnywhere) {
		for (const r of rec.redirs) {
			if (!(r.op.includes(">") || r.op === "<>") || (/&$/.test(r.op) && /^\d*-?$/.test(r.target))) continue;
			const t = expandWord(r.target);
			const relTarget = !isAbsolute(t.value) && !/^(~|[A-Za-z]:[\\/]|\/dev\/)/.test(t.value);
			if (WEPPY.test(t.value) || globHitsWeppy(t.value) || t.tainted || (inHere && relTarget)) weppyDeny(`redirect ${r.op} ${r.target}`);
		}
	}

	if (!argv.length) continue;

	// Shell state: variables and the working directory.
	if (["export", "declare", "typeset", "local", "readonly"].includes(name)) {
		for (const a of rec.argv.slice(1)) {
			const m = /^([A-Za-z_]\w*)=([\s\S]*)$/.exec(a);
			if (m) assign(m[1], m[2]);
		}
		continue;
	}
	if (name === "for" || name === "select") {
		const k = args.indexOf("in");
		if (args[0]) vars.set(args[0], k < 0 ? { value: "", tainted: true } : { value: args.slice(k + 1).join(" "), tainted: ex.slice(k + 1).some((e) => e.tainted) });
		continue;
	}
	if (name === "read" || name === "mapfile" || name === "readarray") {
		const names = positionals(args, ["-a", "-p", "-d", "-n", "-N", "-t", "-u", "-i", "-O", "-s", "-C", "-c"]);
		for (const n of names.length ? names : ["REPLY"]) vars.set(n, { value: "", tainted: true });
		const arr = args[args.indexOf("-a") + 1];
		if (args.includes("-a") && arr) vars.set(arr, { value: "", tainted: true });
		continue;
	}
	if (["cd", "pushd", "chdir", "set-location", "sl", "push-location"].includes(name)) {
		const t = ex.find((e) => !e.value.startsWith("-") || e.value === "-") ?? { value: "~", tainted: false, unresolved: false };
		const before = { ...cwd };
		cwd = t.value === "-" ? { ...previous } : enter(cwd, t);
		if (name === "pushd" || name === "push-location") stack.push(before);
		previous = before;
		continue;
	}
	if (name === "popd" || name === "pop-location") {
		previous = { ...cwd };
		cwd = stack.pop() ?? cwd;
		continue;
	}

	// Publishing tools, also behind runners (npx rojo upload) or a computed command name.
	if (PUBLISH_TOOLS.has(name)) checkPublishTool(name, args);
	if (RUNNERS.has(name)) {
		const k = args.findIndex((a) => !/\s/.test(a) && PUBLISH_TOOLS.has(commandName(a)));
		if (k >= 0) checkPublishTool(commandName(args[k]), args.slice(k + 1));
	}
	if (computed && args.some((a) => PUBLISH_VERBS.test(a))) deny(`the command name ${rec.argv[0]} is computed and is followed by a publish verb; spell out the tool`);
	if (computed && gitInvocation(args, here.path).sub === "push") checkPush(gitInvocation(args, here.path)); // $(which git) push

	// Web API writes.
	if (HTTP_CLIENTS[name]) checkHttp(name, args, rec);
	if (computed) {
		const req = merge(curlRequest(args), wgetRequest(args), psRequest(args, 2));
		if (req.writes && (req.unknown || req.urls.some((u) => ROBLOX_HOST.test(hostOf(u)) || /[$`]/.test(hostOf(u))))) deny(`the command name ${rec.argv[0]} is computed and sends a write request; spell out the HTTP client`);
	}

	// git: force pushes anywhere, writes into weppy-project-sync.
	if (name === "git") {
		const inv = gitInvocation(args, here.path);
		if (inv.sub === "push") checkPush(inv);
		if (weppyAnywhere && inv.sub) {
			const env = Object.fromEntries([...vars, ...assigns]);
			const gitEnv = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR"].map((k) => env[k]).filter(Boolean);
			const touches =
				inHere ||
				WEPPY_DIR.test(inv.dir) ||
				[inv.gitDir, inv.workTree].some((p) => p !== null && (pathy(p) || /[$`]/.test(p))) ||
				gitEnv.some((e) => pathy(e.value) || e.tainted) ||
				gitPathArgs(inv.rest).some((a) => pathy(a));
			if (touches && !gitReadOnly(inv.sub, inv.rest)) weppyDeny(`git ${inv.sub}`);
			const output = inv.rest.flatMap((a, i) => (a === "--output" ? [inv.rest[i + 1] ?? ""] : a.startsWith("--output=") ? [a.slice(9)] : []));
			if (output.some((o) => pathy(o) || (touches && !isAbsolute(o)))) weppyDeny(`git ${inv.sub} --output`);
		}
		continue;
	}

	if (weppyAnywhere) {
		const why = weppyVerdict(name, ex, { ...rec, nameTainted: argv[0].tainted }, inHere);
		if (why) weppyDeny(why);
	}
}

// Inline scripts that send writes to a Roblox web API.
if (sawInterpreter && (ROBLOX_HOST.test(allText) || ROBLOX_ENV.test(allText)) && SCRIPT_WRITE.test(allText)) deny("inline script sends a write request to a Roblox web API");
process.exit(0);
