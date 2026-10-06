"""Validate assets/sources.json (asset-sources/1) and the source links in assets/provenance.json.

  python3 tools/asset_sources.py --check [assets/sources.json] [assets/provenance.json]

Offline; reads only. Rules:
- sources.json: schema asset-sources/1; at most 12 sources; each a lower-case key, CC0-1.0 only, an https
  licence_url, a licence_text_sha256 equal to licence_texts[CC0-1.0].sha256, attribution, redistributable
  true, commit fetch-only, a retrieval method (https-get with an allow-listed host and a path holding
  {item}, or manual with an https page), an item_pattern that compiles, allowed_types from the known set,
  member_types as .ext names, a max_bytes cap. No string anywhere may name api.polyhaven.com.
- provenance.json: an optional source_key on an assets entry must name a source; every files entry names a
  source, an item matching its pattern (no '..'), sha256 (64 hex) and bytes, licence CC0-1.0 with the
  source's licence_text_sha256, a YYYY-MM-DD date, approval pinned; (source_key, item) is unique.
- Nothing but JSON and Markdown is committed under assets/ (every source is fetch-only).
Exit 0 when clean, 1 with problems, 2 on unreadable input.
"""
import argparse
import json
import re
import sys
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "assets" / "sources.json"
PROVENANCE = ROOT / "assets" / "provenance.json"
SCHEMA = "asset-sources/1"
MAX_SOURCES = 12
LICENCES = {"CC0-1.0"}
KEY = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
MEMBER_TYPE = re.compile(r"^\.[a-z0-9]{1,8}$")
KINDS = {"texture-set", "hdri", "model", "audio", "ui"}
FILE_TYPES = {"zip", "png", "jpg", "hdr", "exr", "ogg", "wav", "glb"}
# Hosts a download may come from (plus raw.githubusercontent.com for licence texts). Never the Poly Haven API.
DOWNLOAD_HOSTS = {"ambientcg.com", "dl.polyhaven.org", "kenney.nl"}
LICENCE_HOSTS = {"raw.githubusercontent.com"}
FORBIDDEN = "api.polyhaven.com"
MAX_BYTES = 2 * 1024 ** 3
COMMITTED_OK = {".json", ".md"}


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield str(key)
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def https_url(value, hosts=None, allow_file=False):
    if not isinstance(value, str):
        return False
    parts = urllib.parse.urlsplit(value)
    if allow_file and parts.scheme == "file":
        return True
    return parts.scheme == "https" and bool(parts.hostname) and (hosts is None or parts.hostname in hosts)


def sources_problems(doc, allow_file_urls=False):
    """Problems with a parsed sources.json (empty when valid)."""
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return [f"sources: schema must be {SCHEMA}"]
    problems = []
    if any(FORBIDDEN in text for text in strings(doc)):
        problems.append(f"sources: {FORBIDDEN} must never appear (its terms forbid commercial use)")
    texts = doc.get("licence_texts")
    if not isinstance(texts, dict):
        problems.append("licence_texts must map a licence id to {url, sha256, bytes}")
        texts = {}
    for licence, entry in texts.items():
        where = f"licence_texts.{licence}"
        if licence not in LICENCES:
            problems.append(f"{where}: only {sorted(LICENCES)} is allowed")
        if not isinstance(entry, dict):
            problems.append(f"{where}: must be an object")
            continue
        if not https_url(entry.get("url"), LICENCE_HOSTS, allow_file_urls):
            problems.append(f"{where}: url must be https on {sorted(LICENCE_HOSTS)} (a commit-pinned legal code text)")
        if not isinstance(entry.get("sha256"), str) or not HEX64.match(entry["sha256"]):
            problems.append(f"{where}: sha256 must be 64 lower-case hex digits")
        if not isinstance(entry.get("bytes"), int) or isinstance(entry.get("bytes"), bool) or entry["bytes"] <= 0:
            problems.append(f"{where}: bytes must be a positive integer")
    sources = doc.get("sources")
    if not isinstance(sources, list) or not sources:
        return problems + ["sources must be a non-empty list"]
    if len(sources) > MAX_SOURCES:
        problems.append(f"sources: at most {MAX_SOURCES} candidates (got {len(sources)})")
    keys = set()
    for index, source in enumerate(sources):
        where = f"sources[{index}]"
        if not isinstance(source, dict):
            problems.append(f"{where}: must be an object")
            continue
        key = source.get("key")
        if not isinstance(key, str) or not KEY.match(key):
            problems.append(f"{where}: key must be a lower-case label")
        elif key in keys:
            problems.append(f"{where}: duplicate key {key}")
        else:
            where = f"sources.{key}"
        keys.add(key)
        for field in ("name", "api_terms", "notes"):
            if not isinstance(source.get(field), str) or not source[field].strip():
                problems.append(f"{where}: {field} is required")
        kinds = source.get("kinds")
        if not isinstance(kinds, list) or not kinds or any(k not in KINDS for k in kinds):
            problems.append(f"{where}: kinds must be a non-empty list from {sorted(KINDS)}")
        if not https_url(source.get("homepage")):
            problems.append(f"{where}: homepage must be an https URL")
        licence = source.get("licence")
        if licence not in LICENCES:
            problems.append(f"{where}: licence {licence!r} is not allowed; only {sorted(LICENCES)}")
        if not https_url(source.get("licence_url")):
            problems.append(f"{where}: licence_url must be an https URL")
        expected = texts.get(licence, {}).get("sha256") if isinstance(texts.get(licence), dict) else None
        if source.get("licence_text_sha256") != expected or expected is None:
            problems.append(f"{where}: licence_text_sha256 must equal licence_texts.{licence}.sha256")
        if source.get("attribution") != "none":
            problems.append(f"{where}: attribution must be none for CC0")
        if source.get("redistributable") is not True:
            problems.append(f"{where}: redistributable must be true for CC0")
        if source.get("commit") != "fetch-only":
            problems.append(f"{where}: commit must be fetch-only (nothing fetched goes into git)")
        problems += [f"{where}: {p}" for p in retrieval_problems(source.get("retrieval"), allow_file_urls)]
        types = source.get("allowed_types")
        if not isinstance(types, list) or not types or any(t not in FILE_TYPES for t in types):
            problems.append(f"{where}: allowed_types must be a non-empty list from {sorted(FILE_TYPES)}")
        members = source.get("member_types")
        if not isinstance(members, list) or any(not isinstance(m, str) or not MEMBER_TYPE.match(m) for m in members):
            problems.append(f"{where}: member_types must be a list of .ext names")
        elif "zip" in (types or []) and not members:
            problems.append(f"{where}: an archive source needs member_types")
        size = source.get("max_bytes")
        if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= MAX_BYTES:
            problems.append(f"{where}: max_bytes must be a positive integer up to {MAX_BYTES}")
    return problems


def retrieval_problems(retrieval, allow_file_urls=False):
    if not isinstance(retrieval, dict):
        return ["retrieval must be an object"]
    problems = []
    method = retrieval.get("method")
    pattern = retrieval.get("item_pattern")
    try:
        if not isinstance(pattern, str) or not pattern.startswith("^") or not pattern.endswith("$"):
            raise re.error("anchor it with ^...$")
        re.compile(pattern)
    except re.error as err:
        problems.append(f"retrieval.item_pattern must be an anchored regular expression ({err})")
    if method == "https-get":
        host = retrieval.get("host")
        if host not in DOWNLOAD_HOSTS and not (allow_file_urls and host == "fixtures.invalid"):
            problems.append(f"retrieval.host must be one of {sorted(DOWNLOAD_HOSTS)}")
        path = retrieval.get("path")
        if not isinstance(path, str) or not path.startswith("/") or path.count("{item}") != 1:
            problems.append("retrieval.path must start with / and hold {item} once")
        redirects = retrieval.get("redirect_hosts", [])
        if not isinstance(redirects, list) or any(not isinstance(h, str) or not re.fullmatch(r"[a-z0-9.-]+\.[a-z]{2,}", h) for h in redirects):
            problems.append("retrieval.redirect_hosts must be a list of host names")
        elif FORBIDDEN in redirects:
            problems.append(f"retrieval.redirect_hosts must not include {FORBIDDEN}")
    elif method == "manual":
        if not https_url(retrieval.get("page")):
            problems.append("retrieval.page must be an https URL (where the owner downloads by hand)")
    else:
        problems.append("retrieval.method must be https-get or manual")
    return problems


def item_problem(source, item):
    """Why an item id is not acceptable for a source, or None."""
    if not isinstance(item, str) or not item or len(item) > 200:
        return "item must be a non-empty string of at most 200 characters"
    if ".." in item or item.startswith("/") or "\\" in item or any(ord(c) < 33 for c in item):
        return "item must not contain '..', a leading '/', backslashes, spaces or control characters"
    pattern = (source.get("retrieval") or {}).get("item_pattern")
    if not isinstance(pattern, str) or not re.fullmatch(pattern, item):
        return f"item {item!r} does not match {source.get('key')} item_pattern {pattern}"
    return None


def provenance_problems(doc, sources_doc):
    """Problems with the source links in a parsed provenance.json."""
    if not isinstance(doc, dict):
        return ["provenance: must be an object"]
    by_key = {s.get("key"): s for s in sources_doc.get("sources", []) if isinstance(s, dict)} if isinstance(sources_doc, dict) else {}
    problems = []
    for index, entry in enumerate(doc.get("assets") or []):
        if isinstance(entry, dict) and "source_key" in entry and entry["source_key"] not in by_key:
            problems.append(f"assets[{index}] id {entry.get('id')}: source_key {entry['source_key']!r} is not in assets/sources.json")
    files = doc.get("files", [])
    if not isinstance(files, list):
        return problems + ["provenance: files must be a list"]
    seen = set()
    for index, entry in enumerate(files):
        where = f"files[{index}]"
        if not isinstance(entry, dict):
            problems.append(f"{where}: must be an object")
            continue
        source = by_key.get(entry.get("source_key"))
        if source is None:
            problems.append(f"{where}: source_key {entry.get('source_key')!r} is not in assets/sources.json")
            continue
        why = item_problem(source, entry.get("item"))
        if why:
            problems.append(f"{where}: {why}")
        pair = (entry.get("source_key"), entry.get("item"))
        if pair in seen:
            problems.append(f"{where}: {pair[0]}:{pair[1]} is pinned twice")
        seen.add(pair)
        if not isinstance(entry.get("sha256"), str) or not HEX64.match(entry["sha256"]):
            problems.append(f"{where}: sha256 must be 64 lower-case hex digits")
        if not isinstance(entry.get("bytes"), int) or isinstance(entry.get("bytes"), bool) or entry["bytes"] <= 0:
            problems.append(f"{where}: bytes must be a positive integer")
        if entry.get("type") not in source.get("allowed_types", []):
            problems.append(f"{where}: type {entry.get('type')!r} is not one of {source.get('key')} allowed_types")
        if entry.get("licence") != source.get("licence") or entry.get("licence") not in LICENCES:
            problems.append(f"{where}: licence must be {source.get('licence')} (the source's CC0 licence)")
        if entry.get("licence_text_sha256") != source.get("licence_text_sha256"):
            problems.append(f"{where}: licence_text_sha256 differs from the source's pinned legal code text")
        url = entry.get("url")
        if not (isinstance(url, str) and (url.startswith("https://") or url.startswith("manual:"))):
            problems.append(f"{where}: url must be https://... or manual:<page>")
        elif FORBIDDEN in url:
            problems.append(f"{where}: {FORBIDDEN} is never a source")
        if not isinstance(entry.get("date"), str) or not DATE.match(entry["date"]):
            problems.append(f"{where}: date must be YYYY-MM-DD")
        if entry.get("approval") != "pinned":
            problems.append(f"{where}: approval must be pinned")
        if not isinstance(entry.get("purpose"), str) or not entry["purpose"].strip():
            problems.append(f"{where}: purpose is required")
    return problems


def committed_file_problems(assets_dir):
    """Files under assets/ other than JSON and Markdown (every source is fetch-only)."""
    problems = []
    base = Path(assets_dir)
    if base.is_dir():
        for path in sorted(p for p in base.rglob("*") if p.is_file()):
            if path.suffix.lower() not in COMMITTED_OK:
                problems.append(f"{path.relative_to(base.parent).as_posix()}: only JSON and Markdown live under assets/; fetched files stay in build/asset-cache/")
    return problems


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="validate (the only mode; kept explicit for the gate)")
    ap.add_argument("sources", nargs="?", default=str(SOURCES))
    ap.add_argument("provenance", nargs="?", default=str(PROVENANCE))
    ap.add_argument("--allow-file-urls", action="store_true", help=argparse.SUPPRESS)  # tests only
    args = ap.parse_args(argv)
    try:
        sources_doc = load(args.sources)
        provenance_doc = load(args.provenance)
    except (OSError, ValueError) as err:
        print(f"asset_sources: cannot read input: {err}")
        return 2
    problems = sources_problems(sources_doc, args.allow_file_urls)
    problems += provenance_problems(provenance_doc, sources_doc)
    problems += committed_file_problems(Path(args.sources).resolve().parent)
    for problem in problems:
        print(f"PROBLEM {problem}")
    files = provenance_doc.get("files", []) if isinstance(provenance_doc, dict) else []
    print(f"asset_sources: {len(sources_doc.get('sources', []))} sources, {len(files) if isinstance(files, list) else 0} pinned files, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
