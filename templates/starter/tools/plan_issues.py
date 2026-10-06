"""Write local issue drafts for a production stage. Makes no API calls and creates no issues.

  python3 tools/plan_issues.py [--stage STAGE] [--out build/issue-drafts]

Reads production/pipeline.json (production-pipeline/1), production/brief.json, release/report.json (when
tools/release_check.py has run) and release/owner-*.json. For each exit gate of the stage that is not
done it writes one Markdown draft (front matter: title, labels, template) to
<out>/<stage>/NN-<gate>.md, plus index.json. Owner and playtest gates become drafts labelled owner: only
the owner closes them, by recording them in a release/owner-*.json file. The drafts follow the issue
forms in .github/ISSUE_TEMPLATE; a person reviews them and creates the issues they want.
"""
import argparse
import json
import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import production  # noqa: E402
import release_check  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_FOR = {"brief": "system", "file": "system", "gate": "system", "release": "system", "playtest": "playtest", "owner": "playtest"}


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:48] or "gate"


def draft(stage, gate, state, detail, brief, report):
    kind = gate["kind"]
    labels = [f"stage:{stage['id']}", f"gate:{kind}"]
    acceptance, verify, body = [], "python3 tools/production.py status", []
    if kind == "brief":
        open_fields = [f for f in gate["fields"] if production.is_tbd(brief.get(f, production.TBD))]
        labels.append("decision")
        body.append("Decide these production/brief.json fields from the game-build request or with the owner. Agents never invent them.")
        acceptance += [f"`{f}` decided in production/brief.json, logged in docs/decisions.md, mirrored in AGENTS.md" for f in open_fields]
        verify = "python3 tools/check.py --tier pre-commit"
    elif kind == "file":
        labels.append("design")
        body.append(f"Fill in `{gate['path']}`: answer every prompt, then set its `Status:` line to draft or agreed.")
        acceptance.append(f"`{gate['path']}` answers every prompt and its Status is no longer TBD")
    elif kind == "gate":
        labels.append("engineering")
        body.append(f"Make the game gate pass at the {gate['tier']} tier.")
        acceptance.append(f"`python3 tools/check.py --tier {gate['tier']}` passes")
        verify = f"python3 tools/check.py --tier {gate['tier']}"
    elif kind == "release":
        statuses = {i["id"]: i for i in (report or {}).get("items", [])}
        owner_items = [i for i in gate["items"] if not i.startswith("A")]
        labels.append("owner" if owner_items and len(owner_items) == len(gate["items"]) else "release")
        for item_id in gate["items"]:
            item = release_check.ITEM_BY_ID.get(item_id, {"title": item_id, "spec": ""})
            got = statuses.get(item_id, {})
            line = f"{item_id} {item['title']}: {item['spec']}"
            if got.get("problems"):
                line += f" Currently: {got['problems'][0]}"
            acceptance.append(line + (" (owner records it)" if not item_id.startswith("A") else ""))
        body.append("Release checklist items (docs/release-runbook.md). Automated items pass in tools/release_check.py; "
                    "Studio and owner items are done by the owner and recorded in release/owner-*.json.")
        verify = "python3 tools/release_check.py"
    else:
        labels.append("owner")
        body.append("Only the owner can complete this gate and record it in a release/owner-*.json file (release-owner/1). "
                    "Agents prepare what the owner needs and stop.")
        acceptance.append(f"owner record `{gate['id']}` in release/owner-*.json")
    title = f"[{stage['id']}] {gate['text']}"
    lines = [
        "---",
        f"title: {json.dumps(title)}",
        f"labels: [{', '.join(labels)}]",
        f"template: {TEMPLATE_FOR[kind]}",
        f"gate: {gate['id']}",
        "---",
        "",
        f"Stage **{stage['id']}**: {stage['goal']}",
        "",
        *body,
        "",
        f"Gate status now: {state} ({detail})",
        "",
        "## Acceptance",
        "",
        *[f"- [ ] {a}" for a in acceptance],
        "",
        "## Verify",
        "",
        f"`{verify}`",
        "",
        "## Skills",
        "",
        ", ".join(stage.get("skills", [])),
        "",
    ]
    return title, labels, "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--stage", help=f"one of {production.STAGES} (default: production/pipeline.json current)")
    ap.add_argument("--out", default="build/issue-drafts", help="output folder (default build/issue-drafts)")
    args = ap.parse_args(argv)
    pipeline, err = production.load_json(ROOT / "production" / "pipeline.json")
    brief, err2 = production.load_json(ROOT / "production" / "brief.json")
    if err or err2:
        print(f"refused: {err or err2}", file=sys.stderr)
        return 2
    problems = production.pipeline_problems(pipeline, production.BRIEF_FIELDS)
    if problems:
        print("refused: production/pipeline.json is invalid:\n  " + "\n  ".join(problems), file=sys.stderr)
        return 2
    stage_id = args.stage or pipeline["current"]
    if stage_id not in production.STAGES:
        print(f"refused: unknown stage {stage_id!r}; stages: {production.STAGES}", file=sys.stderr)
        return 2
    stage = pipeline["stages"][production.STAGES.index(stage_id)]
    report, _ = production.load_json(ROOT / "release" / "report.json")
    report = report if isinstance(report, dict) else None
    records, _ = production.owner_records(ROOT)
    out = (ROOT / args.out / stage_id).resolve()
    if ROOT.resolve() not in out.parents:
        print("refused: --out must stay inside this repository", file=sys.stderr)
        return 2
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    index = []
    for gate in stage.get("exit", []):
        state, detail = production.gate_status(ROOT, gate, brief, records, report)
        if state in ("DONE", "OWNER_RECORDED"):
            continue
        title, labels, text = draft(stage, gate, state, detail, brief, report)
        name = f"{len(index) + 1:02d}-{slug(gate['id'])}.md"
        (out / name).write_text(text, encoding="utf-8")
        index.append({"file": name, "gate": gate["id"], "kind": gate["kind"], "title": title, "labels": labels, "status": state})
    (out / "index.json").write_text(json.dumps({"stage": stage_id, "drafts": index}, indent=2) + "\n", encoding="utf-8")
    rel = out.relative_to(ROOT.resolve()).as_posix()
    print(f"wrote {len(index)} draft(s) for stage {stage_id} to {rel}/ (index.json lists them)")
    print("review them; a person creates the issues they want (for example `gh issue create --title <title> --body-file <file>`). "
          "This tool calls no API.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
