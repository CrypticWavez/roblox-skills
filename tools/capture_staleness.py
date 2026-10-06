"""Flag captures and Studio smoke records whose source scene hash has changed since they were made.

  python3 tools/capture_staleness.py                 scan reports/ (default)
  python3 tools/capture_staleness.py PATH [PATH...]  files or folders to scan instead
  python3 tools/capture_staleness.py --json          machine-readable result on stdout
  python3 tools/capture_staleness.py --fail-stale    exit 1 when anything is STALE or INCOMPLETE

Two kinds of record are checked:
- capture manifests (schema capture-manifest/1, written from Pipeline/CaptureSet next to the images):
  scene.hash is compared with tests/golden/fixture-hashes.json[scene.name] (source "fixture") or
  tests/golden/studio-smoke.json[scene.name].hash (source "studio-smoke"); every shot's image must sit
  next to the manifest.
- Studio smoke records (reports/studio/smoke-*.json): each result.<scene>.hash is compared with
  tests/golden/studio-smoke.json.

Statuses: CURRENT, STALE (hash changed: recapture or rerun), INCOMPLETE (images missing), INVALID
(malformed record, unknown scene or source). Exit 1 on INVALID always, on STALE/INCOMPLETE only with
--fail-stale; otherwise 0. Read-only: it prints and writes nothing.
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = "capture-manifest/1"
SOURCES = ("fixture", "studio-smoke")
LABEL = re.compile(r"^[a-z0-9][a-z0-9_\-]{0,47}$")
HEX = re.compile(r"^[0-9a-f]{1,64}$")
SMOKE_NAME = re.compile(r"^smoke-.*\.json$")
FIXTURE_GOLDEN = "tests/golden/fixture-hashes.json"
SMOKE_GOLDEN = "tests/golden/studio-smoke.json"
CAMERA = "packages/SceneKit/Camera.luau"


def camera_angles(root):
    """The angle names in SceneKit Camera.ANGLES, read from the Luau source so the two never drift."""
    text = (root / CAMERA).read_text(encoding="utf-8")
    block = re.search(r"Camera\.ANGLES\s*=\s*\{(.*?)\n\}", text, re.S)
    if not block:
        raise ValueError(f"{CAMERA}: Camera.ANGLES not found")
    keys = re.findall(r'^\s*(?:\["([\w-]+)"\]|([A-Za-z_]\w*))\s*=\s*\{', block.group(1), re.M)
    names = sorted({quoted or bare for quoted, bare in keys})
    if not names:
        raise ValueError(f"{CAMERA}: Camera.ANGLES has no entries")
    return names


def load_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def goldens(root):
    fixture = load_json(root / FIXTURE_GOLDEN) if (root / FIXTURE_GOLDEN).is_file() else {}
    smoke = load_json(root / SMOKE_GOLDEN) if (root / SMOKE_GOLDEN).is_file() else {}
    return {
        "fixture": {k: v for k, v in fixture.items() if isinstance(v, str)},
        "studio-smoke": {k: v.get("hash") for k, v in smoke.items() if isinstance(v, dict)},
    }


def rel(path, root):
    try:
        return Path(path).resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return Path(path).name


def manifest_problems(doc, angles):
    problems = []
    if not isinstance(doc, dict):
        return ["manifest must be an object"]
    if doc.get("schema") != SCHEMA:
        problems.append(f"schema must be {SCHEMA}")
    scene = doc.get("scene")
    if not isinstance(scene, dict) or not isinstance(scene.get("name"), str) or not LABEL.match(scene["name"]):
        problems.append("scene.name must be a lower-case label")
        scene = None
    elif not isinstance(scene.get("hash"), str) or not HEX.match(scene["hash"]):
        problems.append("scene.hash must be a hex digest")
    elif scene.get("source") not in SOURCES:
        problems.append("scene.source must be fixture or studio-smoke")
    shots = doc.get("shots")
    if not isinstance(shots, list) or not shots:
        problems.append("shots must be a non-empty list")
        return problems
    seen = set()
    for index, shot in enumerate(shots, 1):
        where = f"shots[{index}]"
        if not isinstance(shot, dict) or not isinstance(shot.get("id"), str):
            problems.append(f"{where} needs an id")
            continue
        if shot["id"] in seen:
            problems.append(f"{where} duplicates {shot['id']}")
        seen.add(shot["id"])
        if shot.get("angle") not in angles:
            problems.append(f"{where} unknown angle {shot.get('angle')!r}")
        if scene and shot["id"] != f"{scene['name']}.{shot.get('profile')}.{shot.get('angle')}":
            problems.append(f"{where} id must be <scene>.<profile>.<angle>")
        file = shot.get("file")
        if not isinstance(file, str) or "/" in file or "\\" in file or not file.endswith(".png"):
            problems.append(f"{where} file must be a plain .png name")
    return problems


def check_manifest(path, doc, root, current, angles):
    item = {"kind": "capture", "path": rel(path, root)}
    problems = manifest_problems(doc, angles)
    if problems:
        return {**item, "status": "INVALID", "problems": problems}
    scene = doc["scene"]
    item.update({"scene": scene["name"], "source": scene["source"], "recorded": scene["hash"]})
    want = current[scene["source"]].get(scene["name"])
    if want is None:
        golden = FIXTURE_GOLDEN if scene["source"] == "fixture" else SMOKE_GOLDEN
        return {**item, "status": "INVALID", "problems": [f"{scene['name']} is not in {golden}"]}
    item["current"] = want
    missing = sorted(shot["file"] for shot in doc["shots"] if not (Path(path).parent / shot["file"]).is_file())
    if want != scene["hash"]:
        item["status"] = "STALE"
    elif missing:
        item["status"] = "INCOMPLETE"
    else:
        item["status"] = "CURRENT"
    item["shots"] = len(doc["shots"])
    if missing:
        item["missing"] = missing
    return item


def check_smoke(path, doc, root, current):
    items = []
    result = doc.get("result") if isinstance(doc, dict) else None
    if not isinstance(result, dict) or not result:
        return [{"kind": "studio-smoke", "path": rel(path, root), "status": "INVALID", "problems": ["result must map scene names to {hash}"]}]
    for name in sorted(result):
        entry = result[name]
        item = {"kind": "studio-smoke", "path": rel(path, root), "scene": name, "source": "studio-smoke"}
        if not isinstance(entry, dict) or not isinstance(entry.get("hash"), str) or not HEX.match(entry["hash"]):
            items.append({**item, "status": "INVALID", "problems": [f"result.{name}.hash must be a hex digest"]})
            continue
        want = current["studio-smoke"].get(name)
        item["recorded"] = entry["hash"]
        if want is None:
            items.append({**item, "status": "INVALID", "problems": [f"{name} is not in {SMOKE_GOLDEN}"]})
            continue
        item["current"] = want
        item["status"] = "CURRENT" if want == entry["hash"] else "STALE"
        items.append(item)
    return items


def candidates(paths, root):
    files = []
    for value in paths:
        path = Path(value)
        if not path.is_absolute():
            path = root / path
        if path.is_dir():
            files.extend(sorted(p for p in path.rglob("*.json") if p.is_file()))
        elif path.is_file():
            files.append(path)
        else:
            raise FileNotFoundError(f"{value} does not exist")
    return files


def scan(paths, root):
    angles = camera_angles(root)
    current = goldens(root)
    items = []
    for path in candidates(paths, root):
        try:
            doc = load_json(path)
        except (OSError, ValueError) as err:
            if SMOKE_NAME.match(path.name) or path.name == "manifest.json":
                items.append({"kind": "unknown", "path": rel(path, root), "status": "INVALID", "problems": [f"unreadable JSON: {err.__class__.__name__}"]})
            continue
        if isinstance(doc, dict) and doc.get("schema") == SCHEMA:
            items.append(check_manifest(path, doc, root, current, angles))
        elif path.name == "manifest.json" and isinstance(doc, dict) and "shots" in doc:
            items.append(check_manifest(path, doc, root, current, angles))
        elif SMOKE_NAME.match(path.name) and path.parent.name == "studio":
            items.extend(check_smoke(path, doc, root, current))
    return items


def summary(items):
    counts = {}
    for item in items:
        counts[item["status"]] = counts.get(item["status"], 0) + 1
    return dict(sorted(counts.items()))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("paths", nargs="*", help="files or folders to scan (default: reports/)")
    ap.add_argument("--json", action="store_true", help="print the result as JSON")
    ap.add_argument("--fail-stale", action="store_true", help="exit 1 when anything is STALE or INCOMPLETE")
    ap.add_argument("--root", default=str(ROOT), help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    root = Path(args.root)
    try:
        items = scan(args.paths or ["reports"], root)
    except (OSError, ValueError) as err:
        print(f"capture_staleness: {err}", file=sys.stderr)
        return 1
    counts = summary(items)
    if args.json:
        print(json.dumps({"schema": "capture-staleness/1", "counts": counts, "items": items}, indent=2, sort_keys=True))
    else:
        for item in items:
            where = f"{item['path']}" + (f" {item['scene']}" if "scene" in item else "")
            if item["status"] == "INVALID":
                print(f"INVALID {where}: {'; '.join(item['problems'])}")
            elif item["status"] == "STALE":
                golden = FIXTURE_GOLDEN if item["source"] == "fixture" else SMOKE_GOLDEN
                print(f"STALE {where}: recorded {item['recorded']}, current {item['current']} ({golden}); recapture or rerun")
            elif item["status"] == "INCOMPLETE":
                print(f"INCOMPLETE {where}: missing {', '.join(item['missing'])}")
            else:
                print(f"CURRENT {where}: {item['recorded']}")
        print("capture_staleness: " + (", ".join(f"{n} {s}" for s, n in counts.items()) or "nothing to check"))
    if counts.get("INVALID"):
        return 1
    if args.fail_stale and (counts.get("STALE") or counts.get("INCOMPLETE")):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
