"""Factory gate. Tiers:
  fast        format check + JSON validity + secret scan                      (seconds)
  pre-commit  fast + skills sync + gap matrix + content checks + hook self-test + selene + Lune specs
              + fixture hashes + Python unit tests + playbook lint + asset sources + luau-defs lock
              + kit tiers + capture staleness + starter smoke (about a minute)
  pre-release pre-commit + Blender templates/QA + round trip + QA self-test + material library
              + kit/1 bake + glTF validation + previews + luau-lsp analysis + full starter smoke (minutes)

  python3 tools/check.py [--tier fast|pre-commit|pre-release] [--strict] [--update-golden[=NAME,...]]
                         [--install-git-hook] [--live-links] [--allow-skip STEP]

--update-golden rewrites every golden: tests/golden/fixture-hashes.json, tests/golden/studio-smoke.json
(tools/lune/smoke_hashes.luau, run before the Lune specs that check it) and the spec goldens of
tests/lib/Golden.luau (the Lune specs get FACTORY_UPDATE_GOLDEN=1). --update-golden=NAME[,NAME] rewrites
only the named ones: fixture-hashes, studio-smoke, or spec golden names (passed to the specs as
FACTORY_UPDATE_GOLDEN=NAME,...); a named spec golden that no spec wrote FAILs (step golden-update), so a
typo cannot pass silently. Without the flag a missing golden FAILs, and FACTORY_UPDATE_GOLDEN is removed
from every step's environment, so a stray shell variable cannot rewrite a golden.

Content checks: doc-links (relative Markdown links and heading anchors resolve, URLs are well formed),
knowledge-index (knowledge/INDEX.md is current), knowledge-paths (each knowledge record's cited paths
exist here or the record is scoped to the workbench), fixtures-readme (every fixtures/ entry is
documented), asset-provenance (every Roblox asset id in a committable file is registered in
assets/provenance.json), rojo-sourcemap (each fixtures/*.project.json maps and every .luau file under
packages/ and fixtures/ is reachable from one), and gate-selftest (each of them rejects a broken input).
--live-links additionally requests every external URL; it is opt-in only (live checks are flaky), so no
tier or CI job runs it by default.
Missing tools (stylua, node, selene, lune, rojo, bpy) are reported as SKIPPED, never as passes (exit 3 of
tools/starter_smoke.py, which lacks rojo, lune or stylua, is starter-smoke-full SKIPPED), and a
SKIPPED step fails the run (default tier and the installed git hook included) unless it is selene, which
needs network to generate its Roblox std, luau-lsp-analyze (needs the pinned luau-lsp; exit 3 of
tools/luau_analyze.py), or named with --allow-skip. --strict allows no skips at all;
CI runs with it, so a missing tool cannot keep CI green.
The secret scan uses tools/hooks/secret-patterns.json, the same list as the Claude edit hook, over every
file git would commit (tracked plus untracked, not ignored), dotfiles and scripts included.
Writes build/check-report.json. Opens no Studio session; publishes, uploads and buys nothing.
"""
import argparse
import fnmatch
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEXT_SUFFIXES = {".luau", ".lua", ".py", ".mjs", ".js", ".json", ".md", ".toml", ".yml", ".yaml", ".txt"}
SKIP_DIRS = {".git", "build", ".venv", "node_modules", "__pycache__"}
GOLDEN = ROOT / "tests" / "golden" / "fixture-hashes.json"
GOLDEN_DIR = GOLDEN.parent
GOLDEN_ENV = "FACTORY_UPDATE_GOLDEN"  # read by tests/lib/Golden.luau
GATE_GOLDENS = ("fixture-hashes", "studio-smoke")  # written by this gate, not by specs
GOLDEN_NAME = re.compile(r"^[a-z0-9][a-z0-9_.-]*$")  # same rule as tests/lib/Golden.luau
INHERITED_SPECS = [
    "tests/runtime/run.luau",
    "tests/creator/animation.luau",
    "tests/creator/audio_movement.luau",
    "tests/creator/effects.luau",
    "tests/creator/ui.luau",
    "tests/creator/world.luau",
    "tests/diagnostics/network.luau",
]
# selene needs network to generate its Roblox std; luau-lsp-analyze needs the pinned luau-lsp (rokit
# installs it in CI). --strict (CI) allows no skips.
ALLOWED_SKIPS = {"selene", "luau-lsp-analyze"}
SECRET_PATTERNS_FILE = ROOT / "tools" / "hooks" / "secret-patterns.json"
SECRET_SCAN_MAX_BYTES = 5_000_000


def load_secret_patterns(path=SECRET_PATTERNS_FILE):
    """(compiled regex, label) pairs from the pattern file shared with tools/hooks/lib.mjs."""
    data = json.loads(path.read_text(encoding="utf-8"))
    return [(re.compile(p["pattern"], re.IGNORECASE if "i" in p.get("flags", "") else 0), p["label"]) for p in data["patterns"]]


def find_secrets(text, patterns):
    return sorted({label for regex, label in patterns if regex.search(text)})


def files(suffixes=TEXT_SUFFIXES):
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            p = Path(dirpath) / name
            if p.suffix in suffixes:
                yield p


FAILURE_LINE = re.compile(r"^\s*(FAIL|FAILED|ERROR|Error|error)\b|Traceback|AssertionError")


def run(cmd, timeout=600, env=None):
    start = time.time()
    try:
        proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s", round(time.time() - start, 1)
    lines = (proc.stdout + proc.stderr).strip().splitlines()
    tail = lines[-15:]
    # Keep failure lines that scrolled out of the tail, so the report names the failing case.
    failures = [line for line in lines[:-15] if FAILURE_LINE.search(line)][:20]
    return proc.returncode, "\n".join(failures + tail), round(time.time() - start, 1)


def headline(detail):
    """The line that explains a failure: the first FAIL/ERROR line, else the last line."""
    lines = [line for line in detail.splitlines() if line.strip()]
    return next((line for line in lines if FAILURE_LINE.search(line)), lines[-1] if lines else "")


class Gate:
    def __init__(self):
        self.results = []

    def add(self, name, status, detail="", seconds=0.0):
        self.results.append({"name": name, "status": status, "detail": detail, "seconds": seconds})
        mark = {"PASS": "ok  ", "FAIL": "FAIL", "SKIPPED": "skip"}[status]
        why = headline(detail) if status != "PASS" else ""
        print(f"[{mark}] {name} ({seconds}s){': ' + why if why else ''}")

    def cmd(self, name, cmd, needs=None, timeout=600, env=None, skip_codes=()):
        if needs and shutil.which(needs) is None:
            self.add(name, "SKIPPED", f"{needs} not installed")
            return False
        code, tail, secs = run(cmd, timeout, env)
        self.add(name, "PASS" if code == 0 else "SKIPPED" if code in skip_codes else "FAIL", tail, secs)
        return code == 0


def check_json(gate):
    bad = []
    for p in files({".json"}):
        try:
            json.loads(p.read_text(encoding="utf-8"))
        except ValueError as err:
            bad.append(f"{p.relative_to(ROOT)}: {err}")
    gate.add("json-valid", "FAIL" if bad else "PASS", "\n".join(bad))


def committable_files():
    """Every file git would commit: tracked plus untracked-but-not-ignored. Falls back to a walk."""
    try:
        out = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd=ROOT, capture_output=True, timeout=60, check=True,
        ).stdout
        paths = [ROOT / name for name in out.decode("utf-8", "surrogateescape").split("\0") if name]
    except (OSError, subprocess.SubprocessError):
        paths = []
        for dirpath, dirnames, filenames in os.walk(ROOT):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            paths.extend(Path(dirpath) / name for name in filenames)
    return sorted({p for p in paths if p.is_file()})


def check_secrets(gate):
    try:
        patterns = load_secret_patterns()
    except (OSError, ValueError, KeyError, re.error) as err:
        gate.add("secret-scan", "FAIL", f"{SECRET_PATTERNS_FILE.relative_to(ROOT)} could not be loaded: {err}")
        return
    hits = []
    for p in committable_files():
        if p.stat().st_size > SECRET_SCAN_MAX_BYTES:
            continue
        data = p.read_bytes()
        if b"\0" in data[:8192]:
            continue  # binary
        labels = find_secrets(data.decode("utf-8", errors="ignore"), patterns)
        if labels:
            hits.append(f"{p.relative_to(ROOT).as_posix()}: {', '.join(labels)}")
    gate.add("secret-scan", "FAIL" if hits else "PASS", "\n".join(hits))


def check_selene(gate):
    if shutil.which("selene") is None:
        gate.add("selene", "SKIPPED", "selene not installed")
        return
    if not (ROOT / "roblox.yml").exists() and run(["selene", "generate-roblox-std"], 120)[0] != 0:
        gate.add("selene", "SKIPPED", "roblox std could not be generated (needs network to the Roblox API dump)")
        return
    gate.cmd("selene", ["selene", "packages"])


def golden_scope(value):
    """--update-golden value -> None (flag absent), "all" (bare flag) or a frozenset of golden names.
    Raises ValueError for an empty or malformed name."""
    if value is None:
        return None
    if value == "all":
        return "all"
    names = [name.strip() for name in value.split(",")]
    bad = [name for name in names if not GOLDEN_NAME.match(name)]
    if bad:
        raise ValueError(f"--update-golden: bad golden name(s) {bad} (lower-case letters, digits, _ . -)")
    return frozenset(names)


def golden_updates(scope, name):
    return scope == "all" or (scope is not None and scope != "all" and name in scope)


def golden_env(scope, base):
    """Environment for the Lune specs: FACTORY_UPDATE_GOLDEN only when this run updates spec goldens."""
    env = {key: value for key, value in base.items() if key != GOLDEN_ENV}
    if scope == "all":
        env[GOLDEN_ENV] = "1"
    elif scope:
        spec_names = sorted(scope - set(GATE_GOLDENS))
        if spec_names:
            env[GOLDEN_ENV] = ",".join(spec_names)
    return env


def golden_snapshot(directory=GOLDEN_DIR):
    return {p.name[: -len(".json")]: p.read_bytes() for p in sorted(directory.glob("*.json"))} if directory.is_dir() else {}


def golden_report(scope, before, after):
    """(problems, note) after an update run: a named spec golden that no spec wrote is a problem."""
    problems = []
    if scope not in (None, "all"):
        problems = [
            f"tests/golden/{name}.json was not written by any spec (typo, or the spec did not run?)"
            for name in sorted(scope - set(GATE_GOLDENS))
            if name not in after
        ]
    added = sorted(set(after) - set(before))
    changed = sorted(name for name in set(after) & set(before) if after[name] != before[name])
    removed = sorted(set(before) - set(after))
    parts = [f"{kind}: {', '.join(names)}" for kind, names in (("added", added), ("rewrote", changed), ("removed", removed)) if names]
    return problems, "; ".join(parts) or "no golden changed"


def check_fixtures(gate, update):
    if shutil.which("lune") is None:
        gate.add("fixture-build", "SKIPPED", "lune not installed")
        return
    code, tail, secs = run(["lune", "run", "tools/lune/build_fixtures.luau", "build/fixtures"])
    gate.add("fixture-build", "PASS" if code == 0 else "FAIL", tail, secs)
    if code != 0:
        return
    report = json.loads((ROOT / "build/fixtures/report.json").read_text())
    hashes = {k: v["hash"] for k, v in report["fixtures"].items()}
    if update:
        old = json.loads(GOLDEN.read_text()) if GOLDEN.exists() else {}
        GOLDEN.parent.mkdir(parents=True, exist_ok=True)
        GOLDEN.write_text(json.dumps(hashes, indent=2, sort_keys=True) + "\n")
        changed = sorted(k for k in set(hashes) | set(old) if hashes.get(k) != old.get(k))
        gate.add("fixture-hashes", "PASS", f"golden updated ({', '.join(changed) if changed else 'no hash changed'})")
        return
    if not GOLDEN.exists():  # a deleted golden must not turn hash drift into a pass
        gate.add("fixture-hashes", "FAIL", f"{GOLDEN.relative_to(ROOT).as_posix()} is missing (intended? rerun with --update-golden=fixture-hashes)")
        return
    golden = json.loads(GOLDEN.read_text())
    drift = {
        "added": sorted(set(hashes) - set(golden)),
        "removed": sorted(set(golden) - set(hashes)),
        "changed": sorted(k for k in set(golden) & set(hashes) if golden[k] != hashes[k]),
    }
    detail = "; ".join(f"{kind}: {', '.join(names)}" for kind, names in drift.items() if names)
    if detail:
        detail += " (intended? rerun with --update-golden=fixture-hashes)"
    gate.add("fixture-hashes", "FAIL" if detail else "PASS", detail)


def check_starter(gate, strict):
    """starter-smoke: scaffold a game repo with tools/new_project.py into a temp dir and run that repo's
    own gate there (StyLua, JSON, secrets, skills, hooks, Selene, Lune specs, Rojo build), then check
    the starter's refusals (dest inside the factory, non-empty dest) and --update (no-op on a fresh
    copy, refused after a package was edited in the game repo)."""
    missing = [tool for tool in ("lune", "stylua", "rojo") if shutil.which(tool) is None]
    if missing:
        gate.add("starter-smoke", "SKIPPED", f"{', '.join(missing)} not installed")
        return
    start, problems, inner = time.time(), [], ""
    new_project = [sys.executable, "tools/new_project.py"]

    def expect(args, code, text):
        got, out, _ = run(new_project + args)
        if got != code or text not in out:
            problems.append(f"FAIL new_project.py {' '.join(args)}: wanted exit {code} and '{text}', got {got}: {headline(out)}")

    with tempfile.TemporaryDirectory(prefix="starter-smoke-") as tmp:
        dest = Path(tmp) / "StarterSmoke"
        code, out, _ = run(new_project + [str(dest)])
        if code != 0:
            problems.append(f"FAIL scaffold: {headline(out)}\n{out}")
        else:
            if (ROOT / "roblox.yml").exists():  # Selene's generated Roblox std (CI); avoids a second download
                shutil.copy(ROOT / "roblox.yml", dest / "roblox.yml")
            # The documented next step; the Codex hook commands resolve the repo root with git.
            subprocess.run(["git", "init", "-q", str(dest)], capture_output=True, text=True, timeout=60)
            cmd = [sys.executable, "tools/check.py", "--tier", "pre-commit"] + (["--strict"] if strict else [])
            try:
                proc = subprocess.run(cmd, cwd=dest, capture_output=True, text=True, timeout=300)
                code, inner = proc.returncode, (proc.stdout + proc.stderr).strip()
            except subprocess.TimeoutExpired as err:
                code, inner = 124, f"game-repo gate timed out after {err.timeout}s"
            report_path = dest / "build" / "check-report.json"
            report = json.loads(report_path.read_text()) if report_path.exists() else {}
            status = {r["name"]: r["status"] for r in report.get("results", [])}
            not_passed = [s for s in ("stylua", "skills-sync", "lune-specs", "rojo-build") if status.get(s) != "PASS"]
            if code != 0 or not_passed:
                problems.append(f"FAIL game-repo gate: failed={report.get('failed')} not passed={not_passed}")
            shutil.rmtree(dest / ".git", ignore_errors=True)  # --update checks below run on an uncommitted copy
            expect([str(ROOT / "build" / "starter-inside")], 2, "overlaps the factory")
            expect([str(dest)], 2, "is not empty")
            expect(["--update", str(dest)], 0, "unchanged")
            rng = dest / "packages" / "ProcGen" / "Rng.luau"
            rng.write_text(rng.read_text() + "-- local edit\n")
            expect(["--update", str(dest)], 2, "edited here")
    detail = "\n".join(problems + ([inner] if inner else []))
    gate.add("starter-smoke", "FAIL" if problems else "PASS", detail, round(time.time() - start, 1))


# ---- Content checks: doc links, knowledge records, fixtures README, asset provenance, Rojo sourcemaps.
# The *_problems functions are pure (explicit root and paths) so gate-selftest can feed them broken input.

def rel_posix(path, root=ROOT):
    return Path(os.path.relpath(path, root)).as_posix()


def inside(path, root):
    try:
        rel = os.path.relpath(path, root)
    except ValueError:  # another drive on Windows
        return False
    return rel != ".." and not rel.startswith(".." + os.sep) and not os.path.isabs(rel)


FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
CODE_SPAN = re.compile(r"(`+)(?:(?!\1).)+?\1")
HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$")
HTML_ANCHOR = re.compile(r"<a\s[^>]*\b(?:id|name)=\"([^\"]+)\"", re.IGNORECASE)
INLINE_LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*(<[^>\n]*>|[^)\s]+)(?:\s+(?:\"[^\"]*\"|'[^']*'))?\s*\)")
REF_DEF = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(<[^>\n]*>|\S+)")
BARE_URL = re.compile(r"https?://[^\s<>()\[\]\"'`]+")
SCHEME = re.compile(r"^([A-Za-z][A-Za-z0-9+.-]*):")
URL_BAD_CHAR = re.compile(r"[^A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]|%(?![0-9A-Fa-f]{2})")  # outside RFC 3986
IMPORT_LINE = re.compile(r"^@(\S+)\s*$")  # Claude memory imports, read only in CLAUDE.md / AGENTS.md
IMPORT_FILES = {"CLAUDE.md", "AGENTS.md"}


def github_slug(heading):
    """GitHub's heading anchor: link text kept, markup and punctuation dropped, spaces to hyphens."""
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)
    text = re.sub(r"<[^>]+>", "", text).lower()
    return re.sub(r"[^\w\- ]", "", text).replace(" ", "-")


def markdown_scan(text, imports=False):
    """(links, urls, anchors) outside code: link targets and http(s) URLs with line numbers, heading anchors."""
    links, urls, anchors, seen, fence = [], [], set(), {}, None
    for number, line in enumerate(text.splitlines(), 1):
        opener = FENCE.match(line)
        if opener:
            marker = opener.group(1)
            if fence is None:
                fence = marker
            elif marker[0] == fence[0] and len(marker) >= len(fence) and not line.strip(marker[0] + " \t"):
                fence = None
            continue
        if fence:
            continue
        heading = HEADING.match(line)
        if heading:
            slug = github_slug(heading.group(1))
            count = seen.get(slug, 0)
            seen[slug] = count + 1
            anchors.add(slug if count == 0 else f"{slug}-{count}")
        anchors.update(HTML_ANCHOR.findall(line))
        code_free = CODE_SPAN.sub("", line)
        for regex in (INLINE_LINK, REF_DEF):
            links += [(number, target.strip("<>")) for target in regex.findall(code_free)]
        if imports and IMPORT_LINE.match(code_free):
            links.append((number, IMPORT_LINE.match(code_free).group(1)))
        urls += [(number, url.rstrip(".,;:*")) for url in BARE_URL.findall(code_free)]
    return links, urls, anchors


def url_problem(url):
    """Why an http(s) URL is malformed, or None. Offline: the host is never contacted."""
    try:
        parts = urllib.parse.urlsplit(url)
        _ = parts.port  # raises on a non-numeric port
    except ValueError as err:
        return f"malformed URL ({err})"
    host = parts.hostname or ""
    if parts.scheme not in ("http", "https") or not host:
        return "malformed URL"
    if not re.fullmatch(r"[a-z0-9.-]+", host) or ("." not in host and host != "localhost") or ".." in host:
        return "malformed URL (bad host)"
    bad = URL_BAD_CHAR.search(url)
    if bad:
        return f"malformed URL ({bad.group(0)!r} is not allowed in a URL; percent-encode it or put a pattern in a code span)"
    return None


def json_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from json_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from json_strings(item)


def doc_link_problems(root, md_files, json_files=()):
    """Broken relative links/anchors/imports in Markdown and malformed URLs in Markdown or JSON.
    Returns (problems, external_urls)."""
    root = Path(root).resolve()
    problems, external, cache = [], set(), {}

    def scan(path):
        if path not in cache:
            text = path.read_text(encoding="utf-8", errors="replace")
            cache[path] = markdown_scan(text, imports=path.name in IMPORT_FILES)
        return cache[path]

    def add_url(where, url):
        bad = url_problem(url)
        if bad:
            problems.append(f"{where}: {bad}: {url}")
        else:
            external.add(url)

    for path in (Path(p).resolve() for p in md_files):
        rel = rel_posix(path, root)
        links, urls, _ = scan(path)
        for number, url in urls:
            add_url(f"{rel}:{number}", url)
        for number, target in links:
            where = f"{rel}:{number}"
            scheme = SCHEME.match(target)
            if scheme:
                if scheme.group(1).lower() not in ("http", "https", "mailto"):
                    problems.append(f"{where}: unsupported link scheme: {target}")
                continue  # http(s) targets are also bare URLs, checked above
            path_part, _, anchor = target.partition("#")
            path_part = urllib.parse.unquote(path_part.split("?", 1)[0])
            dest = path
            if path_part:
                base = root if path_part.startswith("/") else path.parent
                dest = Path(os.path.normpath(base / path_part.lstrip("/")))
                if not inside(dest, root):
                    problems.append(f"{where}: link leaves the repository: {target}")
                    continue
                if not dest.exists():
                    problems.append(f"{where}: missing link target: {target}")
                    continue
            if anchor and dest.suffix.lower() == ".md" and dest.is_file():
                if anchor.lower() not in scan(dest)[2]:
                    problems.append(f"{where}: no heading for anchor #{anchor} in {rel_posix(dest, root)}")
    for path in json_files:
        rel = rel_posix(Path(path).resolve(), root)
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8"))
        except ValueError:
            continue  # json-valid reports it
        for text in json_strings(data):
            if re.match(r"https?://", text):
                add_url(rel, text.strip())
    return problems, external


LIVE_SKIP_HOSTS = {"localhost", "127.0.0.1", "example.com", "www.example.com"}


def live_link_problems(urls, timeout=15):
    """Request each URL (HEAD, then GET when HEAD is refused). Only 404/410 and unresolvable hosts fail;
    401/403/429/5xx are listed as unverified because sites block or throttle scripted requests."""
    import concurrent.futures
    import urllib.error
    import urllib.request

    def probe(url):
        for method in ("HEAD", "GET"):
            request = urllib.request.Request(url, method=method, headers={"User-Agent": "roblox-factory-link-check"})
            try:
                with urllib.request.urlopen(request, timeout=timeout):
                    return None
            except urllib.error.HTTPError as err:
                if err.code in (404, 410):
                    return ("FAIL", f"{url}: HTTP {err.code}")
                if method == "HEAD" and err.code in (400, 403, 405, 429, 501):
                    continue
                return ("WARN", f"{url}: HTTP {err.code} (unverified)")
            except (urllib.error.URLError, OSError, ValueError) as err:
                reason = str(getattr(err, "reason", err))
                kind = "FAIL" if "Name or service not known" in reason or "getaddrinfo" in reason else "WARN"
                return (kind, f"{url}: {reason}")
        return ("WARN", f"{url}: refused (unverified)")

    todo = sorted(u for u in urls if (urllib.parse.urlsplit(u).hostname or "") not in LIVE_SKIP_HOSTS)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = [r for r in pool.map(probe, todo) if r]
    return [m for k, m in results if k == "FAIL"], [m for k, m in results if k == "WARN"], len(todo)


def check_doc_links(gate, live=False):
    start = time.time()
    tracked = committable_files()
    md = [p for p in tracked if p.suffix == ".md"]
    data = [p for p in tracked if p.suffix == ".json" and rel_posix(p).startswith(("knowledge/", "assets/"))]
    problems, external = doc_link_problems(ROOT, md, data)
    notes = [f"{len(md)} Markdown files, {len(external)} well-formed external URLs (not requested; --live-links does)"]
    if live and not problems:
        failed, unverified, count = live_link_problems(external)
        problems += failed
        notes = [f"--live-links: requested {count} URLs, {len(failed)} dead, {len(unverified)} unverified"] + unverified
    gate.add("doc-links", "FAIL" if problems else "PASS", "\n".join(notes + problems), round(time.time() - start, 2))


KNOWLEDGE_SCOPES = {"repo", "workbench"}
UNSCOPED_CLAIMS = {"verified", "partially_verified"}  # a workbench record writes <status>_on_workbench
CITED_EXTENSIONS = {
    ".py", ".json", ".jsonl", ".md", ".luau", ".lua", ".mjs", ".js", ".toml", ".yml", ".yaml", ".txt",
    ".exe", ".ps1", ".rbxl", ".rbxlx", ".csv", ".png", ".mp4", ".blend", ".fbx", ".glb",
}


def cited_paths(record):
    """Repo-relative file paths in any string of a record: tokens with a slash and a file extension."""
    found = set()
    for text in json_strings(record):
        for token in re.split(r"[\s,;()\[\]\"'`]+", text):
            token = token.rstrip(".:").replace("\\", "/")
            if "/" in token and "://" not in token and not token.startswith("/") and Path(token).suffix.lower() in CITED_EXTENSIONS:
                found.add(token)
    return found


def knowledge_problems(root, record_files):
    """Each record needs id, title, status, scope and scope_note; scope repo cites only existing paths;
    a workbench record may not claim plain 'verified' (this repo cannot reproduce it)."""
    root = Path(root)
    problems, ids = [], {}
    for path in record_files:
        rel = rel_posix(Path(path).resolve(), root.resolve())
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8"))
        except ValueError as err:
            problems.append(f"{rel}: invalid JSON ({err})")
            continue
        for index, record in enumerate(data if isinstance(data, list) else [data]):
            if not isinstance(record, dict):
                problems.append(f"{rel}[{index}]: a record must be an object")
                continue
            rid = str(record.get("id") or f"{rel}[{index}]")
            missing_fields = [f for f in ("id", "title", "status", "scope", "scope_note") if not str(record.get(f, "")).strip()]
            if missing_fields:
                problems.append(f"{rid}: missing {', '.join(missing_fields)}")
            if rid in ids:
                problems.append(f"{rid}: duplicate id (also in {ids[rid]})")
            ids[rid] = rel
            scope, status = record.get("scope"), record.get("status")
            if scope not in KNOWLEDGE_SCOPES:
                if scope:
                    problems.append(f"{rid}: scope must be one of {sorted(KNOWLEDGE_SCOPES)}")
                continue
            absent = sorted(p for p in cited_paths(record) if not (root / p).exists())
            if scope == "repo" and absent:
                problems.append(f"{rid}: scope repo cites paths not in this repo: {', '.join(absent)} (fix them or scope it to the workbench)")
            if scope == "workbench" and status in UNSCOPED_CLAIMS:
                problems.append(f"{rid}: workbench record claims '{status}', which this repo cannot reproduce; write '{status}_on_workbench'")
    return problems


def check_knowledge_paths(gate):
    start = time.time()
    files = sorted((ROOT / "knowledge" / "records").glob("*.json"))
    problems = knowledge_problems(ROOT, files)
    gate.add("knowledge-paths", "FAIL" if problems else "PASS", "\n".join(problems), round(time.time() - start, 2))


def fixtures_readme_problems(root):
    """Every top-level fixtures/ entry is linked from fixtures/README.md (what consumes it)."""
    fixtures = Path(root) / "fixtures"
    readme = fixtures / "README.md"
    if not readme.exists():
        return ["fixtures/README.md is missing"]
    links, _, _ = markdown_scan(readme.read_text(encoding="utf-8"))
    linked = {target.split("#")[0].rstrip("/") for _, target in links}
    entries = sorted(p.name for p in fixtures.iterdir() if p.name != "README.md" and not p.name.startswith("."))
    return [f"fixtures/{name}: not described in fixtures/README.md" for name in entries if name not in linked]


def check_fixtures_readme(gate):
    start = time.time()
    problems = fixtures_readme_problems(ROOT)
    gate.add("fixtures-readme", "FAIL" if problems else "PASS", "\n".join(problems), round(time.time() - start, 2))


PROVENANCE = ROOT / "assets" / "provenance.json"
APPROVALS = {"approved", "research_citation", "rejected"}
PROVENANCE_FIELDS = ["kind", "name", "source", "license", "approval", "date", "purpose", "origin"]
# Real Roblox asset ids: rbxassetid:// and rbxthumb:// content ids, roblox.com URLs naming an asset,
# place, bundle, badge or pass, and numeric AssetId/MeshId/TextureId-style fields. 0 is the placeholder.
ASSET_ID_PATTERNS = [
    re.compile(r"rbxassetid://(\d+)", re.IGNORECASE),
    re.compile(r"rbxthumb://[^\s\"'<>]*?\bid=(\d+)", re.IGNORECASE),
    re.compile(
        r"https?://(?:[a-z0-9-]+\.)*roblox\.com/(?:[a-z-]+/)*?"
        r"(?:asset|library|catalog|bundles|badges|game-pass|games|marketplace/asset|store/asset)/(\d+)",
        re.IGNORECASE,
    ),
    re.compile(r"https?://(?:[a-z0-9-]+\.)*roblox\.com/[^\s\"'<>]*?[?&](?:id|assetid)=(\d+)", re.IGNORECASE),
    re.compile(r"\b(?:asset|mesh|texture|sound|animation|image|decal)_?id\b[\"']?\s*[:=]\s*[\"']?(\d+)\b", re.IGNORECASE),
]
CONTENT_SUFFIXES = (".luau", ".lua", ".rbxmx", ".rbxlx", ".project.json", ".model.json", ".meta.json")


def asset_ids_in(text):
    hits = set()
    for regex in ASSET_ID_PATTERNS:
        for match in regex.finditer(text):
            hits.add((text.count("\n", 0, match.start()) + 1, int(match.group(1))))
    return sorted(hits)


def provenance_problems(data):
    problems, seen = [], set()
    entries = data.get("assets") if isinstance(data, dict) else None
    if not isinstance(entries, list):
        return ["assets/provenance.json: needs an \"assets\" list"]
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            problems.append(f"assets[{index}]: an entry must be an object")
            continue
        aid = entry.get("id")
        label = f"assets[{index}] id {aid}"
        if not isinstance(aid, int) or isinstance(aid, bool) or aid <= 0:
            problems.append(f"{label}: id must be a positive integer")
        elif aid in seen:
            problems.append(f"{label}: duplicate id")
        seen.add(aid)
        missing = [f for f in PROVENANCE_FIELDS if not str(entry.get(f, "")).strip()]
        if missing:
            problems.append(f"{label}: missing {', '.join(missing)}")
        if entry.get("approval") not in APPROVALS:
            problems.append(f"{label}: approval must be one of {sorted(APPROVALS)}")
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(entry.get("date", ""))):
            problems.append(f"{label}: date must be YYYY-MM-DD")
        if entry.get("approval") == "approved" and not (str(entry.get("reviewer", "")).strip() and str(entry.get("script_review", "")).strip()):
            problems.append(f"{label}: an approved asset needs reviewer and script_review (skill roblox-asset-intake)")
    return problems


def asset_provenance_problems(root, paths, data, registry_path):
    """Every non-zero asset id in the given files is registered; only approved ids appear in place content."""
    root = Path(root).resolve()
    problems = provenance_problems(data)
    registry = {e.get("id"): e for e in data.get("assets", []) if isinstance(e, dict)} if isinstance(data, dict) else {}
    for path in paths:
        path = Path(path).resolve()
        if path == Path(registry_path).resolve() or path.stat().st_size > SECRET_SCAN_MAX_BYTES:
            continue
        raw = path.read_bytes()
        if b"\0" in raw[:8192]:
            continue  # binary
        rel = rel_posix(path, root)
        for line, aid in asset_ids_in(raw.decode("utf-8", errors="ignore")):
            entry = registry.get(aid)
            if aid == 0:
                continue
            if entry is None:
                problems.append(f"{rel}:{line}: asset id {aid} is not registered in assets/provenance.json (register it, or use 0 as the placeholder)")
            elif rel.endswith(CONTENT_SUFFIXES) and entry.get("approval") != "approved":
                problems.append(f"{rel}:{line}: asset id {aid} is '{entry.get('approval')}'; only approved assets may appear in place content")
    return problems


def check_asset_provenance(gate):
    start = time.time()
    try:
        data = json.loads(PROVENANCE.read_text(encoding="utf-8"))
    except (OSError, ValueError) as err:
        gate.add("asset-provenance", "FAIL", f"assets/provenance.json could not be read: {err}")
        return
    paths = committable_files()  # every non-binary file, like the secret scan
    problems = asset_provenance_problems(ROOT, paths, data, PROVENANCE)
    detail = problems or [f"{len(paths)} files scanned, {len(data.get('assets', []))} registered ids"]
    gate.add("asset-provenance", "FAIL" if problems else "PASS", "\n".join(detail), round(time.time() - start, 2))


def sourcemap_files(node, base, root):
    """Repo-relative posix paths of every file in a `rojo sourcemap` tree."""
    found = set()
    for raw in node.get("filePaths", []):
        raw = raw[4:] if raw.startswith("\\\\?\\") else raw  # Windows verbatim prefix (rojo < 7.7.1)
        path = Path(os.path.normpath(Path(base) / raw))
        if inside(path, root):
            found.add(rel_posix(path, root))
    for child in node.get("children", []):
        found |= sourcemap_files(child, base, root)
    return found


def check_rojo_sourcemap(gate):
    if shutil.which("rojo") is None:
        gate.add("rojo-sourcemap", "SKIPPED", "rojo not installed")
        return
    start = time.time()
    code, version, _ = run(["rojo", "--version"], timeout=60)
    if code != 0:  # e.g. an Aftman shim ahead of Rokit on PATH (gap matrix T09)
        gate.add("rojo-sourcemap", "FAIL", f"the rojo on PATH does not run (`rojo --version` exit {code}): {version}")
        return
    root = ROOT.resolve()
    reached, problems, notes = set(), [], []
    projects = sorted((ROOT / "fixtures").glob("*.project.json"))
    code, out, _ = run([sys.executable, "tools/network_manifest.py"])  # network.project.json reads it from build/
    if code != 0:
        problems.append(f"network manifest: {headline(out)}")
    for project in projects:
        try:
            proc = subprocess.run(["rojo", "sourcemap", str(project), "--absolute"], cwd=ROOT, capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            problems.append(f"{project.name}: rojo sourcemap timed out")
            continue
        if proc.returncode != 0:
            why = [line.strip() for line in (proc.stderr + proc.stdout).splitlines() if "ERROR" in line or "$path:" in line]
            problems.append(f"{project.name}: rojo sourcemap failed: {' '.join(why[:2]) or proc.returncode}")
            continue
        reached |= sourcemap_files(json.loads(proc.stdout), project.parent, root)
    luau = [rel_posix(p) for p in committable_files() if p.suffix == ".luau"]
    orphans = sorted(p for p in luau if p.startswith(("packages/", "fixtures/")) and p not in reached)
    problems += [f"{p}: not reachable from any fixtures/*.project.json" for p in orphans]
    notes.append(f"{len(projects)} projects, {len(reached)} mapped files")
    gate.add("rojo-sourcemap", "FAIL" if problems else "PASS", "\n".join(notes + problems), round(time.time() - start, 2))


def check_gate_selftest(gate):
    """Feed every content check a deliberately broken input: a check that accepts one is itself broken."""
    start = time.time()
    failures = []

    def expect(name, problems, wanted, unwanted=()):
        for needle in wanted:
            if not any(needle in p for p in problems):
                failures.append(f"{name}: accepted a broken input (no problem mentions {needle!r}): {problems}")
        for needle in unwanted:
            if any(needle in p for p in problems):
                failures.append(f"{name}: false positive on {needle!r}: {problems}")

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "docs").mkdir()
        good = root / "docs" / "good.md"
        good.write_text("# Title\n\n## Second part\n\n<a id=\"pinned\"></a>\n", encoding="utf-8")
        bad = root / "docs" / "bad.md"
        bad.write_text(
            "# Self\n[a](good.md#second-part) [b](missing.md) [c](good.md#nope) [d](#self) [e](good.md#pinned)\n"
            "[f](../../outside.md) [g](file:///etc/hosts) see https://exa mple.com and `[h](in-code.md)`\n"
            "```\n[i](in-fence.md)\n```\n[ref]: missing-ref.md\nhttps://x.org/{a,b} `https://x.org/{in,code}` https://x.org/a%20b\n",
            encoding="utf-8",
        )
        problems, _ = doc_link_problems(root, [bad, good])
        expect(
            "doc-links",
            problems,
            ["missing.md", "#nope", "outside.md", "file:", "https://exa", "missing-ref.md", "x.org/{a,b}"],
            ["second-part", "#self", "#pinned", "in-code.md", "in-fence.md", "{in,code}", "a%20b"],
        )

        registry_path = root / "assets" / "provenance.json"
        cited = {"id": 1111111, "kind": "model", "name": "n", "source": "s", "license": "l", "approval": "research_citation", "date": "2026-01-01", "purpose": "p", "origin": "o"}
        registry = {"assets": [cited, {**cited, "id": 2222222, "approval": "approved"}, {**cited, "id": 5555555, "license": ""}]}
        place = root / "Place.luau"
        place.write_text('local a = "rbxassetid://' + '3333333"\nlocal b = "rbxassetid://' + '1111111"\nlocal c = "rbxassetid://0"\n', encoding="utf-8")
        notes = root / "notes.md"
        notes.write_text("https://www.roblox.com/library/" + "1111111/x and Mesh" + "Id = 4444444\n", encoding="utf-8")
        problems = asset_provenance_problems(root, [place, notes], registry, registry_path)
        expect(
            "asset-provenance",
            problems,
            ["asset id 3333333 is not registered", "Place.luau:2: asset id 1111111", "4444444", "2222222: an approved asset needs", "5555555: missing license"],
            ["notes.md:1: asset id 1111111", "asset id 0 "],
        )

        record = {"id": "r-repo", "title": "t", "status": "verified", "scope": "repo", "scope_note": "n", "artifacts": ["tools/nope.py"]}
        (root / "records.json").write_text(
            json.dumps(
                [
                    record,
                    {**record, "id": "r-workbench", "scope": "workbench", "artifacts": []},
                    {**record, "id": "r-unscoped", "scope": "", "scope_note": ""},
                    {**record, "id": "r-ok", "scope": "workbench", "status": "verified_on_workbench"},
                    {**record, "id": "r-ok", "scope": "workbench", "status": "researched_only"},
                ]
            ),
            encoding="utf-8",
        )
        problems = knowledge_problems(root, [root / "records.json"])
        expect(
            "knowledge-paths",
            problems,
            ["r-repo: scope repo cites paths not in this repo: tools/nope.py", "r-workbench: workbench record claims 'verified'", "r-unscoped: missing scope", "r-ok: duplicate id"],
            ["r-ok: scope repo", "r-ok: workbench record"],
        )

        (root / "fixtures" / "kept").mkdir(parents=True)
        (root / "fixtures" / "orphan.json").write_text("{}", encoding="utf-8")
        (root / "fixtures" / "README.md").write_text("[kept](kept/)\n", encoding="utf-8")
        expect("fixtures-readme", fixtures_readme_problems(root), ["fixtures/orphan.json"], ["fixtures/kept"])

        tree = {"filePaths": ["x.project.json"], "children": [{"filePaths": ["../packages/A.luau"]}, {"filePaths": ["../../elsewhere.luau"]}]}
        mapped = sourcemap_files(tree, root / "fixtures", root)
        if mapped != {"fixtures/x.project.json", "packages/A.luau"}:
            failures.append(f"rojo-sourcemap: sourcemap paths resolved to {sorted(mapped)}")

        # --update-golden scoping: bare means all, names are validated, and the specs see only spec names.
        stray = {"PATH": "p", GOLDEN_ENV: "1"}
        scoped = golden_scope("fixture-hashes, gamekit_fsm,ui.layout")
        checks = {
            "absent flag is no update": golden_scope(None) is None and not golden_updates(None, "fixture-hashes"),
            "bare flag is all": golden_scope("all") == "all" and golden_updates("all", "studio-smoke"),
            "names parsed": scoped == frozenset({"fixture-hashes", "gamekit_fsm", "ui.layout"}),
            "scoped update": golden_updates(scoped, "fixture-hashes") and not golden_updates(scoped, "studio-smoke"),
            "stray variable removed": golden_env(None, stray) == {"PATH": "p"},
            "all sets 1": golden_env("all", {})[GOLDEN_ENV] == "1",
            "specs see spec names": golden_env(scoped, stray)[GOLDEN_ENV] == "gamekit_fsm,ui.layout",
            "gate names stay out": GOLDEN_ENV not in golden_env(frozenset({"fixture-hashes"}), stray),
        }
        failures.extend(f"golden-scope: {label}" for label, ok in checks.items() if not ok)
        for broken in ("", "a,,b", "../x", "Bad", "a b", "fixture-hashes,"):
            try:
                golden_scope(broken)
                failures.append(f"golden-scope: accepted a broken input {broken!r}")
            except ValueError:
                pass
        problems, note = golden_report(scoped, {"gamekit_fsm": b"1"}, {"gamekit_fsm": b"2", "fixture-hashes": b"x"})
        expect("golden-update", problems, ["ui.layout.json was not written"], ["gamekit_fsm.json was not"])
        if note != "added: fixture-hashes; rewrote: gamekit_fsm":
            failures.append(f"golden-update: note {note!r}")
    gate.add("gate-selftest", "FAIL" if failures else "PASS", "\n".join(failures), round(time.time() - start, 2))


def blender_cmd():
    if importlib.util.find_spec("bpy") is not None:
        return [sys.executable, "tools/blender/factory.py"]
    if shutil.which("blender"):
        return ["blender", "-b", "--python", "tools/blender/factory.py", "--"]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", default="pre-commit", choices=["fast", "pre-commit", "pre-release"])
    ap.add_argument("--strict", action="store_true", help="count SKIPPED steps as failures (CI)")
    ap.add_argument(
        "--update-golden", nargs="?", const="all", default=None, metavar="NAME,...",
        help="rewrite goldens: all when bare, else only the named ones (fixture-hashes, studio-smoke, spec golden names)",
    )
    ap.add_argument("--install-git-hook", action="store_true")
    ap.add_argument("--live-links", action="store_true", help="also request every external URL (opt-in; never in CI)")
    ap.add_argument("--allow-skip", action="append", default=[], metavar="STEP", help="let a SKIPPED step (name or glob) pass; selene always may, except with --strict")
    args = ap.parse_args()
    try:
        scope = golden_scope(args.update_golden)
    except ValueError as err:
        ap.error(str(err))
    os.environ.pop(GOLDEN_ENV, None)  # only an explicit --update-golden may rewrite a golden
    if args.install_git_hook:
        hook = ROOT / ".git" / "hooks" / "pre-commit"
        # Default verdict: any SKIPPED step except selene fails the commit (a missing core tool is not a pass).
        hook.write_text("#!/bin/sh\n# Installed by tools/check.py --install-git-hook.\nexec python3 tools/check.py --tier pre-commit\n")
        hook.chmod(0o755)
        print("installed", hook)
        return 0

    gate = Gate()
    gate.cmd("stylua", ["stylua", "--check", "packages", "tests", "tools/lune", "fixtures"], needs="stylua")
    check_json(gate)
    check_secrets(gate)
    if args.tier in ("pre-commit", "pre-release"):
        gate.cmd("skills-sync", [sys.executable, "tools/sync_skills.py", "--check"])
        gate.cmd("gap-matrix", [sys.executable, "tools/gap_matrix.py", "--check"])
        # Content checks (doc links, knowledge records, fixtures README, asset provenance, Rojo sourcemaps).
        check_doc_links(gate, live=args.live_links)
        gate.cmd("knowledge-index", [sys.executable, "tools/knowledge_index.py", "--check"])
        check_knowledge_paths(gate)
        check_fixtures_readme(gate)
        check_asset_provenance(gate)
        check_rojo_sourcemap(gate)
        check_gate_selftest(gate)
        selftest_env = {**os.environ, "FACTORY_PYTHON": sys.executable}  # secret-pattern parity check
        gate.cmd("hooks-selftest", ["node", "tools/hooks/selftest.mjs"], needs="node", env=selftest_env)
        check_selene(gate)
        before = golden_snapshot()
        if golden_updates(scope, "studio-smoke"):  # tests/scenekit.spec.luau checks it, so rewrite it before the specs
            gate.cmd("studio-smoke-golden", ["lune", "run", "tools/lune/smoke_hashes.luau"], needs="lune")
        gate.cmd("lune-specs", ["lune", "run", "tests/run.luau"], needs="lune", env=golden_env(scope, os.environ))
        for script in INHERITED_SPECS:  # the first pass's own Lune suites, re-run here
            gate.cmd(f"inherited-{Path(script).parent.name}-{Path(script).stem}", ["lune", "run", script], needs="lune")
        check_fixtures(gate, golden_updates(scope, "fixture-hashes"))
        # Python tools' unit tests, then the data checks the kits and playbooks rely on.
        gate.cmd("python-unit", [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"], timeout=900)
        gate.cmd("playbook-lint", [sys.executable, "tools/playbook_lint.py"])
        gate.cmd("asset-sources", [sys.executable, "tools/asset_sources.py", "--check"])
        gate.cmd("luau-defs-lock", [sys.executable, "tools/luau_defs.py", "--check-lock"])
        gate.cmd("kit-tiers", [sys.executable, "tools/kit_tiers.py", "--check"])
        gate.cmd("capture-staleness", [sys.executable, "tools/capture_staleness.py"])  # lists STALE records; fails only on INVALID
        if scope is not None:
            problems, note = golden_report(scope, before, golden_snapshot())
            gate.add("golden-update", "FAIL" if problems else "PASS", "\n".join([note] + problems))  # headline: a problem
        check_starter(gate, args.strict)
    elif scope is not None:  # the fast tier runs no golden step, so the flag would silently do nothing
        gate.add("golden-update", "FAIL", "--update-golden needs --tier pre-commit or pre-release")
    if args.tier == "pre-release":
        blender = blender_cmd()
        if blender is None:
            gate.add("blender", "SKIPPED", "no bpy module or blender executable")
        else:
            gate.cmd("blender-templates", blender + ["templates", "build/blender"], timeout=3000)
            gate.cmd("blender-roundtrip", blender + ["roundtrip", "build/roundtrip"], timeout=900)
            gate.cmd("blender-qa-selftest", blender + ["qa-selftest", "build/qa-selftest"], timeout=900)
            gate.cmd("material-library", blender + ["textures", "assets/material-library.json", "--out", "build/material-library-check.json"], timeout=300)
            kit = ["kit", "--templates", "pickup,checkpoint_gate,obby_platform_set", "--out", "build/kit/kit.json", "--library", "assets/material-library.json"]
            gate.cmd("blender-kit", blender + kit, timeout=900)
            glbs = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "build/blender").glob("*/*.glb"))
            gate.cmd("gltf-validate-templates", [sys.executable, "tools/gltf_validate.py", *glbs])
            courses = ("course_linear", "course_tower", "course_race_loop", "course_lanes", "course_micro_arena")
            for fixture in ("modular_building", "dungeon", "settlement", "forest", *courses):
                manifest = f"build/fixtures/{fixture}.manifest.json"
                gate.cmd(f"preview-{fixture}", blender + ["render-manifest", manifest, "build/previews"], timeout=900)
        # Luau type analysis against the pinned Roblox definitions; exit 3 means luau-lsp or rojo is absent.
        gate.cmd("luau-lsp-analyze", [sys.executable, "tools/luau_analyze.py"], timeout=900, skip_codes=(3,))
        gate.cmd("starter-smoke-full", [sys.executable, "tools/starter_smoke.py", *(["--strict"] if args.strict else [])], timeout=900, skip_codes=(3,))

    failed = [r["name"] for r in gate.results if r["status"] == "FAIL"]
    skipped = [r["name"] for r in gate.results if r["status"] == "SKIPPED"]
    allowed = [] if args.strict else sorted(ALLOWED_SKIPS | set(args.allow_skip))
    blocking = [name for name in skipped if not any(fnmatch.fnmatchcase(name, pattern) for pattern in allowed)]
    passed = not failed and not blocking
    (ROOT / "build").mkdir(exist_ok=True)
    report = {
        "tier": args.tier,
        "strict": args.strict,
        "pass": passed,
        "failed": failed,
        "skipped": skipped,
        "allowed_skips": allowed,
        "results": gate.results,
    }
    (ROOT / "build" / "check-report.json").write_text(json.dumps(report, indent=2))
    why = ""
    if blocking:
        why = " (strict: skipped steps count as failures)" if args.strict else f" (skipped steps {blocking} count as failures: install the tool, or pass --allow-skip <step>)"
    print(f"\n{args.tier}: {'PASS' if passed else 'FAIL'}{why}; failed={failed} skipped={skipped}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
