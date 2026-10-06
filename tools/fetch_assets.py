"""Fetch one CC0 item from an assets/sources.json source into build/asset-cache/ and pin it in provenance.

  python3 tools/fetch_assets.py --list
  python3 tools/fetch_assets.py --source <key> --item <id>                         dry run (default)
  python3 tools/fetch_assets.py --source <key> --item <id> --pin --purpose "..."   fetch, verify, record
  python3 tools/fetch_assets.py --source kenney --item <slug> --from-file <zip> --pin --purpose "..."

A dry run touches no network and writes nothing: it prints the URL, the cache folder and whether the item
is already pinned. `--pin` is the owner's approval for this one item. It then:
1. refuses a source whose licence is not CC0-1.0, and an item that does not match the source's item_pattern;
2. downloads the CC0 legal code text named in licence_texts and refuses it unless its sha256 matches
   (the licence evidence recorded with the pin);
3. downloads the item over https from the source's allow-listed host (redirects only to the source's
   redirect_hosts), or, for a manual source, copies the file given with --from-file;
4. refuses more than the source's max_bytes, a file type outside allowed_types (checked by content) and,
   when the item is already pinned, any sha256 or size other than the pin;
5. stores it under build/asset-cache/<source>/<item>/ (gitignored, never committed); a zip is extracted into
   a fresh files/ folder, refusing absolute, '..' or symlink members and enforcing member-count and size
   caps; only member_types are extracted (the rest are listed as skipped) and nothing is ever executed;
   cache-manifest.json records a sha256 per extracted file;
6. appends a files entry to assets/provenance.json (source_key, item, url, sha256, bytes, type, licence,
   licence_url, licence_text_sha256, date, purpose, approval pinned). A machine path is never recorded.
Exit 0 on success, 1 when a download or check fails, 2 on refused or bad usage. Standard library only.
"""
import argparse
import datetime
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import asset_sources  # noqa: E402  (sibling tool)

CACHE = ROOT / "build" / "asset-cache"
USER_AGENT = "roblox-factory-fetch-assets/1 (one owner-requested file)"
MAX_MEMBERS = 5000
MAX_UNPACKED = 4 * 1024 ** 3
CHUNK = 1 << 20
MAGIC = (
    ("zip", lambda h: h.startswith(b"PK\x03\x04") or h.startswith(b"PK\x05\x06")),
    ("png", lambda h: h.startswith(b"\x89PNG\r\n\x1a\n")),
    ("jpg", lambda h: h.startswith(b"\xff\xd8\xff")),
    ("hdr", lambda h: h.startswith(b"#?RADIANCE") or h.startswith(b"#?RGBE")),
    ("exr", lambda h: h.startswith(b"\x76\x2f\x31\x01")),
    ("ogg", lambda h: h.startswith(b"OggS")),
    ("wav", lambda h: h.startswith(b"RIFF") and h[8:12] == b"WAVE"),
    ("glb", lambda h: h.startswith(b"glTF")),
)


class Refused(Exception):
    """The request is not allowed (exit 2)."""


class Failed(Exception):
    """A download or verification failed (exit 1)."""


def detect_type(path):
    with open(path, "rb") as handle:
        head = handle.read(16)
    for name, test in MAGIC:
        if test(head):
            return name
    return None


def relpath(path):
    try:
        return Path(path).resolve().relative_to(ROOT.resolve()).as_posix()
    except ValueError:
        return Path(path).name


class HostRedirects(urllib.request.HTTPRedirectHandler):
    """Follows a redirect only to https on an allowed host."""

    def __init__(self, hosts):
        super().__init__()
        self.hosts = set(hosts)

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parts = urllib.parse.urlsplit(newurl)
        if parts.scheme != "https" or parts.hostname not in self.hosts or asset_sources.FORBIDDEN in newurl:
            raise Failed(f"redirect to {parts.scheme}://{parts.hostname} is not on the source's allow-list")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url, dest, max_bytes, hosts, timeout=120):
    """Streams url into dest (a new file), refusing more than max_bytes. Returns (sha256, bytes)."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme == "https":
        if parts.hostname not in hosts:
            raise Refused(f"{parts.hostname} is not an allowed host")
    elif parts.scheme != "file":
        raise Refused(f"{url}: only https downloads are allowed")
    opener = urllib.request.build_opener(HostRedirects(hosts))
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    digest, total = hashlib.sha256(), 0
    try:
        with opener.open(request, timeout=timeout) as response, open(dest, "xb") as out:
            while True:
                block = response.read(CHUNK)
                if not block:
                    break
                total += len(block)
                if total > max_bytes:
                    raise Failed(f"download is larger than the cap of {max_bytes} bytes")
                digest.update(block)
                out.write(block)
    except (urllib.error.URLError, OSError) as err:
        raise Failed(f"download failed: {getattr(err, 'reason', err)}") from err
    return digest.hexdigest(), total


def copy_local(path, dest, max_bytes):
    source = Path(path)
    if not source.is_file():
        raise Refused(f"--from-file {source.name}: not a file")
    if source.stat().st_size > max_bytes:
        raise Failed(f"{source.name} is larger than the cap of {max_bytes} bytes")
    digest, total = hashlib.sha256(), 0
    with open(source, "rb") as handle, open(dest, "xb") as out:
        for block in iter(lambda: handle.read(CHUNK), b""):
            total += len(block)
            digest.update(block)
            out.write(block)
    return digest.hexdigest(), total


def unsafe_member(info):
    name = info.filename.replace("\\", "/")
    parts = name.split("/")
    if name.startswith("/") or (len(name) > 1 and name[1] == ":") or ".." in parts:
        return f"member {info.filename!r} leaves the extraction folder"
    if stat.S_ISLNK(info.external_attr >> 16):
        return f"member {info.filename!r} is a symbolic link"
    if any(ord(c) < 32 for c in name):
        return f"member {info.filename!r} has control characters"
    return None


def extract(archive, dest, member_types, max_members=MAX_MEMBERS, max_unpacked=MAX_UNPACKED):
    """Extracts allowed members of a zip into the new folder dest. Returns (files, skipped)."""
    try:
        zf = zipfile.ZipFile(archive)
    except zipfile.BadZipFile as err:
        raise Failed(f"not a readable zip: {err}") from err
    with zf:
        infos = zf.infolist()
        if len(infos) > max_members:
            raise Failed(f"archive has {len(infos)} members; the cap is {max_members}")
        if sum(i.file_size for i in infos) > max_unpacked:
            raise Failed(f"archive unpacks to more than {max_unpacked} bytes")
        for info in infos:
            why = unsafe_member(info)
            if why:
                raise Failed(f"unsafe archive: {why}")
        dest.mkdir(parents=True, exist_ok=False)
        files, skipped = [], []
        base = dest.resolve()
        for info in infos:
            if info.is_dir():
                continue
            name = info.filename.replace("\\", "/")
            if Path(name).suffix.lower() not in member_types:
                skipped.append(name)
                continue
            target = (dest / name).resolve()
            if base not in target.parents:
                raise Failed(f"unsafe archive: member {name!r} leaves the extraction folder")
            target.parent.mkdir(parents=True, exist_ok=True)
            digest, written = hashlib.sha256(), 0
            with zf.open(info) as src, open(target, "xb") as out:
                for block in iter(lambda: src.read(CHUNK), b""):
                    written += len(block)
                    if written > info.file_size:
                        raise Failed(f"member {name!r} is larger than its header says")
                    digest.update(block)
                    out.write(block)
            files.append({"path": name, "sha256": digest.hexdigest(), "bytes": written})
    return sorted(files, key=lambda f: f["path"]), sorted(skipped)


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_json(path, data):
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    tmp = Path(str(path) + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def item_url(source, item, url_root=None):
    retrieval = source["retrieval"]
    if retrieval["method"] != "https-get":
        return None
    path = retrieval["path"].replace("{item}", urllib.parse.quote(item, safe="/-_."))
    return (url_root.rstrip("/") if url_root else "https://" + retrieval["host"]) + path


def find_pin(provenance, key, item):
    for entry in provenance.get("files", []):
        if isinstance(entry, dict) and entry.get("source_key") == key and entry.get("item") == item:
            return entry
    return None


def plan(args, sources_doc, provenance):
    by_key = {s["key"]: s for s in sources_doc["sources"]}
    source = by_key.get(args.source)
    if source is None:
        raise Refused(f"unknown source {args.source!r}; known: {', '.join(sorted(by_key))}")
    if source.get("licence") not in asset_sources.LICENCES:
        raise Refused(f"{args.source} is {source.get('licence')}, not CC0; refused")
    why = asset_sources.item_problem(source, args.item)
    if why:
        raise Refused(why)
    method = source["retrieval"]["method"]
    if method == "manual" and args.pin and not args.from_file:
        raise Refused(f"{args.source} is a manual source: download the item from {source['retrieval']['page']} and pass --from-file")
    if method == "https-get" and args.from_file:
        raise Refused(f"{args.source} is fetched over https; --from-file is only for manual sources")
    return source, find_pin(provenance, args.source, args.item)


def fetch_licence_text(sources_doc, licence, url_root=None):
    entry = sources_doc["licence_texts"][licence]
    url = entry["url"]
    if url_root:
        url = url_root.rstrip("/") + "/" + url.rsplit("/", 1)[-1]
    with tempfile.TemporaryDirectory(prefix="licence-") as tmp:
        sha, size = download(url, Path(tmp) / "legalcode.txt", 1024 * 1024, asset_sources.LICENCE_HOSTS)
    if sha != entry["sha256"] or size != entry["bytes"]:
        raise Failed(f"the {licence} legal code text changed (sha256 {sha}, {size} bytes); re-review the licence before pinning")
    return sha


def pin(args, source, existing, sources_doc, provenance, today):
    if existing is None and not (args.purpose or "").strip():
        raise Refused("--purpose is required for a new pin (it is recorded in provenance)")
    licence_sha = fetch_licence_text(sources_doc, source["licence"], args.licence_root)
    item_dir = Path(args.cache) / source["key"] / args.item
    hosts = {source["retrieval"].get("host")} | set(source["retrieval"].get("redirect_hosts", []))
    hosts.discard(None)
    parent = Path(args.cache) / source["key"]
    parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=".pin-", dir=parent))
    try:
        download_path = work / "download"
        if args.from_file:
            sha, size = copy_local(args.from_file, download_path, source["max_bytes"])
            url = "manual:" + source["retrieval"]["page"]
        else:
            url = item_url(source, args.item)
            sha, size = download(item_url(source, args.item, args.url_root), download_path, source["max_bytes"], hosts)
        kind = detect_type(download_path)
        if kind not in source["allowed_types"]:
            raise Failed(f"the file is {kind or 'of an unknown type'}; {source['key']} allows {source['allowed_types']}")
        if existing is not None and (existing.get("sha256") != sha or existing.get("bytes") != size):
            raise Failed(f"sha256 {sha} ({size} bytes) differs from the pin {existing.get('sha256')} ({existing.get('bytes')} bytes); the file changed at the source")
        final = work / f"{source['key']}.{kind}"
        download_path.rename(final)
        manifest = {"schema": "asset-cache/1", "source_key": source["key"], "item": args.item, "sha256": sha, "bytes": size, "type": kind}
        if kind == "zip":
            files, skipped = extract(final, work / "files", source["member_types"])
            manifest.update({"files": files, "skipped": skipped})
        write_json(work / "cache-manifest.json", manifest)
        if item_dir.exists():
            shutil.rmtree(item_dir)
        item_dir.parent.mkdir(parents=True, exist_ok=True)
        os.replace(work, item_dir)
    finally:
        if work.exists():
            shutil.rmtree(work)
    entry = existing
    if existing is None:
        entry = {
            "source_key": source["key"],
            "item": args.item,
            "url": url,
            "sha256": sha,
            "bytes": size,
            "type": kind,
            "licence": source["licence"],
            "licence_url": source["licence_url"],
            "licence_text_sha256": licence_sha,
            "date": today,
            "purpose": args.purpose.strip(),
            "approval": "pinned",
        }
        provenance.setdefault("files", []).append(entry)
        problems = asset_sources.provenance_problems(provenance, sources_doc)
        if problems:
            raise Failed("the new provenance entry is invalid: " + "; ".join(problems))
        write_json(args.provenance, provenance)
    return entry, item_dir, existing is None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", action="store_true", help="list the sources and pinned items")
    ap.add_argument("--source", help="assets/sources.json key")
    ap.add_argument("--item", help="item id within the source (matches its item_pattern)")
    ap.add_argument("--pin", action="store_true", help="the owner's approval: fetch, verify and record this one item")
    ap.add_argument("--from-file", metavar="FILE", help="a manual source's file the owner downloaded")
    ap.add_argument("--purpose", help="why this item is fetched (recorded with a new pin)")
    ap.add_argument("--sources", default=str(asset_sources.SOURCES), help=argparse.SUPPRESS)
    ap.add_argument("--provenance", default=str(asset_sources.PROVENANCE), help=argparse.SUPPRESS)
    ap.add_argument("--cache", default=str(CACHE), help=argparse.SUPPRESS)
    ap.add_argument("--allow-file-urls", action="store_true", help=argparse.SUPPRESS)  # tests only
    ap.add_argument("--url-root", help=argparse.SUPPRESS)  # tests only: file:// root replacing https://<host>
    ap.add_argument("--licence-root", help=argparse.SUPPRESS)  # tests only: file:// folder holding the legal code text
    ap.add_argument("--today", help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    for value in (args.url_root, args.licence_root):
        if value and not (args.allow_file_urls and value.startswith("file://")):
            print("REFUSED test-only roots must be file:// with --allow-file-urls")
            return 2
    try:
        sources_doc = load_json(args.sources)
        provenance = load_json(args.provenance)
    except (OSError, ValueError) as err:
        print(f"FAIL cannot read sources or provenance: {err}")
        return 1
    problems = asset_sources.sources_problems(sources_doc, args.allow_file_urls)
    if problems:
        print("FAIL assets/sources.json is invalid: " + "; ".join(problems))
        return 1
    if args.list:
        for source in sources_doc["sources"]:
            pins = [e["item"] for e in provenance.get("files", []) if e.get("source_key") == source["key"]]
            print(f"{source['key']:<12} {source['licence']} {source['retrieval']['method']:<9} {', '.join(source['kinds'])}; pinned: {', '.join(pins) or 'none'}")
        return 0
    if not args.source or not args.item:
        print("REFUSED --source and --item are required (or --list)")
        return 2
    try:
        source, existing = plan(args, sources_doc, provenance)
        url = item_url(source, args.item)
        target = relpath(Path(args.cache) / source["key"] / args.item)
        if not args.pin:
            print(f"dry run: {source['key']}:{args.item} ({source['licence']}, {source['retrieval']['method']})")
            print(f"  from:  {url or 'manual download from ' + source['retrieval']['page'] + ' (then --from-file)'}")
            print(f"  into:  {target}/ (not committed)")
            print(f"  pin:   {'pinned ' + existing['sha256'][:12] + ' on ' + existing['date'] if existing else 'not pinned yet'}")
            print("  nothing downloaded or written; add --pin (and --purpose) to fetch, verify and record this item")
            return 0
        today = args.today or datetime.date.today().isoformat()
        entry, item_dir, created = pin(args, source, existing, sources_doc, provenance, today)
    except Refused as err:
        print(f"REFUSED {err}")
        return 2
    except Failed as err:
        print(f"FAIL {err}")
        return 1
    state = "pinned" if created else "verified against the existing pin"
    print(f"{state}: {entry['source_key']}:{entry['item']} sha256 {entry['sha256']} ({entry['bytes']} bytes, {entry['type']}) -> {relpath(item_dir)}/")
    if created:
        print(f"  recorded in {relpath(args.provenance)} (files); kit/1 cites it as cc0:{entry['source_key']}:{entry['item']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
