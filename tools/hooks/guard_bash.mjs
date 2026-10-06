// PreToolUse guard for Bash (Claude Code, and Codex through .codex/hooks.json). Every rule denies;
// there is no ask path. Denied:
//  - publishing and uploads: rojo upload (global flags and rojo.exe included), mantle deploy/destroy,
//    tarmac sync --target roblox / upload-image (global --auth/--api-key included), asphalt upload and
//    sync (except --dry-run or --target studio/debug), and every rbxcloud subcommand except
//    get*/list*/help; also through runners (npx, pnpm, yarn, bunx, rokit, uv run, uvx, pipx, ...),
//    wrappers (env, sudo, setsid, flock, nohup, timeout, script -c, cmd start, Start-Process), a
//    command name held in a variable, inline interpreter code (python -c "os.system('rojo upload')"),
//    and git -c settings. A subcommand this guard cannot see ($(...), xargs/parallel input) is denied;
//  - write requests to Roblox web APIs (*.roblox.com, apis.roblox.com Open Cloud included): curl with
//    -X/--request other than GET/HEAD/OPTIONS or any body (-d/--data*, -F/--form*, --json,
//    -T/--upload-file, -K/--config), wget --post-*/--body-*/--method, httpie/xh with a write method,
//    data items or a stdin body (also python -m httpie, uvx --from httpie http), Invoke-RestMethod /
//    Invoke-WebRequest with -Method Post|Put|Patch|Delete, -Body, -InFile or -Form or splatted
//    parameters, and inline scripts (python/node/ruby/perl/php/pwsh/...) that send a body or a
//    POST/PUT/PATCH/DELETE or run an HTTP client with a write flag. Long options resolve by unique
//    prefix the way each tool does (curl --upload, --js, --conf; wget --post-f, --meth; -Met/-Bod/-InF
//    in PowerShell); an option this guard does not know counts as a possible write. This covers asset
//    uploads, place publishing, DataStore/OrderedDataStore/MessagingService writes, game passes and
//    developer products. A write whose URL is not visible (an unset variable, a curl config file,
//    xargs input) is treated as a Roblox write. Plain GET reads and writes to other literal hosts pass;
//  - force pushes (--force, -f, --force-with-lease, +refspec, --mirror, any unique prefix such as
//    --force-w or --mirr) and deletions (--delete, :branch, --prune) whose destination is a protected
//    branch (main, master), including the matching refspec ':' / '+:' when forced, and pushes made
//    mirror or matching by git -c / GIT_CONFIG_* / repo config (remote.*.mirror, remote.*.push,
//    push.default). Force pushes to other branches, such as an agent's own claude/* work branch, are
//    allowed. $(git branch --show-current) and HEAD resolve to the current branch; any other refspec
//    from a variable or $(...) is denied when forced. A forced push with no refspec is resolved
//    against the current branch and its upstream, and denied when that cannot be resolved;
//  - anything that may write into weppy-project-sync/. When a command line names that directory (or
//    runs inside it), each command that names it, runs in it, takes paths from input or reads a pipe
//    must be a known read-only command (cat, ls, rg, grep, head, diff, jq, find without -delete,
//    sed/awk/sort without in-place, output or write options in any spelling, ...), a copy whose
//    destination is elsewhere (cp/install -t inside a flag cluster counts), or a read-only git
//    subcommand without -c settings (status, log, diff, show, ...; git -C, --git-dir, --work-tree,
//    GIT_DIR and GIT_WORK_TREE all count). Everything else is denied: redirections into it,
//    rm/mv/tee/touch, patch, git apply/am, curl -o, wget -O, tar -C or old-style tar xCf, unzip -d,
//    interpreters, build tools, git writes. Variables assigned in the same command line (D=...,
//    export, for, read, $1, PowerShell $x = ...) are followed; a value from input counts as naming it.
// Command lines are parsed into simple commands (tools/hooks/shell.mjs) so argument order, quoting
// and nesting (bash -c, eval, $(...), heredocs and echo piped into a shell, powershell -Command) do
// not matter. Commands over 64 KiB are denied (a hook that times out lets the command run).
// Residual risk: scripts in files, aliases stored in git or shell config, code that builds tool names
// or URLs at run time, and paths or URLs produced by programs. Hooks never publish anything.
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { isAbsolute, resolve } from "node:path";
import { CODE_HTTP_CLI_WRITE, CODE_PUBLISH, ROBLOX_HOST, SCRIPT_WRITE, decide, readEvent } from "./lib.mjs";
import { commandName, parseCommands } from "./shell.mjs";

// Fail closed: a bug in this guard must block the command, not wave it through.
process.on("uncaughtException", (err) => decide("deny", `guard_bash.mjs failed (${err.message}); fix the hook (node tools/hooks/selftest.mjs) before retrying.`));

const event = readEvent();
const text = String(event.tool_input?.command || "");
// Above this size parsing could run past the hook timeout, and a timed-out hook lets the command run.
const MAX_COMMAND = 64 * 1024;
if (text.length > MAX_COMMAND) decide("deny", `Blocked by factory guard: the command is ${text.length} characters, more than the ${MAX_COMMAND} this guard checks in time. Split it into smaller commands.`);
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

// getopt_long (curl, wget, git, GNU tools, Python argparse) accepts any unique prefix of a long
// option (--upload for --upload-file). The names an option can stand for: the exact name, else every
// option it prefixes. More than one is ambiguous, which the tool rejects; callers treat it as any of them.
function longNames(option, names) {
	const n = option.replace(/^--/, "");
	if (names.includes(n)) return [n];
	return n ? names.filter((o) => o.startsWith(n)) : [];
}

// ---- publish / upload tools ----------------------------------------------------------------------
const PUBLISH_TOOLS = new Set(["rojo", "mantle", "tarmac", "rbxcloud", "asphalt"]);
// Options that take a separate value, so the value is not read as the subcommand (tarmac --auth X sync).
const TOOL_VALUE_OPTS = { rojo: ["--color", "--colour"], mantle: [], tarmac: ["--auth", "--api-key", "--target", "--retry", "--retry-delay"], asphalt: ["--api-key", "--target", "--type", "--creator-type", "--creator-id"], rbxcloud: [] };
// Subcommands that never publish. Under xargs/parallel/find -exec, where more arguments come from
// input, any other subcommand is denied.
const SAFE_SUBCOMMANDS = { rojo: ["init", "serve", "build", "sourcemap", "fmt-project", "plugin", "doc", "help"], mantle: ["outputs", "import", "download", "help"], tarmac: ["create-cache-map", "asset-list", "help"], asphalt: ["migrate-lockfile", "help"], rbxcloud: [] };
const RUNNERS = new Set(["npx", "bunx", "pnpx", "pnpm", "yarn", "npm", "rokit", "aftman", "foreman", "mise", "asdf", "proto", "cargo", "dotnet", "uv", "uvx", "pipx", "poetry", "pdm", "hatch", "rye", "pixi", "conda", "mamba", "micromamba"]);
const PUBLISH_VERBS = /^(upload|upload-image|deploy|destroy|publish|sync)$/i;

function checkPublishTool(tool, args, viaXargs = false) {
	const pos = positionals(args, TOOL_VALUE_OPTS[tool]).map((p) => p.toLowerCase());
	const hidden = (s) => (s === undefined ? viaXargs : /[$`]/.test(s));
	const valueOf = (opt) => {
		const k = args.findIndex((a) => a === opt || a.startsWith(`${opt}=`));
		return k < 0 ? undefined : args[k].startsWith(`${opt}=`) ? args[k].slice(opt.length + 1) : (args[k + 1] ?? "");
	};
	const sub = pos[0];
	if (hidden(sub)) deny(`${tool} with a subcommand this guard cannot see (a variable, $(...) or xargs input); spell the subcommand out`);
	if (viaXargs && tool !== "rbxcloud" && !SAFE_SUBCOMMANDS[tool].includes(sub)) deny(`${tool} ${sub} under xargs/parallel/find -exec takes more arguments from input, which this guard cannot see`);
	if (tool === "rojo" && sub === "upload") deny("rojo upload publishes a place");
	if (tool === "mantle" && ["deploy", "destroy"].includes(sub)) deny(`mantle ${sub} changes a live experience`);
	if (tool === "tarmac") {
		const target = valueOf("--target");
		if (sub === "upload-image" || (sub === "sync" && (/roblox/i.test(target ?? "") || /[$`]/.test(target ?? "")))) deny("tarmac uploads assets to Roblox");
	}
	if (tool === "asphalt") {
		const target = valueOf("--target");
		const local = args.includes("--dry-run") || /^(studio|debug)$/i.test(target ?? "");
		if (sub === "upload" || (sub === "sync" && !local)) deny(`asphalt ${sub} uploads assets to Roblox (only sync --dry-run or --target studio/debug is allowed)`);
	}
	if (tool === "rbxcloud") {
		const [group, verb] = pos;
		if (group !== undefined && group !== "help" && hidden(verb)) deny(`rbxcloud ${group} with a subcommand this guard cannot see (a variable, $(...) or xargs input)`);
		const read = group === undefined || group === "help" || verb === undefined || verb === "help" || /^(get|list)(-|$)/.test(verb);
		if (!read) deny(`rbxcloud ${group} ${verb} writes to Roblox (only get*/list*/help subcommands are allowed)`);
	}
}

// ---- write requests to Roblox web APIs -----------------------------------------------------------
const READ_METHOD = /^(GET|HEAD|OPTIONS)$/i;

const CURL_SHORT_VALUE = new Set("AbcCDdeEFHKmoPQrtTuUwxXyYz".split(""));
// curl 8.5 `curl --help all`, plus options of later releases.
const CURL_VALUE = (
	"abstract-unix-socket alt-svc aws-sigv4 cacert capath cert cert-type ciphers config connect-timeout connect-to " +
	"continue-at cookie cookie-jar create-file-mode crlfile curves data data-ascii data-binary data-raw data-urlencode delegation " +
	"dns-interface dns-ipv4-addr dns-ipv6-addr dns-servers doh-url dump-header ech egd-file engine etag-compare etag-save " +
	"expect100-timeout form form-string ftp-account ftp-alternative-to-user ftp-method ftp-port ftp-ssl-ccc-mode " +
	"happy-eyeballs-timeout-ms haproxy-clientip header hostpubmd5 hostpubsha256 hsts interface ip-tos ipfs-gateway json keepalive-time " +
	"key key-type knownhosts krb libcurl limit-rate local-port login-options mail-auth mail-from mail-rcpt max-filesize max-redirs " +
	"max-time netrc-file noproxy oauth2-bearer output output-dir parallel-max pass pinnedpubkey preproxy proto proto-default proto-redir " +
	"proxy proxy-cacert proxy-capath proxy-cert proxy-cert-type proxy-ciphers proxy-crlfile proxy-header proxy-key proxy-key-type " +
	"proxy-pass proxy-pinnedpubkey proxy-service-name proxy-tls13-ciphers proxy-tlsauthtype proxy-tlspassword " +
	"proxy-tlsuser proxy-user proxy1.0 pubkey quote random-file range rate referer request request-target resolve retry " +
	"retry-delay retry-max-time sasl-authzid service-name sigalgs socks4 socks4a socks5 socks5-gssapi-service socks5-hostname " +
	"speed-limit speed-time ssl-sessions stderr telnet-option tftp-blksize time-cond tls-max tls13-ciphers tlsauthtype tlspassword " +
	"tlsuser trace trace-ascii trace-config unix-socket upload-file upload-flags url url-query user user-agent variable vlan-priority write-out"
).split(" ");
const CURL_FLAG = (
	"anyauth append basic ca-native cert-status compressed compressed-ssh create-dirs crlf digest disable disable-eprt disable-epsv " +
	"disallow-username-in-url doh-cert-status doh-insecure fail fail-early fail-with-body false-start follow form-escape ftp-create-dirs " +
	"ftp-pasv ftp-pret ftp-skip-pasv-ip ftp-ssl-ccc ftp-ssl-control get globoff haproxy-protocol head help http0.9 http1.0 http1.1 http2 " +
	"http2-prior-knowledge http3 http3-only ignore-content-length include insecure ipv4 ipv6 junk-session-cookies list-only location " +
	"location-trusted mail-rcpt-allowfails manual metalink mptcp negotiate netrc netrc-optional next no-alpn no-buffer no-clobber " +
	"no-keepalive no-npn no-progress-meter no-sessionid ntlm ntlm-wb out-null parallel parallel-immediate path-as-is post301 post302 " +
	"post303 progress-bar proxy-anyauth proxy-basic proxy-ca-native proxy-digest proxy-http2 proxy-insecure proxy-negotiate proxy-ntlm " +
	"proxy-ssl-allow-beast proxy-ssl-auto-client-cert proxy-tlsv1 proxytunnel raw remote-header-name remote-name remote-name-all " +
	"remote-time remove-on-error retry-all-errors retry-connrefused sasl-ir show-error silent skip-existing socks5-basic socks5-gssapi " +
	"socks5-gssapi-nec ssl ssl-allow-beast ssl-auto-client-cert ssl-no-revoke ssl-reqd ssl-revoke-best-effort sslv2 sslv3 " +
	"styled-output suppress-connect-headers tcp-fastopen tcp-nodelay tftp-no-options tls-earlydata tlsv1 tlsv1.0 tlsv1.1 tlsv1.2 " +
	"tlsv1.3 tr-encoding trace-ids trace-time use-ascii verbose version xattr"
).split(" ");
const CURL_LONG = [...CURL_VALUE, ...CURL_FLAG];
const CURL_WRITE_OPTION = /^(request|data(-\w+)?|json|form(-string)?|upload-file|config)$/;

function curlRequest(args) {
	const r = { writes: false, urls: [], unknown: false };
	let method = null;
	let body = false;
	let get = false;
	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		if (a === "--") continue;
		if (a.startsWith("--")) {
			const [raw, attached] = splitEq(a);
			// --expand-<option> (curl 8.3+) fills {{variables}} into the value; --no-<flag> negates a flag.
			const expand = raw.startsWith("--expand-");
			const option = expand ? `--${raw.slice(9)}` : raw;
			const names = longNames(option, CURL_LONG);
			if (!names.length && option.startsWith("--no-") && longNames(option.slice(5), CURL_FLAG).length) continue;
			if (!names.length) {
				r.writes = true; // an option this guard does not know: assume it may write (only Roblox or hidden URLs are denied)
				continue;
			}
			const v = attached ?? (names.length === 1 && CURL_VALUE.includes(names[0]) ? (args[++i] ?? "") : undefined);
			if (expand && /\{\{/.test(v ?? "")) r.unknown = true;
			if (names.length > 1) {
				if (names.some((x) => CURL_WRITE_OPTION.test(x))) r.writes = true; // ambiguous: curl refuses it, but judge it as the write
				continue;
			}
			const n = names[0];
			if (n === "request") method = v;
			else if (/^data(-[a-z]+)?$/.test(n)) body = true;
			else if (["json", "form", "form-string", "upload-file"].includes(n)) r.writes = true;
			else if (n === "get") get = true;
			else if (n === "url") r.urls.push(v);
			else if (n === "config") r.writes = r.unknown = true;
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
// wget 1.21 `wget --help`.
const WGET_VALUE = (
	"output-file append-output execute input-file base config tries output-document timeout dns-timeout connect-timeout " +
	"read-timeout wait waitretry quota bind-address limit-rate user password header user-agent referer post-data post-file " +
	"body-data body-file method load-cookies save-cookies directory-prefix cut-dirs default-page level accept reject domains " +
	"exclude-domains include-directories exclude-directories ca-certificate ca-directory certificate private-key " +
	"certificate-type private-key-type secure-protocol http-user http-password proxy-user proxy-password " +
	"restrict-file-names progress rejected-log warc-file local-encoding remote-encoding max-redirect retry-on-http-error " +
	"accept-regex reject-regex regex-type backups ciphers compression crl-file follow-tags ignore-tags ftp-user ftp-password " +
	"pinnedpubkey prefer-family random-file report-speed start-pos use-askpass hsts-file warc-dedup warc-header warc-max-size warc-tempdir"
).split(" ");
const WGET_FLAG = (
	"adjust-extension ask-password auth-no-challenge background backup-converted content-disposition content-on-error continue " +
	"convert-file-only convert-links debug delete-after follow-ftp force-directories force-html ftps-clear-data-connection " +
	"ftps-fallback-to-ftp ftps-implicit ftps-resume-ssl help https-only ignore-case ignore-length inet4-only inet6-only " +
	"keep-session-cookies mirror no-cache no-check-certificate no-clobber no-config no-cookies no-directories no-dns-cache no-glob " +
	"no-host-directories no-hsts no-http-keep-alive no-if-modified-since no-iri no-netrc no-parent no-passive-ftp no-proxy " +
	"no-remove-listing no-use-server-timestamps no-verbose no-warc-compression no-warc-digests no-warc-keep-log page-requisites " +
	"preserve-permissions protocol-directories quiet random-wait recursive relative retr-symlinks retry-connrefused retry-on-host-error " +
	"save-headers server-response show-progress span-hosts spider strict-comments timestamping trust-server-names unlink verbose version warc-cdx xattr"
).split(" ");
const WGET_LONG = [...WGET_VALUE, ...WGET_FLAG];
const WGET_WRITE_OPTION = /^(post-data|post-file|body-data|body-file|method|execute|input-file|config)$/;

function wgetRequest(args) {
	const r = { writes: false, urls: [], unknown: false };
	let method = null;
	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		let n;
		let v;
		if (a === "--") continue;
		if (a.startsWith("--")) {
			const [raw, attached] = splitEq(a);
			const names = longNames(raw, WGET_LONG);
			if (!names.length && raw.startsWith("--no-") && longNames(raw.slice(5), WGET_FLAG).length) continue;
			if (names.length !== 1) {
				// unknown: assume it may write; ambiguous: wget refuses it, but judge it as the write
				if (!names.length || names.some((x) => WGET_WRITE_OPTION.test(x))) r.writes = true;
				continue;
			}
			n = `--${names[0]}`;
			v = attached ?? (WGET_VALUE.includes(names[0]) ? (args[++i] ?? "") : undefined);
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

// httpie 3 (argparse, so unique prefixes work) and xh.
const HTTPIE_VALUE = (
	"auth auth-type bearer session session-read-only output verify cert cert-key cert-key-pass proxy print history-print pretty style " +
	"timeout max-redirects max-headers boundary default-scheme format-options raw ssl ciphers response-charset response-mime " +
	"http-version resolve interface unix-socket"
).split(" ");
const HTTPIE_FLAG = (
	"json form multipart compress unsorted sorted headers meta body verbose all stream download continue quiet ignore-netrc offline " +
	"follow check-status path-as-is chunked ignore-stdin help manual version traceback debug native-tls https curl curl-long"
).split(" ");
const HTTPIE_LONG = [...HTTPIE_VALUE, ...HTTPIE_FLAG];
const dataItem = (item) => {
	const m = /==|:=@|:=|=@|@|=|:/.exec(item);
	return m !== null && m[0] !== "==" && m[0] !== ":";
};

function httpieRequest(args, rec) {
	const pos = [];
	let raw = false;
	let ignoreStdin = false;
	let unknownOption = false;
	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		if (a === "--") {
			pos.push(...args.slice(i + 1));
			break;
		}
		if (a.startsWith("--")) {
			const [n, v] = splitEq(a);
			const names = longNames(n, HTTPIE_LONG);
			if (names.length !== 1) unknownOption = true;
			else {
				raw ||= names[0] === "raw";
				ignoreStdin ||= names[0] === "ignore-stdin";
				if (v === undefined && HTTPIE_VALUE.includes(names[0])) i++;
			}
			continue;
		}
		if (/^-[A-Za-z]/.test(a)) {
			for (let k = 1; k < a.length; k++) {
				ignoreStdin ||= a[k] === "I";
				if ("aAopPs".includes(a[k])) {
					if (k === a.length - 1) i++;
					break;
				}
			}
			continue;
		}
		pos.push(a);
	}
	let method = null;
	let k = 0;
	if (pos.length > 1 && /^[a-z]+$/i.test(pos[0])) method = pos[k++];
	const r = { writes: false, urls: pos.slice(k, k + 1), unknown: false };
	const stdinBody = (rec.piped || rec.redirs.some((x) => x.op === "<" || x.op.startsWith("<<"))) && !ignoreStdin;
	if (raw) r.writes = true;
	else if (method) r.writes = !READ_METHOD.test(method);
	else r.writes = stdinBody || pos.slice(k + 1).some(dataItem);
	// An option this guard does not know may have taken the next word as its value: judge every word.
	if (unknownOption) {
		r.urls = pos;
		r.writes ||= pos.some((p) => /^(post|put|patch|delete)$/i.test(p) || dataItem(p));
	}
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
	httpie: httpieRequest, // python -m httpie, pipx run httpie
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

// Each lookup starts git; a line with very many pushes could otherwise outlast the hook timeout.
let gitCalls = 0;
function git(inv, args) {
	if (++gitCalls > 32) deny("too many git pushes in one command line for this guard to resolve in time; split it");
	const pre = ["-C", inv.dir, ...(inv.gitDir ? [`--git-dir=${resolve(inv.dir, inv.gitDir)}`] : [])];
	const r = spawnSync("git", [...pre, ...args], { encoding: "utf8", timeout: 2000 });
	return r.status === 0 ? r.stdout.trim() : null;
}

// git -c / --config-env settings and GIT_CONFIG_* variables that change what a push does.
const FALSE = /^(false|no|off|0)$/i;

// A push without refspecs: a mirror remote overwrites everything; configured remote.<name>.push
// refspecs apply; otherwise push.default decides (matching pushes every branch, main included;
// simple/current/upstream push the current branch to itself or its upstream).
function checkImplicitPush(inv, remote, force, why) {
	const own = (key) => inv.configs.filter(([k]) => k.toLowerCase() === key.toLowerCase()).map(([, v]) => v ?? "true");
	const listed = git(inv, ["config", "--get-regexp", `^(remote\\.${remote.replace(/[^\w-]/g, ".")}\\.(mirror|push)|push\\.default)$`]);
	const stored = (key) =>
		(listed ?? "")
			.split("\n")
			.filter((l) => l.toLowerCase().startsWith(`${key.toLowerCase()} `))
			.map((l) => l.slice(key.length + 1));
	const cfg = (key) => (own(key).length ? own(key) : stored(key));
	if (cfg(`remote.${remote}.mirror`).some((v) => !FALSE.test(v.trim()))) deny(`${why} (remote.${remote}.mirror makes this a mirror push that overwrites every branch)`);
	const specs = cfg(`remote.${remote}.push`);
	if (specs.length) {
		for (const s of specs) {
			const dst = s.replace(/^\+/, "").split(":").pop();
			if ((force || s.startsWith("+")) && (isProtected(dst) || /[$`]/.test(s))) deny(`${why} (remote.${remote}.push is ${s})`);
		}
		return;
	}
	if (!force) return;
	const mode = cfg("push.default").pop() ?? "simple";
	if (!/^(simple|current|upstream|tracking|nothing)$/i.test(mode.trim())) deny(`${why} (push.default=${mode} pushes every matching branch, main/master included)`);
	const dests = defaultDestinations(inv);
	if (dests === null) deny(`${why}; the destination of a forced push without a refspec could not be resolved, so name the branch explicitly`);
	if (dests.some(isProtected)) deny(why);
}

// Where a bare `git push` goes: the current branch (push.default simple/current) and its upstream.
function defaultDestinations(inv) {
	const branch = git(inv, ["symbolic-ref", "--short", "-q", "HEAD"]);
	if (!branch) return null;
	const merge = git(inv, ["config", "--get", `branch.${branch}.merge`]);
	return [branch, merge].filter(Boolean);
}

// git's global options before the subcommand. configs: -c key=value and --config-env key=ENV
// (whose value this guard cannot see), plus GIT_CONFIG_PARAMETERS / GIT_CONFIG_COUNT variables.
function gitInvocation(args, dir, env = {}) {
	let gitDir = null;
	let workTree = null;
	const configs = [];
	const pair = (s) => {
		const k = s.indexOf("=");
		return k < 0 ? [s, undefined] : [s.slice(0, k), s.slice(k + 1)];
	};
	const value = (e) => (e === undefined ? undefined : e.tainted || e.unresolved ? "$unresolved" : e.value);
	if (env.GIT_CONFIG_PARAMETERS) {
		for (const m of String(value(env.GIT_CONFIG_PARAMETERS)).matchAll(/'([^']*)'(?:='([^']*)')?/g)) configs.push(m[2] === undefined ? pair(m[1]) : [m[1], m[2]]);
		if (!configs.length) configs.push(["$unresolved", "$unresolved"]);
	}
	if (env.GIT_CONFIG_COUNT) {
		const count = Number(value(env.GIT_CONFIG_COUNT));
		for (let k = 0; k < (Number.isFinite(count) ? Math.min(count, 64) : 64); k++) if (env[`GIT_CONFIG_KEY_${k}`]) configs.push([value(env[`GIT_CONFIG_KEY_${k}`]), value(env[`GIT_CONFIG_VALUE_${k}`]) ?? ""]);
	}
	let i = 0;
	for (; i < args.length; i++) {
		const a = args[i];
		const [n, v] = splitEq(a);
		if (a === "-C") dir = resolvePath(dir, args[++i] ?? ".");
		else if (n === "--git-dir") gitDir = v ?? args[++i] ?? "";
		else if (n === "--work-tree") workTree = v ?? args[++i] ?? "";
		else if (a === "-c") configs.push(pair(args[++i] ?? ""));
		else if (n === "--config-env") configs.push([pair(v ?? args[++i] ?? "")[0], "$unresolved"]);
		else if (["--namespace", "--super-prefix", "--list-cmds"].includes(a)) i++;
		else if (!a.startsWith("-")) break;
	}
	return { dir, gitDir, workTree, configs, sub: args[i], rest: args.slice(i + 1) };
}

// git push long options (git 2.4x), for unique-prefix resolution (--force-w, --mirr, --dele).
const PUSH_LONG = (
	"all branches mirror tags follow-tags no-follow-tags atomic no-atomic dry-run porcelain delete force no-force force-with-lease " +
	"no-force-with-lease force-if-includes no-force-if-includes repo receive-pack exec push-option no-push-option signed no-signed " +
	"set-upstream thin no-thin quiet verbose progress no-progress recurse-submodules no-recurse-submodules verify no-verify ipv4 ipv6 prune no-prune"
).split(" ");
const PUSH_VALUE = ["repo", "receive-pack", "exec", "push-option", "recurse-submodules"];
// Idioms for "the current branch", resolved to it rather than treated as unknown.
const CURRENT_IDIOM = String.raw`git\s+(?:branch\s+--show-current|rev-parse\s+--abbrev-ref\s+(?:HEAD|@)|symbolic-ref\s+(?:(?:--short|-q|--quiet)\s+)*HEAD)`;
const CURRENT_BRANCH = new RegExp(String.raw`\$\(\s*${CURRENT_IDIOM}\s*\)|\x60\s*${CURRENT_IDIOM}\s*\x60`, "g");
let pushConfigChanged = false; // an earlier command in this line rewrote remote.*.mirror/push or push.default

function checkPush(inv) {
	const why = "force-push or deletion of a protected branch (main/master); force pushes are allowed only to other branches";
	for (const [k, v] of inv.configs) {
		if (/[$`]/.test(k)) deny(`${why}; git -c/--config-env/GIT_CONFIG_* settings this guard cannot see`);
		if (/^remote\..+\.mirror$/i.test(k) && !FALSE.test(String(v ?? "true").trim())) deny(`${why} (-c ${k} makes this a mirror push that overwrites every branch)`);
		if (/^remote\..+\.push$/i.test(k) && (/[$`+]/.test(v ?? "") || isProtected(String(v ?? "").split(":").pop()))) deny(`${why} (-c ${k}=${v})`);
		if (/^push\.default$/i.test(k) && !/^(simple|current|upstream|tracking|nothing)$/i.test(String(v ?? "").trim())) deny(`${why} (-c push.default=${v} can push every matching branch, main/master included)`);
	}
	if (pushConfigChanged) deny(`${why}; an earlier command in this line changes the push configuration (remote mirror/push or push.default), so run it separately`);
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
			const names = longNames(n, PUSH_LONG);
			if (names.includes("mirror")) deny("git push --mirror overwrites every remote branch, including main/master");
			if (names.includes("force") || names.includes("force-with-lease")) {
				force = true;
				if (v && names.includes("force-with-lease")) lease.push(v.split(":")[0]);
			}
			if (names.includes("delete") || names.includes("prune")) del = true; // --prune deletes remote branches that have no local one
			if (names.includes("all") || names.includes("branches")) all = true;
			if (names.length === 1 && PUSH_VALUE.includes(names[0]) && v === undefined) i++;
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
	if (force && lease.some(isProtected)) deny(why);
	const refspecs = pos.slice(1);
	let current;
	const currentBranch = () => (current ??= git(inv, ["symbolic-ref", "--short", "-q", "HEAD"]));
	for (const raw of refspecs) {
		const spec = raw.replace(CURRENT_BRANCH, () => currentBranch() ?? "$unresolved");
		const plus = spec.startsWith("+");
		const body = plus ? spec.slice(1) : spec;
		if (body === ":") {
			// the matching refspec: every branch that exists on both sides, main/master included
			if (force || plus) deny(`${why} (':' pushes every matching branch)`);
			continue;
		}
		if (/[$`]/.test(body)) {
			if (force || plus || del) deny(`${why}; the refspec ${raw} comes from a variable or $(...) this guard cannot resolve, so name the branch`);
			continue;
		}
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
	if (!refspecs.length) {
		if (force && all) deny(`${why} (--all includes them)`);
		const remote = pos[0] ?? "origin";
		if (/[$`]/.test(remote) && force) deny(`${why}; the remote ${remote} comes from a variable or $(...) this guard cannot resolve`);
		checkImplicitPush(inv, remote, force, why);
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
		"write-output write-host split-path join-path get-location gl findstr fc where clip pbcopy wl-copy"
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

// git arguments that can name paths. Messages are text, not paths: -m/-F also inside a flag cluster
// (git commit -am "..."), attached (-m"..."), or as a --message/--file prefix, for the subcommands
// that take a message.
const MESSAGE_SUBCOMMANDS = new Set(["commit", "tag", "merge", "notes", "stash", "revert", "cherry-pick"]);
function gitPathArgs(sub, rest) {
	const message = MESSAGE_SUBCOMMANDS.has(sub);
	const out = [];
	for (let i = 0; i < rest.length; i++) {
		const a = rest[i];
		if (message && /^-[a-zA-Z]*[mF]/.test(a) && !a.startsWith("--")) {
			if (/^-[a-zA-Z]*[mF]$/.test(a)) i++; // the message is the next word; otherwise it is attached
			continue;
		}
		const [n, v] = splitEq(a);
		if (message && n.length >= 4 && ("--message".startsWith(n) || "--file".startsWith(n))) {
			if (v === undefined) i++;
			continue;
		}
		out.push(a);
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
	// cp/install -t DIR also inside a flag cluster (cp -rt DIR, install -Dt DIR) and --target-directory
	// by any unique prefix (--t DIR); other value options are skipped so their value is not the destination.
	const shortValue = COPY_SHORT_VALUE[name] ?? "";
	const longValue = COPY_LONG_VALUE[name] ?? [];
	const pos = [];
	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		if (a === "--") {
			pos.push(...args.slice(i + 1));
			break;
		}
		if (a.startsWith("--")) {
			const [n, v] = splitEq(a);
			const names = longNames(n, [...longValue, "target-directory", "no-target-directory"]);
			if (["cp", "install"].includes(name) && names.includes("target-directory")) return v ?? args[i + 1] ?? "";
			if (names.length === 1 && longValue.includes(names[0]) && v === undefined) i++;
			continue;
		}
		if (a.startsWith("-") && a.length > 1) {
			for (let k = 1; k < a.length; k++) {
				if (!shortValue.includes(a[k])) continue;
				const v = k < a.length - 1 ? a.slice(k + 1) : (args[++i] ?? "");
				if (a[k] === "t" && name !== "rsync" && name !== "scp") return v;
				break;
			}
			continue;
		}
		pos.push(a);
	}
	return pos.length > 1 ? pos[pos.length - 1] : null;
}
// Short options that take a value (cp -S SUFFIX, install -m MODE, rsync -e CMD, scp -P PORT) and long
// ones that take a separate value.
const COPY_SHORT_VALUE = { cp: "St", install: "gmoSt", rsync: "eBfMT", scp: "cDFiJlmoPSX" };
const COPY_LONG_VALUE = {
	cp: ["suffix", "no-preserve", "sparse"],
	install: ["suffix", "mode", "owner", "group", "strip-program"],
	rsync: ["rsh", "filter", "exclude", "include", "exclude-from", "include-from", "files-from", "temp-dir", "backup-dir", "partial-dir", "log-file", "compare-dest", "copy-dest", "link-dest", "suffix", "chmod", "chown", "rsync-path", "password-file", "port", "timeout", "max-size", "min-size", "bwlimit"],
	scp: [],
};

// GNU tar: short letters that take a value, and long options (unique prefixes resolve, --dir for
// --directory). Old style (tar xCf DIR ARCHIVE) gives each value letter the next word, in order.
const TAR_VALUE = "bCfFgHIKLNTVX";
const TAR_LONG_VALUE = (
	"directory file to-command use-compress-program checkpoint-action info-script new-volume-script rsh-command listed-incremental " +
	"index-file volno-file exclude exclude-from files-from transform xform strip-components owner group mode mtime newer after-date " +
	"newer-mtime label blocking-factor format suffix warning record-size tape-length starting-file level sort quoting-style " +
	"hole-detection exclude-tag exclude-tag-all exclude-tag-under add-file atime-preserve"
).split(" ");
const TAR_LONG_FLAG = (
	"extract get create append update delete concatenate catenate list diff compare test-label remove-files to-stdout keep-old-files " +
	"overwrite skip-old-files unlink-first recursive-unlink dereference delay-directory-restore gzip gunzip ungzip bzip2 xz zstd lzip " +
	"lzma lzop compress uncompress auto-compress verbose one-file-system absolute-names preserve-permissions same-permissions " +
	"same-owner no-same-owner numeric-owner wildcards anchored null totals checkpoint sparse ignore-zeros ignore-failed-read " +
	"incremental verify multi-volume backup interactive confirmation xattrs acls selinux show-transformed-names utc help version"
).split(" ");
const TAR_LONG = [...TAR_LONG_VALUE, ...TAR_LONG_FLAG];

function tarVerdict(args, hit, inHere) {
	let letters = "";
	let file = null;
	const dirs = [];
	const written = []; // snapshot (-g) and index files tar writes
	let exec = false;
	let removes = false;
	const take = (ch, value) => {
		if (ch === "f") file = value;
		else if (ch === "C") dirs.push(value);
		else if (ch === "g") written.push(value);
		else if (ch === "I" || ch === "F") exec = true;
	};
	let i = 0;
	if (args[0] && !args[0].startsWith("-")) {
		let next = 1;
		for (const ch of args[0]) {
			if (TAR_VALUE.includes(ch)) take(ch, args[next++] ?? "");
			else letters += ch;
		}
		i = next;
	}
	for (; i < args.length; i++) {
		const a = args[i];
		if (a === "--") break;
		if (a.startsWith("--")) {
			const [n, v] = splitEq(a);
			const names = longNames(n, TAR_LONG);
			const has = (re) => names.some((x) => re.test(x));
			if (has(/^(to-command|use-compress-program|checkpoint-action|info-script|new-volume-script|rsh-command)$/)) exec = true;
			if (has(/^(extract|get)$/)) letters += "x";
			if (has(/^(create|append|update|delete|concatenate|catenate)$/)) letters += "c";
			if (has(/^to-stdout$/)) letters += "O";
			removes ||= has(/^remove-files$/);
			if (names.length !== 1) continue;
			const value = v ?? (TAR_LONG_VALUE.includes(names[0]) ? (args[++i] ?? "") : undefined);
			if (names[0] === "directory") dirs.push(value);
			else if (names[0] === "file") file = value;
			else if (/^(listed-incremental|index-file|volno-file)$/.test(names[0])) written.push(value);
			continue;
		}
		if (/^-[A-Za-z]/.test(a)) {
			for (let k = 1; k < a.length; k++) {
				if (TAR_VALUE.includes(a[k])) {
					take(a[k], k < a.length - 1 ? a.slice(k + 1) : (args[++i] ?? ""));
					break;
				}
				letters += a[k];
			}
		}
	}
	if (exec) return "tar runs a helper command";
	if (removes) return "tar --remove-files deletes the files it archives";
	if (written.some(hit)) return "tar writes a snapshot/index file into it";
	if (/x/.test(letters) && !/O/.test(letters) && (dirs.length ? dirs.some(hit) : inHere)) return "tar extracts into it";
	if (/[cruA]/.test(letters) && file !== null && hit(file)) return "tar writes an archive into it";
	return null;
}

// sort/sed/gawk long options, for unique-prefix resolution (sort --out=FILE, sed --in).
const SORT_LONG_VALUE = "random-source sort batch-size compress-program files0-from key output buffer-size field-separator temporary-directory parallel".split(" ");
const SORT_LONG = [...SORT_LONG_VALUE, ..."ignore-leading-blanks dictionary-order ignore-case general-numeric-sort ignore-nonprinting month-sort human-numeric-sort numeric-sort random-sort reverse version-sort check debug merge stable unique zero-terminated help version".split(" ")];
const SED_LONG = "quiet silent debug expression file follow-symlinks in-place line-length null-data zero-terminated posix regexp-extended separate sandbox unbuffered binary help version".split(" ");
const AWK_LONG = "assign field-separator file include load exec source characters-as-bytes traditional copyright dump-variables debug gen-pot help lint lint-old non-decimal-data optimize no-optimize pretty-print profile posix re-interval sandbox use-lc-numeric version bignum csv".split(" ");

// Files sort writes: -o/--output (also inside a cluster: sort -uo FILE), -T/--temporary-directory,
// and --compress-program, which runs a program (reported as "$exec" so it always counts).
function sortOutputs(args) {
	const out = [];
	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		if (a === "--") break;
		if (a.startsWith("--")) {
			const [n, v] = splitEq(a);
			const names = longNames(n, SORT_LONG);
			if (names.includes("output") || names.includes("temporary-directory")) out.push(v ?? args[i + 1] ?? "");
			if (names.includes("compress-program")) out.push("$exec");
			if (names.length === 1 && SORT_LONG_VALUE.includes(names[0]) && v === undefined) i++;
			continue;
		}
		if (/^-[A-Za-z]/.test(a)) {
			for (let k = 1; k < a.length; k++) {
				if (!"koStT".includes(a[k])) continue;
				const value = k < a.length - 1 ? a.slice(k + 1) : (args[++i] ?? "");
				if (a[k] === "o" || a[k] === "T") out.push(value);
				break;
			}
		}
	}
	return out;
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
		const longHits = (list, re) => args.some((a) => a.startsWith("--") && longNames(splitEq(a)[0], list).some((x) => re.test(x)));
		if (name === "sed" && touching && (args.some((a) => /^-[a-zA-Z]*[if]/.test(a)) || longHits(SED_LONG, /^(in-place|file)$/) || args.some((a) => SED_WRITE.test(a)))) return "sed in place or with a w/e command";
		if (/^(g|m|n)?awk$/.test(name) && touching && (args.some((a) => /^-[a-zA-Z]*[ifE]$/.test(a)) || longHits(AWK_LONG, /^(include|file|load|exec|dump-variables|pretty-print|profile|debug)$/) || args.some((a) => /system\s*\(|[>|]/.test(a)))) return `${name} with -i/-f or output redirection`;
		if (name === "sort" && sortOutputs(args).some(hit)) return "sort -o/-T/--compress-program";
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
		if (name === "rsync" && args.some((a, i) => /^--(backup-dir|partial-dir|log-file|temp-dir|write-batch|only-write-batch)/.test(a) && hit(splitEq(a)[1] ?? args[i + 1] ?? ""))) return "rsync writes backup/partial/log/temp files into it";
		if (name === "install" && touching && args.some((a) => /^-[a-zA-Z]*d/.test(a) || /^--di/.test(a))) return "install -d creates directories";
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
	// patch (and git apply/am, checked with git) takes its target paths from the diff it reads.
	if (name === "patch") return "patch writes the files its diff names";
	const scriptish = SCRIPT_RUNNER.test(name);
	const mentions = scriptish && (args.some((a) => WEPPY.test(a)) || rec.redirs.some((r) => WEPPY.test(r.body ?? "") || (r.op === "<<<" && WEPPY.test(r.target))));
	// A command fed by a pipe can take paths from its input, so it must be read-only (tee writes only
	// to its arguments, which are checked as touching).
	if (touching || mentions || (rec.piped && name !== "tee")) return `${name || "command"} is not a known read-only command`;
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
const inlineCode = [];
let last = null;
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

	// Publishing tools and HTTP clients, also behind runners (npx rojo upload, uv run rojo upload,
	// uvx --from httpie http POST ..., python -m httpie POST ...) or a computed command name.
	if (PUBLISH_TOOLS.has(name)) checkPublishTool(name, args, rec.viaXargs);
	if (RUNNERS.has(name) || (INTERPRETER.test(name) && args.includes("-m"))) {
		args.forEach((a, k) => {
			if (/\s/.test(a)) return;
			const tool = commandName(a);
			if (PUBLISH_TOOLS.has(tool)) checkPublishTool(tool, args.slice(k + 1), rec.viaXargs);
			if (HTTP_CLIENTS[tool]) checkHttp(tool, args.slice(k + 1), rec);
		});
	}
	const env = Object.fromEntries([...vars, ...assigns]);
	if (computed && args.some((a) => PUBLISH_VERBS.test(a))) deny(`the command name ${rec.argv[0]} is computed and is followed by a publish verb; spell out the tool`);
	if (computed && gitInvocation(args, here.path, env).sub === "push") checkPush(gitInvocation(args, here.path, env)); // $(which git) push

	// Web API writes.
	if (HTTP_CLIENTS[name]) checkHttp(name, args, rec);
	if (computed) {
		const req = merge(curlRequest(args), wgetRequest(args), psRequest(args, 2));
		if (req.writes && (req.unknown || req.urls.some((u) => ROBLOX_HOST.test(hostOf(u)) || /[$`]/.test(hostOf(u))))) deny(`the command name ${rec.argv[0]} is computed and sends a write request; spell out the HTTP client`);
	}

	// Inline interpreter code (python -c, node -e, heredocs and here-strings, text piped into it) is
	// scanned as text for publishing tools and HTTP clients it starts.
	// Stdin is code only when no script file is named (python3 - <<EOF, node with no file); for
	// `node script.mjs <<EOF` it is the script's data.
	if (INTERPRETER.test(name) || computed) {
		inlineCode.push(...args);
		const script = args.find((a) => !a.startsWith("-") || a === "-");
		if (script === undefined || script === "-") {
			inlineCode.push(...rec.redirs.flatMap((r) => (r.op === "<<<" ? [r.target] : r.op.startsWith("<<") ? [r.body ?? ""] : [])));
			if (rec.piped && last) inlineCode.push(...last.argv, ...last.redirs.map((r) => r.body ?? r.target));
		}
	}
	last = rec;

	// git: force pushes anywhere, writes into weppy-project-sync.
	if (name === "git") {
		let inv = gitInvocation(args, here.path, env);
		// git -c settings can run commands (core.fsmonitor, core.pager, alias.x=!cmd): scan them as code.
		inlineCode.push(...inv.configs.map(([, v]) => v ?? ""));
		// An alias defined on this command line (git -c alias.p='push -f' p origin main) is expanded.
		const alias = inv.configs.find(([k]) => k.toLowerCase() === `alias.${String(inv.sub).toLowerCase()}`)?.[1];
		if (alias !== undefined) {
			if (alias.startsWith("!")) {
				if (/\bpush\b/.test(alias)) deny(`git alias ${inv.sub} runs a shell command with a push this guard cannot check; run the push directly`);
			} else {
				const expanded = gitInvocation(alias.split(/\s+/).filter(Boolean), inv.dir);
				inv = { ...inv, sub: expanded.sub, rest: [...expanded.rest, ...inv.rest], configs: [...inv.configs, ...expanded.configs] };
			}
		}
		if (inv.sub === "push") checkPush(inv);
		if (inv.sub === "config" && !gitReadOnly("config", inv.rest) && inv.rest.some((a) => /^(remote\..+\.(mirror|push)|push\.default)$/i.test(a))) pushConfigChanged = true;
		if (inv.sub === "remote" && inv.rest.some((a) => a.startsWith("--mirror"))) pushConfigChanged = true;
		if (weppyAnywhere && inv.sub) {
			const gitEnv = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR"].map((k) => env[k]).filter(Boolean);
			const touches =
				inHere ||
				WEPPY_DIR.test(inv.dir) ||
				[inv.gitDir, inv.workTree].some((p) => p !== null && (pathy(p) || /[$`]/.test(p))) ||
				gitEnv.some((e) => pathy(e.value) || e.tainted) ||
				gitPathArgs(inv.sub, inv.rest).some((a) => pathy(a));
			if (touches && !gitReadOnly(inv.sub, inv.rest)) weppyDeny(`git ${inv.sub}`);
			// -c settings can run commands even under a read-only subcommand (core.fsmonitor, core.pager).
			if (touches && inv.configs.length) weppyDeny(`git -c ${inv.configs[0][0]} can run a command`);
			// git apply/am take their target paths from the patch they read.
			if (["apply", "am"].includes(inv.sub)) weppyDeny(`git ${inv.sub} writes the files its patch names`);
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

const code = inlineCode.join("\n");
if (CODE_PUBLISH.test(code)) deny("inline script or git setting starts a publishing tool (rojo upload, mantle deploy/destroy, tarmac sync/upload-image, asphalt sync/upload, rbxcloud writes)");
if (ROBLOX_HOST.test(code) && CODE_HTTP_CLI_WRITE.test(code)) deny("inline script runs an HTTP client that sends a write request to a Roblox web API");
// Inline scripts that send writes to a Roblox web API.
if (sawInterpreter && (ROBLOX_HOST.test(allText) || ROBLOX_ENV.test(allText)) && SCRIPT_WRITE.test(allText)) deny("inline script sends a write request to a Roblox web API");
process.exit(0);
