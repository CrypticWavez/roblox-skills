// Minimal shell parser for the PreToolUse guards. It evaluates nothing. It splits a command line
// into simple commands so rules can look at a command's own arguments instead of the raw text,
// which made the old regexes depend on argument order. Each command is
//   { argv, redirs, assigns, chdir, viaXargs, piped, carrier, mode }
// assigns: leading VAR=value words (and env VAR=value); chdir: env -C / sudo -D directory;
// viaXargs: arguments may be appended from input (xargs, find -exec); piped: stdin is a pipe;
// carrier: a shell whose script text was parsed into further commands; mode: "sh" or "ps".
//
// Handled: ' " $'' quoting, backslashes, ; && || | & newlines ( ), PowerShell { } blocks,
// $(...) and `...` substitutions, redirections (2>, >>, &>, <<EOF heredocs, <<<), leading
// VAR=value assignments, wrappers (sudo, env, xargs, timeout, nohup, ...), find -exec, and nested
// scripts in bash/sh -c, eval, powershell -Command / -EncodedCommand, cmd /c, wsl, and a shell
// reading its script from a heredoc or from echo/printf/cat piped into it.
// Not handled (residual risk): aliases, scripts executed from files, script text produced by
// other programs, and deliberately obfuscated text. The guards expand variables assigned in the
// same command line themselves.

const OPERATORS = ["&&", "||", "|&", ";;", ";", "|", "&", "\n", "(", ")"];
const REDIRECTS = ["&>>", "&>", ">>", ">|", ">&", "<<<", "<<-", "<<", "<>", "<&", ">", "<"];

// mode "ps" (PowerShell / cmd strings): backslash is literal and a backtick escapes the next char.
function lex(src, start, nested, mode = "sh") {
	const items = [];
	let word = null;
	let depth = 0;
	let i = start;
	const ensure = () => {
		if (word === null) word = { value: "", quoted: false, subs: [] };
	};
	const flush = () => {
		if (word !== null) items.push({ type: "word", ...word });
		word = null;
	};
	const substitution = (from) => {
		// from points just past "$("; returns the index just past the matching ")".
		const inner = lex(src, from, true, mode);
		word.subs.push(inner.items);
		return inner.end + 1;
	};
	const backtick = (from) => {
		let j = from;
		while (j < src.length && src[j] !== "`") j += src[j] === "\\" ? 2 : 1;
		word.subs.push(lex(src.slice(from, j), 0, false, mode).items);
		return j + 1;
	};
	while (i < src.length) {
		const c = src[i];
		if (c === " " || c === "\t" || c === "\r") {
			flush();
			i++;
			continue;
		}
		if (mode === "ps" && c === "`") {
			ensure();
			word.value += src[i + 1] ?? "";
			i += 2;
			continue;
		}
		if (c === "\\" && mode !== "ps") {
			if (src[i + 1] === "\n") {
				i += 2;
				continue;
			}
			ensure();
			word.value += src[i + 1] ?? "";
			i += 2;
			continue;
		}
		if (c === "'") {
			ensure();
			word.quoted = true;
			const j = src.indexOf("'", i + 1);
			const end = j < 0 ? src.length : j;
			word.value += src.slice(i + 1, end);
			i = end + 1;
			continue;
		}
		if (c === "$" && src[i + 1] === "'") {
			ensure();
			word.quoted = true;
			i += 2;
			while (i < src.length && src[i] !== "'") {
				if (src[i] === "\\" && i + 1 < src.length) {
					word.value += src[i + 1];
					i += 2;
				} else word.value += src[i++];
			}
			i++;
			continue;
		}
		if (c === '"') {
			ensure();
			word.quoted = true;
			i++;
			while (i < src.length && src[i] !== '"') {
				if (src[i] === "\\" && mode !== "ps" && i + 1 < src.length && '"\\$`\n'.includes(src[i + 1])) {
					word.value += src[i + 1];
					i += 2;
				} else if (src[i] === "$" && src[i + 1] === "(") {
					const from = i;
					i = substitution(i + 2);
					word.value += src.slice(from, i);
				} else if (src[i] === "`" && mode !== "ps") {
					const from = i;
					i = backtick(i + 1);
					word.value += src.slice(from, i);
				} else word.value += src[i++];
			}
			i++;
			continue;
		}
		if (c === "$" && src[i + 1] === "(") {
			ensure();
			const from = i;
			i = substitution(i + 2);
			word.value += src.slice(from, i);
			continue;
		}
		if (c === "`" && mode !== "ps") {
			ensure();
			const from = i;
			i = backtick(i + 1);
			word.value += src.slice(from, i);
			continue;
		}
		if (c === "#" && word === null) {
			while (i < src.length && src[i] !== "\n") i++;
			continue;
		}
		if ((c === "<" || c === ">") && src[i + 1] === "(") {
			// process substitution: parse the inner command, keep the word as an opaque path
			flush();
			const inner = lex(src, i + 2, true, mode);
			items.push({ type: "sub", items: inner.items });
			i = inner.end + 1;
			continue;
		}
		const redirect = REDIRECTS.find((op) => src.startsWith(op, i));
		if (redirect && (redirect[0] !== "&" || src[i + 1] === ">")) {
			let fd = "";
			if (word !== null && !word.quoted && /^\d+$/.test(word.value)) {
				fd = word.value;
				word = null;
			} else flush();
			items.push({ type: "redir", op: redirect, fd });
			i += redirect.length;
			continue;
		}
		// PowerShell script blocks ({ Remove-Item $_ }) and hashtables hold separate statements.
		const op = mode === "ps" && (c === "{" || c === "}") ? c : OPERATORS.find((o) => src.startsWith(o, i));
		if (op) {
			flush();
			if (op === "(") depth++;
			if (op === ")") {
				if (depth === 0 && nested) return { items, end: i };
				depth = Math.max(0, depth - 1);
			}
			items.push({ type: "op", value: op });
			i += op.length;
			if (op === "\n") i = readHeredocs(src, i, items);
			continue;
		}
		ensure();
		word.value += c;
		i++;
	}
	flush();
	return { items, end: src.length };
}

// After a newline, consume the bodies of any pending <<DELIM heredocs.
function readHeredocs(src, i, items) {
	for (let k = 0; k < items.length; k++) {
		const r = items[k];
		if (r.type !== "redir" || !r.op.startsWith("<<") || r.op === "<<<" || r.body !== undefined) continue;
		const delim = items[k + 1]?.type === "word" ? items[k + 1].value : "";
		const lines = [];
		while (i < src.length) {
			let end = src.indexOf("\n", i);
			if (end < 0) end = src.length;
			let line = src.slice(i, end);
			i = end + 1;
			if (r.op === "<<-") line = line.replace(/^\t+/, "");
			if (line === delim) break;
			lines.push(line);
		}
		r.body = lines.join("\n");
	}
	return i;
}

export function commandName(token) {
	return String(token ?? "")
		.split(/[\\/]/)
		.pop()
		.toLowerCase()
		.replace(/\.(exe|cmd|bat|ps1)$/, "");
}

// Wrappers run the rest of their argv as a command. argOpts take a separate value.
const WRAPPERS = {
	sudo: ["-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T", "--chdir", "--user", "--group"],
	doas: ["-u", "-C"],
	env: ["-u", "-C", "-S", "--unset", "--chdir", "--split-string"],
	command: [],
	builtin: [],
	exec: ["-a"],
	nohup: [],
	nice: ["-n", "--adjustment"],
	ionice: ["-c", "-n", "-p"],
	time: ["-f", "-o"],
	timeout: ["-s", "-k", "--signal", "--kill-after"],
	stdbuf: ["-i", "-o", "-e"],
	xargs: ["-I", "-n", "-P", "-L", "-s", "-d", "-E", "-a", "--max-args", "--max-procs", "--delimiter", "--arg-file"],
	parallel: ["-j", "-S", "--jobs"],
	watch: ["-n", "-d", "--interval"],
	unbuffer: [],
	chronic: [],
};
// Wrapper options that change the directory the wrapped command runs in.
const CHDIR_OPTS = { env: ["-C", "--chdir"], sudo: ["-D", "--chdir"] };
const RESERVED = new Set(["!", "{", "}", "then", "do", "else", "elif", "if", "while", "until", "fi", "done", "esac", "&"]);
const ASSIGNMENT = /^([A-Za-z_][A-Za-z0-9_]*)=([\s\S]*)$/;

function stripWrappers(argv) {
	let i = 0;
	let viaXargs = false;
	let chdir = null;
	const assigns = [];
	for (;;) {
		while (i < argv.length && (RESERVED.has(argv[i]) || ASSIGNMENT.test(argv[i]))) {
			const m = ASSIGNMENT.exec(argv[i]);
			if (m) assigns.push([m[1], m[2]]);
			i++;
		}
		const name = commandName(argv[i]);
		const argOpts = WRAPPERS[name];
		if (!argOpts || i >= argv.length - 1) break;
		if (name === "xargs" || name === "parallel") viaXargs = true;
		i++;
		while (i < argv.length) {
			const a = argv[i];
			const [opt, attached] = a.startsWith("--") && a.includes("=") ? [a.slice(0, a.indexOf("=")), a.slice(a.indexOf("=") + 1)] : [a, undefined];
			if (CHDIR_OPTS[name]?.includes(opt)) chdir = attached ?? argv[i + 1] ?? "";
			if (argOpts.includes(a)) i += 2;
			else if (a.startsWith("-") && a !== "-") i++;
			else if (name === "env" && ASSIGNMENT.test(a)) {
				const m = ASSIGNMENT.exec(a);
				assigns.push([m[1], m[2]]);
				i++;
			} else if ((name === "timeout" || name === "nice") && /^[\d.]+[smhd]?$/.test(a)) i++;
			else break;
		}
	}
	return { argv: argv.slice(i), viaXargs, assigns, chdir };
}

const SHELLS = ["bash", "sh", "zsh", "dash", "ksh", "fish", "busybox", "ash", "mksh"];
// Commands whose output, piped into a shell, is the script text itself.
const SCRIPT_PRODUCERS = ["echo", "printf", "print", "write-output", "write-host"];

// Script text a shell reads from stdin: heredocs/here-strings on the shell itself, or the words of
// echo/printf (and heredocs of cat) piped into it.
function stdinScripts(redirs, pipedFrom) {
	const out = [];
	for (const r of redirs) {
		if (r.op === "<<<") out.push(r.target);
		else if (r.op.startsWith("<<") && r.body !== undefined) out.push(r.body);
	}
	if (pipedFrom) {
		const name = commandName(pipedFrom.argv[0]);
		if (SCRIPT_PRODUCERS.includes(name)) out.push(pipedFrom.argv.slice(1).filter((a) => !/^-[neE]+$/.test(a)).join(" "));
		for (const r of pipedFrom.redirs) {
			if (r.op === "<<<") out.push(r.target);
			else if (r.op.startsWith("<<") && r.body !== undefined) out.push(r.body);
		}
	}
	return out;
}

function nestedScripts(argv, redirs, pipedFrom) {
	const name = commandName(argv[0]);
	const rest = argv.slice(1);
	if (SHELLS.includes(name)) {
		const k = rest.findIndex((a) => /^-[a-zA-Z]*c[a-zA-Z]*$/.test(a));
		if (k >= 0 && rest[k + 1] !== undefined) return [[rest[k + 1], "sh"]];
		// No -c: the script is a file argument, or stdin when there is none (or -s / -).
		const file = rest.find((a) => !a.startsWith("-") || a === "-");
		if (file === undefined || file === "-" || rest.includes("-s")) return stdinScripts(redirs, pipedFrom).map((t) => [t, "sh"]);
		return [];
	}
	if (name === "eval") return [[rest.join(" "), "sh"]];
	if (name === "powershell" || name === "pwsh") {
		const enc = rest.findIndex((a) => /^-(e|ec|enc|encodedcommand)$/i.test(a));
		if (enc >= 0 && rest[enc + 1]) {
			try {
				return [[Buffer.from(rest[enc + 1], "base64").toString("utf16le"), "ps"]];
			} catch {
				return [];
			}
		}
		const k = rest.findIndex((a) => /^-(c|command)$/i.test(a));
		if (k >= 0 && rest[k + 1] !== "-") return [[rest.slice(k + 1).join(" "), "ps"]];
		const first = rest.findIndex((a) => !a.startsWith("-"));
		if (k < 0 && first >= 0) return [[rest.slice(first).join(" "), "ps"]];
		return stdinScripts(redirs, pipedFrom).map((t) => [t, "ps"]);
	}
	if (name === "cmd") {
		const k = rest.findIndex((a) => /^\/[ck]$/i.test(a));
		return k >= 0 ? [[rest.slice(k + 1).join(" "), "ps"]] : [];
	}
	if (name === "wsl") {
		const k = rest.findIndex((a) => a === "-e" || a === "--exec" || a === "--");
		return [[rest.slice(k >= 0 ? k + 1 : 0).join(" "), "sh"]];
	}
	return [];
}

function findExecs(argv) {
	if (commandName(argv[0]) !== "find") return [];
	const out = [];
	for (let i = 1; i < argv.length; i++) {
		if (!/^-(exec|execdir|ok|okdir)$/.test(argv[i])) continue;
		const sub = [];
		for (i++; i < argv.length && argv[i] !== ";" && argv[i] !== "+"; i++) sub.push(argv[i]);
		if (sub.length) out.push(sub);
	}
	return out;
}

function collect(items, out, depth, mode) {
	let cur = { argv: [], redirs: [] };
	let pipedFrom = null;
	const finish = (op) => {
		const done = cur.argv.length || cur.redirs.length ? expand(cur, out, depth, mode, pipedFrom) : null;
		pipedFrom = op === "|" || op === "|&" ? done : null;
		cur = { argv: [], redirs: [] };
	};
	for (let k = 0; k < items.length; k++) {
		const it = items[k];
		if (it.type === "op") {
			finish(it.value);
			continue;
		}
		if (it.type === "sub") {
			collect(it.items, out, depth + 1, mode);
			continue;
		}
		if (it.type === "redir") {
			const target = items[k + 1]?.type === "word" ? items[k + 1] : null;
			if (target) {
				k++;
				for (const sub of target.subs) collect(sub, out, depth + 1, mode);
			}
			cur.redirs.push({ op: it.op, fd: it.fd, target: target ? target.value : "", body: it.body });
			continue;
		}
		for (const sub of it.subs) collect(sub, out, depth + 1, mode);
		cur.argv.push(it.value);
	}
	finish(null);
}

function expand(cmd, out, depth, mode, pipedFrom, fromExec = false) {
	const stripped = stripWrappers(cmd.argv);
	const rec = { ...stripped, redirs: cmd.redirs, mode, piped: Boolean(pipedFrom), carrier: false };
	if (fromExec) rec.viaXargs = true;
	out.push(rec);
	if (depth > 6 || !rec.argv.length) return rec;
	const nested = nestedScripts(rec.argv, rec.redirs, pipedFrom);
	if (nested.length) rec.carrier = true;
	for (const [script, m] of nested) collect(lex(script, 0, false, m).items, out, depth + 1, m);
	for (const sub of findExecs(rec.argv)) expand({ argv: sub, redirs: [] }, out, depth + 1, mode, null, true);
	return rec;
}

// Every simple command in `text`, in source order, nested ones included.
export function parseCommands(text) {
	const out = [];
	collect(lex(String(text ?? ""), 0, false).items, out, 0, "sh");
	return out;
}
