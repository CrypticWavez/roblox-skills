---
name: luau-quality
description: Format, lint and test Luau and the factory's Python/Blender tooling with the repo gates - StyLua, Selene, Lune unit tests, fixture builds and golden hashes, skill and gap-matrix checks, hook self-test, Blender QA - in fast/pre-commit/pre-release tiers. Use after editing any .luau/.py/.mjs/SKILL.md file, before committing and when a gate or CI job fails.
---

# Quality gates

## Purpose
One repeatable gate, `tools/check.py`, that Claude, Codex, the git hook and CI all run, so "green" means the same thing everywhere.

## Triggers
After editing `.luau`, `.py`, `.mjs`, JSON or SKILL.md files; before every commit; before marking a PR ready; a hook message or a CI job failed.

## Inputs
The working tree, the tier to run, and whether a golden-hash change is intended.

## Required context
`tools/check.py` docstring (tiers and steps); `stylua.toml`, `selene.toml`; `rokit.toml` (pinned rojo, lune, stylua, selene, luau-lsp); `.github/workflows/factory.yml` (what CI runs).

## Tools
| Tier | When | Command | Runs |
|---|---|---|---|
| FAST_ON_EDIT | automatic Claude PostToolUse hook after Edit/Write/MultiEdit (`.claude/settings.json`) | `node tools/hooks/fast_on_edit.mjs` | touched file only: secret scan, JSON parse, `stylua --check` for Luau, SKILL.md frontmatter, reminder when `.claude/skills` is edited; < 1 s |
| fast | on demand | `python3 tools/check.py --tier fast` | `stylua --check`, JSON validity, secret scan of the working tree |
| PRE_COMMIT | before every commit; CI job `pre-commit` | `python3 tools/check.py` (default tier) | fast + `tools/sync_skills.py --check` + `tools/gap_matrix.py --check` + `node tools/hooks/selftest.mjs` + selene + `lune run tests/run.luau` + inherited Lune suites + fixture build against golden hashes; ~10 s |
| PRE_RELEASE | before a PR is marked ready; CI job `blender` (bpy 5.1.2 and 5.2.2) | `python3 tools/check.py --tier pre-release` | pre-commit + Blender `templates`, `roundtrip` and `render-manifest` previews of modular_building, dungeon and settlement; minutes |

- `--strict` counts every SKIPPED step (tool missing) as FAIL. CI runs `--tier pre-commit --strict` and the Blender job `--tier pre-release --strict`. Without it a missing tool shows as SKIPPED, never as PASS.
- The secret scan reads every text file in the working tree (not the git index), so unstaged files count too.
- `--update-golden` rewrites `tests/golden/fixture-hashes.json`; `--install-git-hook` makes `git commit` run PRE_COMMIT.

## Procedure
1. Edit; read the hook's message if it flags formatting, JSON, a secret or SKILL.md frontmatter. Format Luau with `stylua <file>`.
2. Before committing run PRE_COMMIT; fix failures at the root (no skipped tests, no lowered validation limits).
3. Fixture hash changed on purpose: `python3 tools/check.py --update-golden` and `lune run tools/lune/smoke_hashes.luau`, and name the changed fixtures and why in the commit.
4. New Luau logic gets a Lune spec in `tests/*.spec.luau` (pure modules) or a Studio diagnostic (Roblox-only APIs); see roblox-luau-testing.
5. Before a PR is ready, run PRE_RELEASE where `bpy` or Blender is installed.

## Outputs
One line per step (`[ok  ]`, `[FAIL]`, `[skip]`), a final `<tier>: PASS|FAIL; failed=[...] skipped=[...]` line, and `build/check-report.json` (`tier`, `pass`, `failed`, `skipped`, per-step detail).

## Acceptance
The tier reports PASS with `failed` empty; every SKIPPED step is named in the PR or report (CI's `--strict` makes it a failure).

## Failure
- `fixture-hashes`: an unintended change is a generator or SceneKit regression; find it with `Scene.compare` on the old and new manifests (visual-qa).
- `selene` SKIPPED: it needs `selene generate-roblox-std`, which needs network to the Roblox API dump.
- `skills-sync`: edit `.agents/skills/`, then `python3 tools/sync_skills.py`; it also fails when a SKILL.md's `name` differs from its folder, the description is missing, or one of the ten `## <Section>` headings (`SECTIONS` in `tools/sync_skills.py`) is missing or empty.
- `gap-matrix`: edit `reports/gap-matrix.json`, then `python3 tools/gap_matrix.py`; never edit `docs/gap-matrix.md` by hand.
- Toolchain missing: `rokit install`; without rokit, `cargo install stylua --features luau` and `cargo install selene lune`.

## Related
roblox-luau-testing, roblox-scene-authoring, roblox-procedural-generation, blender-asset-qa.
