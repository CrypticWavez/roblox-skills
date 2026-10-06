"""Pinned Roblox type definitions and API docs for luau-lsp.

  python3 tools/luau_defs.py               fetch what is missing or wrong into build/luau-lsp/, verify sha256
  python3 tools/luau_defs.py --verify      offline: the cached files exist and match the lock (exit 1 if not)
  python3 tools/luau_defs.py --check-lock  offline: luau-defs.lock.json is well formed (gate-friendly)
  python3 tools/luau_defs.py --print       print the cached file paths (for editor or plugin settings)

The lock (luau-defs.lock.json) pins one luau-lsp commit and the sha256 and size of each file at that
commit. A download goes to a temporary file, is checked against size and sha256, and only then
replaces the cache entry; a mismatch is refused and nothing is kept. Files come only from
raw.githubusercontent.com URLs that contain the pinned commit. The cache is gitignored: nothing
fetched here is committed. Stdlib only; never runs anything it downloads.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "luau-defs.lock.json"
CACHE = ROOT / "build" / "luau-lsp"
SCHEMA = "luau-defs-lock/1"
ALLOWED_HOSTS = {"raw.githubusercontent.com"}
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
ROLES = {"definitions", "docs"}
MAX_BYTES = 64 * 1024 * 1024


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def lock_problems(lock, allow_file_urls=False):
    """Problems with a parsed lock (empty when it is usable)."""
    if not isinstance(lock, dict) or lock.get("schema") != SCHEMA:
        return [f"lock: schema must be {SCHEMA!r}"]
    problems = []
    meta = lock.get("luau_lsp")
    commit = meta.get("commit") if isinstance(meta, dict) else None
    if not isinstance(commit, str) or not HEX40.match(commit):
        problems.append("luau_lsp.commit must be a 40-hex commit id")
        commit = None
    if not isinstance(meta, dict) or not str(meta.get("version", "")).strip():
        problems.append("luau_lsp.version is required")
    files = lock.get("files")
    if not isinstance(files, list) or not files:
        return problems + ["files must be a non-empty list"]
    names, roles = set(), []
    for index, entry in enumerate(files):
        where = f"files[{index}]"
        if not isinstance(entry, dict):
            problems.append(f"{where}: must be an object")
            continue
        name = entry.get("name")
        if not isinstance(name, str) or not NAME_RE.match(name) or name in (".", ".."):
            problems.append(f"{where}: name must be a plain file name")
        elif name in names:
            problems.append(f"{where}: duplicate name {name}")
        names.add(name)
        if entry.get("role") not in ROLES:
            problems.append(f"{where}: role must be one of {sorted(ROLES)}")
        roles.append(entry.get("role"))
        if not isinstance(entry.get("sha256"), str) or not HEX64.match(entry["sha256"]):
            problems.append(f"{where}: sha256 must be 64 lower-case hex digits")
        size = entry.get("bytes")
        if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= MAX_BYTES:
            problems.append(f"{where}: bytes must be a positive integer up to {MAX_BYTES}")
        url = entry.get("url")
        parts = urllib.parse.urlsplit(url) if isinstance(url, str) else None
        if parts is None:
            problems.append(f"{where}: url is required")
        elif parts.scheme == "file" and allow_file_urls:
            pass
        elif parts.scheme != "https" or parts.hostname not in ALLOWED_HOSTS:
            problems.append(f"{where}: url must be https on {sorted(ALLOWED_HOSTS)}")
        elif commit and f"/{commit}/" not in parts.path:
            problems.append(f"{where}: url must name the pinned commit {commit}")
    if "definitions" not in roles:
        problems.append("files: one entry needs role 'definitions'")
    return problems


def load_lock(path=LOCK, allow_file_urls=False):
    lock = json.loads(Path(path).read_text(encoding="utf-8"))
    problems = lock_problems(lock, allow_file_urls)
    if problems:
        raise ValueError("; ".join(problems))
    return lock


def cached_state(lock, cache=CACHE):
    """[(entry, path, state)] with state 'ok', 'missing' or 'mismatch'."""
    rows = []
    for entry in lock["files"]:
        path = Path(cache) / entry["name"]
        if not path.is_file():
            state = "missing"
        elif path.stat().st_size != entry["bytes"] or sha256_file(path) != entry["sha256"]:
            state = "mismatch"
        else:
            state = "ok"
        rows.append((entry, path, state))
    return rows


def download(entry, dest, opener=urllib.request.urlopen, timeout=60):
    """Fetches entry['url'] into dest after checking size and sha256. Raises ValueError on a mismatch."""
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    digest, total = hashlib.sha256(), 0
    fd, tmp = tempfile.mkstemp(prefix=".download-", dir=dest.parent)
    try:
        with os.fdopen(fd, "wb") as out, opener(entry["url"], timeout=timeout) as response:
            while True:
                block = response.read(1 << 20)
                if not block:
                    break
                total += len(block)
                if total > entry["bytes"]:
                    raise ValueError(f"{entry['name']}: more than the pinned {entry['bytes']} bytes")
                digest.update(block)
                out.write(block)
        if total != entry["bytes"]:
            raise ValueError(f"{entry['name']}: got {total} bytes, the lock pins {entry['bytes']}")
        if digest.hexdigest() != entry["sha256"]:
            raise ValueError(f"{entry['name']}: sha256 {digest.hexdigest()} does not match the lock {entry['sha256']}")
        os.chmod(tmp, 0o644)  # mkstemp creates 0600; editors and the LSP read these
        os.replace(tmp, dest)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return dest


def fetch(lock, cache=CACHE, opener=urllib.request.urlopen, log=print):
    """Downloads every missing or mismatched file. Returns the problems (empty on success)."""
    problems = []
    for entry, path, state in cached_state(lock, cache):
        if state == "ok":
            log(f"ok       {entry['name']}")
            continue
        try:
            download(entry, path, opener)
            log(f"fetched  {entry['name']} ({entry['bytes']} bytes, sha256 verified)")
        except (OSError, ValueError) as err:
            problems.append(f"{entry['name']}: {err}")
    return problems


def paths(lock, cache=CACHE):
    """{role: path} of the cached files (the first file per role)."""
    found = {}
    for entry in lock["files"]:
        found.setdefault(entry["role"], Path(cache) / entry["name"])
    return found


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--verify", action="store_true", help="offline: check the cache against the lock")
    mode.add_argument("--check-lock", action="store_true", help="offline: check the lock file only")
    mode.add_argument("--print", action="store_true", help="print the cached file paths")
    ap.add_argument("--lock", default=str(LOCK), help=argparse.SUPPRESS)
    ap.add_argument("--cache", default=str(CACHE), help=argparse.SUPPRESS)
    ap.add_argument("--allow-file-urls", action="store_true", help=argparse.SUPPRESS)  # tests only
    args = ap.parse_args(argv)
    try:
        lock = load_lock(args.lock, args.allow_file_urls)
    except (OSError, ValueError) as err:
        print(f"FAIL luau-defs.lock.json: {err}")
        return 1
    if args.check_lock:
        print(f"ok luau-defs.lock.json: luau-lsp {lock['luau_lsp']['version']} at {lock['luau_lsp']['commit'][:12]}, {len(lock['files'])} files")
        return 0
    if args.print:
        for role, path in paths(lock, args.cache).items():
            print(f"{role}: {path}")
        return 0
    if args.verify:
        bad = [(entry["name"], state) for entry, _, state in cached_state(lock, args.cache) if state != "ok"]
        for name, state in bad:
            print(f"FAIL {name}: {state} (run python3 tools/luau_defs.py to fetch it)")
        if not bad:
            print(f"ok {len(lock['files'])} pinned files verified in {Path(args.cache).name}/")
        return 1 if bad else 0
    problems = fetch(lock, args.cache)
    for problem in problems:
        print(f"FAIL {problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
