"""Render knowledge/INDEX.md, the one-page index of research docs and knowledge records.

  python3 tools/knowledge_index.py          rewrite knowledge/INDEX.md
  python3 tools/knowledge_index.py --check  fail if the index is stale (gate step knowledge-index)

Sources are docs/research/*.md (title = first `# ` heading) and knowledge/records/*.json (one
record or a list of records per file). Edit those, never the generated index. Record scopes are
checked by the gate step knowledge-paths in tools/check.py.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESEARCH = ROOT / "docs" / "research"
RECORDS = ROOT / "knowledge" / "records"
INDEX = ROOT / "knowledge" / "INDEX.md"


def cell(text):
    return str(text).replace("|", "\\|").replace("\n", " ").strip()


def doc_title(path):
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return path.stem


def records():
    for path in sorted(RECORDS.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        for record in data if isinstance(data, list) else [data]:
            yield path, record


def render():
    out = [
        "# Knowledge and research index",
        "",
        "Generated from `docs/research/*.md` and `knowledge/records/*.json` by `python3 tools/knowledge_index.py`; edit those, not this file. Gate steps: `knowledge-index` (this file is current), `knowledge-paths` (record scopes), `doc-links` (links and URLs).",
        "",
        "Record scope `repo`: every path the record cites exists in this repository. Scope `workbench`: copied from the owner's local workbench; the paths, commands and receipts it cites exist only there, so its status (`*_on_workbench`) is a workbench observation this repo cannot reproduce. Treat it as a lead to re-check, not as evidence.",
        "",
        "## Research docs",
        "",
        "| Doc | Title |",
        "|---|---|",
    ]
    for path in sorted(RESEARCH.glob("*.md")):
        out.append(f"| [{path.name}](../docs/research/{path.name}) | {cell(doc_title(path))} |")
    out += ["", "## Knowledge records", "", "| Record | File | Type | Status | Scope | Title |", "|---|---|---|---|---|---|"]
    for path, r in records():
        out.append(
            f"| `{cell(r.get('id', '?'))}` | [{path.name}](records/{path.name}) | {cell(r.get('type', ''))} "
            f"| {cell(r.get('status', ''))} | {cell(r.get('scope', ''))} | {cell(r.get('title', ''))} |"
        )
    return "\n".join(out) + "\n"


def main():
    try:
        text = render()
    except (OSError, ValueError) as err:
        print(f"knowledge-index: could not read the sources: {err}")
        return 1
    if "--check" in sys.argv:
        current = INDEX.read_text(encoding="utf-8").replace("\r\n", "\n") if INDEX.exists() else ""
        if current != text:
            print("knowledge-index: knowledge/INDEX.md is stale; run python3 tools/knowledge_index.py")
            return 1
        return 0
    with open(INDEX, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print(f"wrote {INDEX.relative_to(ROOT).as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
