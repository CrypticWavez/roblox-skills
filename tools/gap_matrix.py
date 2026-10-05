"""Validate reports/gap-matrix.json and render docs/gap-matrix.md from it.

  python3 tools/gap_matrix.py          rewrite docs/gap-matrix.md
  python3 tools/gap_matrix.py --check  fail if the JSON is invalid or the doc is stale

The JSON is canonical; edit it, never the generated doc.
"""
import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "reports" / "gap-matrix.json"
DOC = ROOT / "docs" / "gap-matrix.md"
FIELDS = [
    "capability",
    "previous_claim",
    "actual_state",
    "evidence",
    "defect",
    "root_cause",
    "impact",
    "priority",
    "fix",
    "verification",
    "status",
]
PRIORITIES = {"P0", "P1", "P2", "P3"}
NEEDS_OWNER_STEPS = {"BLOCKED_EXTERNAL"}


def validate(data):
    errors = []
    statuses = set(data["statuses"])
    seen = set()
    for row in data["rows"]:
        rid = row.get("id", "?")
        if rid in seen:
            errors.append(f"{rid}: duplicate id")
        seen.add(rid)
        for field in FIELDS + ["area"]:
            if not str(row.get(field, "")).strip():
                errors.append(f"{rid}: missing {field}")
        if row.get("status") not in statuses:
            errors.append(f"{rid}: unknown status {row.get('status')}")
        if row.get("priority") not in PRIORITIES:
            errors.append(f"{rid}: priority must be one of {sorted(PRIORITIES)}")
        if row.get("status") in NEEDS_OWNER_STEPS and not row.get("owner_steps"):
            errors.append(f"{rid}: {row['status']} needs owner_steps")
    return errors


def cell(text):
    return str(text).replace("|", "\\|").replace("\n", " ")


def render(data):
    rows = data["rows"]
    counts = Counter(r["status"] for r in rows)
    out = [
        "# Second-pass gap matrix",
        "",
        f"Generated from `reports/gap-matrix.json` by `python3 tools/gap_matrix.py`; edit the JSON, not this file. As of {data['as_of']}.",
        "",
        data["scope"],
        "",
        f"**Rule:** {data['verification_rule']}",
        "",
        "| Status | Count |",
        "|---|---|",
    ]
    out += [f"| {s} | {counts[s]} |" for s in data["statuses"] if counts[s]]
    out += ["", "## Summary", "", "| ID | Area | Capability | Status | Priority | Verification |", "|---|---|---|---|---|---|"]
    for r in rows:
        out.append(
            f"| [{r['id']}](#{r['id'].lower()}) | {cell(r['area'])} | {cell(r['capability'])} | {r['status']} | {r['priority']} | {cell(r['verification'])} |"
        )
    steps = [r for r in rows if r.get("owner_steps")]
    if steps:
        out += ["", "## Steps that need Ethan's machine or decision", ""]
        for r in steps:
            out.append(f"**{r['id']} {r['capability']}** ({r['status']})")
            out.append("")
            out += [f"{i}. {s}" for i, s in enumerate(r["owner_steps"], 1)]
            out.append("")
    out += ["", "## Rows", ""]
    for r in rows:
        out += [f"### {r['id']}", "", f"**{r['capability']}** · {r['area']} · {r['status']} · {r['priority']}", ""]
        for field in FIELDS[1:7] + FIELDS[8:10]:
            out.append(f"- **{field.replace('_', ' ').upper()}:** {r[field]}")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def main():
    data = json.loads(SOURCE.read_text(encoding="utf-8"))
    errors = validate(data)
    for e in errors:
        print("gap-matrix:", e)
    text = render(data)
    if "--check" in sys.argv:
        stale = not DOC.exists() or DOC.read_text(encoding="utf-8") != text
        if stale:
            print("gap-matrix: docs/gap-matrix.md is stale; run python3 tools/gap_matrix.py")
        return 1 if errors or stale else 0
    if errors:
        return 1
    DOC.write_text(text, encoding="utf-8")
    print(f"wrote {DOC.relative_to(ROOT)} ({len(data['rows'])} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
