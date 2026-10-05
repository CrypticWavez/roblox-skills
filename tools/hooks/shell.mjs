// Minimal shell parser for the PreToolUse guards. It evaluates nothing. It splits a command line
// into simple commands ({ argv, redirs }) so rules can look at a command's own arguments
// instead of the raw text, which made the old regexes depend on argument order.
//
// Handled: ' " $'' quoting, backslashes, ; && || | & newlines ( ), $(...) and `...`
// substitutions, redirections (2>, >>, &>, <<EOF heredocs), leading VAR=value assignments,
// wrappers (sudo, env, xargs, timeout, nohup, ...), find -exec, and nested command strings in
// bash/sh -c, eval, powershell -Command / -EncodedCommand, cmd /c and wsl.
// Not handled (residual risk): variables and aliases that hide the command name, scripts
// executed from files, and deliberately obfuscated text.

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
		const op = OPERATORS.find((o) => src.startsWith(o, i));
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
	sudo: ["-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T"],
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
	watch: ["-n", "-d", "--interval"],
	unbuffer: [],
	chronic: [],
};
const RESERVED = new Set(["!", "{", "}", "then", "do", "else", "elif", "if", "while", "until", "fi", "done", "esac", "&"]);

function stripWrappers(argv) {
	let i = 0;
	let viaXargs = false;
	for (;;) {
		while (i < argv.length && (RESERVED.has(argv[i]) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(argv[i]))) i++;
		const name = commandName(argv[i]);
		const argOpts = WRAPPERS[name];
		if (!argOpts || i >= argv.length - 1) break;
		if (name === "xargs") viaXargs = true;
		i++;
		while (i < argv.length) {
			const a = argv[i];
			if (argOpts.includes(a)) i += 2;
			else if (a.startsWith("-") && a !== "-") i++;
			else if (name === "env" && /^[A-Za-z_][A-Za-z0-9_]*=/.test(a)) i++;
			else if ((name === "timeout" || name === "nice") && /^[\d.]+[smhd]?$/.test(a)) i++;
			else break;
		}
	}
	return { argv: argv.slice(i), viaXargs };
}

function nestedScripts(argv) {
	const name = commandName(argv[0]);
	const rest = argv.slice(1);
	if (["bash", "sh", "zsh", "dash", "ksh", "fish", "busybox"].includes(name)) {
		const k = rest.findIndex((a) => /^-[a-zA-Z]*c[a-zA-Z]*$/.test(a));
		if (k >= 0 && rest[k + 1] !== undefined) return [[rest[k + 1], "sh"]];
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
		if (k >= 0) return [[rest.slice(k + 1).join(" "), "ps"]];
		const first = rest.findIndex((a) => !a.startsWith("-"));
		return first >= 0 ? [[rest.slice(first).join(" "), "ps"]] : [];
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

function collect(items, out, depth) {
	let cur = { argv: [], redirs: [] };
	const finish = () => {
		if (cur.argv.length || cur.redirs.length) expand(cur, out, depth);
		cur = { argv: [], redirs: [] };
	};
	for (let k = 0; k < items.length; k++) {
		const it = items[k];
		if (it.type === "op") {
			finish();
			continue;
		}
		if (it.type === "sub") {
			collect(it.items, out, depth + 1);
			continue;
		}
		if (it.type === "redir") {
			const target = items[k + 1]?.type === "word" ? items[k + 1] : null;
			if (target) {
				k++;
				for (const sub of target.subs) collect(sub, out, depth + 1);
			}
			cur.redirs.push({ op: it.op, fd: it.fd, target: target ? target.value : "", body: it.body });
			continue;
		}
		for (const sub of it.subs) collect(sub, out, depth + 1);
		cur.argv.push(it.value);
	}
	finish();
}

function expand(cmd, out, depth) {
	const { argv, viaXargs } = stripWrappers(cmd.argv);
	out.push({ argv, redirs: cmd.redirs, viaXargs });
	if (depth > 6 || !argv.length) return;
	for (const [script, mode] of nestedScripts(argv)) collect(lex(script, 0, false, mode).items, out, depth + 1);
	for (const sub of findExecs(argv)) out.push({ argv: stripWrappers(sub).argv, redirs: [], viaXargs: true });
}

// Every simple command in `text`, in source order, nested ones included.
export function parseCommands(text) {
	const out = [];
	collect(lex(String(text ?? ""), 0, false).items, out, 0);
	return out;
}
