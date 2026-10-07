# Production plan

How this repository goes from a game-build request to a release candidate. The stages, their exit gates and the skills for each live in [production/pipeline.json](../production/pipeline.json) (production-pipeline/1); this page explains how to work with them. Skill: roblox-production-pipeline. Nothing here decides what the game is: that is [production/brief.json](../production/brief.json), filled only from the game-build request or by the owner.

## Stages

| Stage | Goal | Exit gates (summary) |
|---|---|---|
| concept | Decide what the game is | brief identity fields; [core loop](design/core-loop.md); owner approval |
| greybox | Core loop playable in untextured geometry; kits wired into the boot phases | world, kits and engine settings decided; [UX flows](design/ux-flows.md); gate pre-commit; boot report ok in Studio (S07); internal playtest |
| vertical-slice | One slice at target quality | characters, progression and the UI, [art](design/art-direction.md) and [audio](design/audio-direction.md) directions; release checks A07, A10, A11; playtest; owner approval |
| alpha | Feature complete; every required brief field decided | [economy](design/economy.md), the monetization sheet `docs/design/monetization.md` from `tools/monetize.py plan`; release checks A02-A06, A08, A15, A18; Studio items S01, S02, S05; playtest |
| beta | Content complete; polish, performance, localisation, devices | release checks A09, A11, A13, A14, A17; Studio items S03, S04, S06; Limited-audience playtest |
| release-candidate | Everything automated passes; the owner does the owner items and publishes | gate pre-release; A01-A18; O01-O15; the owner publishes |

Gate kinds: `brief` (fields decided), `file` (a design doc whose `Status:` is no longer TBD), `gate` (a `tools/check.py` tier passes), `release` (items of [the release runbook](release-runbook.md)), `playtest` and `owner` (only the owner records them, in `release/owner-*.json`).

## Working loop

1. `python3 tools/production.py status`: the current stage, each exit gate's state, the TBD brief fields.
2. `python3 tools/plan_issues.py`: one Markdown draft per open gate in `build/issue-drafts/<stage>/` (title, labels, acceptance, how to verify). A person reviews them and creates the issues; the issue forms are in `.github/ISSUE_TEMPLATE` (system, asset, bug, playtest). The tool calls no API.
3. Build in small issues: kit modules first (`starter.json` lists what is installed and each module's tier), new code in `src/` with a Lune spec, `python3 tools/check.py` before every commit.
4. Decisions go to [docs/decisions.md](decisions.md), then to the brief and the `AGENTS.md` tables in the same commit.
5. When every gate of the stage is done, the owner records the owner and playtest gates and moves `current` in `production/pipeline.json`. The gate step `brief` fails if a passed stage lacks those records or its brief fields.

## Roles

- **Owner**: decides the brief, approves stages, runs Studio checks that need their machine, does every Creator Hub action, publishes. Writes `release/owner-*.json`.
- **Agents**: build and test within the decisions, keep the gate green, prepare drafts and evidence, stop at owner items. They never publish, upload, create products or spend.

## Playtests

Each playtest gets a playtest issue (questions, setup, findings, decision). Fixture passes and Studio runs do not prove fun; playtests and their decisions do.
