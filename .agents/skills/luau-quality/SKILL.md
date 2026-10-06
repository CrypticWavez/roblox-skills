---
name: luau-quality
description: Format, lint, type-check and test Luau and the factory's Python/Blender tooling with the repo gates - StyLua, Selene, luau-lsp type analysis against a no-regression baseline, Lune unit tests, Python unit tests, fixture builds and golden hashes, kit tier headers, skill and gap-matrix checks, doc links, knowledge index and record scopes, asset provenance, Rojo sourcemaps, hook self-test, Blender QA - in fast/pre-commit/pre-release tiers. Use after editing any .luau/.py/.mjs/.md/SKILL.md file or a knowledge record, before committing and when a gate or CI job fails.
---

# Quality gates

## Purpose
One repeatable gate, `tools/check.py`, that Claude, Codex, the git hook and CI all run, so "green" means the same thing everywhere.

## Triggers
After editing `.luau`, `.py`, `.mjs`, JSON, Markdown or SKILL.md files, a knowledge record, a fixture or a Rojo project, or adding a Roblox asset id; before every commit; before marking a PR ready; a hook message or a CI job failed.

## Inputs
The working tree, the tier to run, and whether a golden-hash change is intended.

## Required context
`tools/check.py` docstring (tiers and steps); `stylua.toml`, `selene.toml`; `assets/provenance.json`, `knowledge/INDEX.md`, `fixtures/README.md` (what the content checks compare against); `rokit.toml` (pinned rojo, lune, stylua, selene, luau-lsp 1.70.1); `luau-defs.lock.json` (Roblox definitions and API docs pinned by commit and sha256); `tests/golden/luau-lsp-baseline.json` (per-file diagnostic counts); `.github/workflows/factory.yml` (what CI runs).

## Tools
| Tier | When | Command | Runs |
|---|---|---|---|
| FAST_ON_EDIT | automatic Claude PostToolUse hook after Edit/Write/MultiEdit (`.claude/settings.json`) | `node tools/hooks/fast_on_edit.mjs` | touched file only: secret scan, JSON parse, `stylua --check` for Luau, SKILL.md frontmatter, reminder when `.claude/skills` is edited; < 1 s |
| fast | on demand | `python3 tools/check.py --tier fast` | `stylua --check`, JSON validity, secret scan of the working tree |
| PRE_COMMIT | before every commit; CI job `pre-commit` | `python3 tools/check.py` (default tier) | fast + `tools/sync_skills.py --check` + `tools/gap_matrix.py --check` + content checks (below) + `node tools/hooks/selftest.mjs` + selene + `lune run tests/run.luau` + inherited Lune suites + fixture build against golden hashes; ~17 s, of which Lune specs ~13 s and content checks < 1 s |
| PRE_RELEASE | before a PR is marked ready; CI job `blender` (bpy 5.1.2 and 5.2.2) | `python3 tools/check.py --tier pre-release` | pre-commit + Blender `templates`, `roundtrip`, `qa-selftest` and `render-manifest` previews of modular_building, dungeon and settlement; minutes |

- Content checks (PRE_COMMIT, offline): `doc-links` (relative Markdown links, heading anchors and `@` imports resolve; http(s) URLs in Markdown and `knowledge/`/`assets/` JSON are well formed), `knowledge-index` (`knowledge/INDEX.md` matches `python3 tools/knowledge_index.py`), `knowledge-paths` (every record has `scope` and `scope_note`; scope `repo` cites only paths that exist; scope `workbench` never claims plain `verified`), `fixtures-readme` (every `fixtures/` entry is in `fixtures/README.md`), `asset-provenance` (every rbxassetid/rbxthumb id, roblox.com asset URL id and AssetId/MeshId/TextureId-style number is in `assets/provenance.json`; 0 is the placeholder; place content may use only `approved` ids), `rojo-sourcemap` (`rojo sourcemap` maps each `fixtures/*.project.json`; every `.luau` under `packages/` and `fixtures/` is reached; SKIPPED without rojo), `gate-selftest` (each of them rejects a planted broken input).
- `--live-links` also requests every external URL (dead = 404/410 or unresolvable host; 401/403/429/5xx and proxy refusals are listed as unverified). Opt-in only: no tier or CI job runs it, because live link checks are flaky.
- A SKIPPED step (tool missing) fails the run, the default tier and the installed git hook included, unless it is `selene` (its Roblox std needs network) or named with `--allow-skip <step or glob>`. `--strict` allows no skips: CI runs `--tier pre-commit --strict` and the Blender job `--tier pre-release --strict`.
- The secret scan reads the working-tree copy of every file git would commit (tracked and untracked, not ignored), not the staged index, so unstaged edits count too.
- Standalone checks (run directly; `tools/check.py` lists which ones a tier runs):

| Check | Command | Passes when |
|---|---|---|
| Python unit tests | `python3 -m unittest discover -s tests -p 'test_*.py'` | every test passes; skips name a missing tool (luau-lsp, bpy), never a failure |
| Luau type analysis | `python3 tools/luau_defs.py` once (fetches into `build/luau-lsp/`, sha256-verified; `--verify` and `--check-lock` are offline), then `python3 tools/luau_analyze.py` | no file has more diagnostics than `tests/golden/luau-lsp-baseline.json`; exit 3 (SKIPPED) without a luau-lsp binary (`$LUAU_LSP` or PATH) or rojo, never a pass |
| Kit tier headers | `python3 tools/kit_tiers.py --check` | every kit module has `--!strict` and one `-- @tier T0..T4`; every T3 names a registered probe; `reports/kit-tiers.json` is current |
| Kit smoke (Lune side) | `lune run tools/lune/kit_smoke.luau` | every `*_probes` registry loads and the kitsmoke lines match `tests/golden/kit-smoke.json` |
| Asset sources | `python3 tools/asset_sources.py --check` | `assets/sources.json` and the `files` pins in `assets/provenance.json` follow policy (roblox-asset-intake) |
| Capture staleness | `python3 tools/capture_staleness.py` | exit 0 unless a record is INVALID; it lists STALE captures and Studio smoke records to redo, and `--fail-stale` fails on them (visual-qa) |

- In the editor: the repo-local Claude Code plugin `luau-lsp@roblox-factory` (`.claude-plugin/marketplace.json`, `plugins/luau-lsp`) runs the same luau-lsp with the same definitions and pushes diagnostics after each `.luau` edit. The owner enables it (docs/pc-setup.md); cloud sessions start no language server, so use `luau_analyze.py` there.
- `--update-golden=NAME[,NAME]` rewrites only the named goldens: `fixture-hashes`, `studio-smoke` (step `studio-smoke-golden`, run before the specs that check it) or a spec golden of `tests/lib/Golden.luau` such as `kit-smoke`; a named spec golden that no spec wrote FAILs. A bare `--update-golden` rewrites every golden, so always name the scope. Without the flag a missing golden FAILs, and a stray `FACTORY_UPDATE_GOLDEN` variable is ignored. `--install-git-hook` makes `git commit` run PRE_COMMIT.

## Procedure
1. Edit; read the hook's message if it flags formatting, JSON, a secret or SKILL.md frontmatter. Format Luau with `stylua <file>`.
2. Before committing run PRE_COMMIT; fix failures at the root (no skipped tests, no lowered validation limits).
3. Fixture hash changed on purpose: `python3 tools/check.py --update-golden=fixture-hashes,studio-smoke` (only the goldens that should change), and name the changed fixtures and why in the commit. A changed `studio-smoke.json` voids the Studio parity evidence until Studio reproduces it (gap matrix S02).
4. New Luau logic gets a Lune spec in `tests/*.spec.luau` (pure modules) or a Studio diagnostic (Roblox-only APIs); see roblox-luau-testing.
5. Run `python3 tools/luau_analyze.py` where luau-lsp is installed. A regression names the file and the new diagnostics (`build/luau-lsp/report.json` has all of them): fix the code, not the baseline. After fixing diagnostics, ratchet down with `--update-baseline` and say which files dropped; raising a count needs a stated reason in the commit.
6. Before a PR is ready, run PRE_RELEASE where `bpy` or Blender is installed, and name the bpy versions that ran.

## Outputs
One line per step (`[ok  ]`, `[FAIL]`, `[skip]`), a final `<tier>: PASS|FAIL; failed=[...] skipped=[...]` line, and `build/check-report.json` (`tier`, `pass`, `failed`, `skipped`, per-step detail).

## Acceptance
The tier reports PASS with `failed` empty; any SKIPPED step (only `selene` passes by default) is named in the PR or report (CI's `--strict` makes it a failure).

## Failure
- `fixture-hashes`: an unintended change is a generator or SceneKit regression; find it with `Scene.compare` on the old and new manifests (visual-qa).
- `selene` SKIPPED: it needs `selene generate-roblox-std`, which needs network to the Roblox API dump.
- `skills-sync`: edit `.agents/skills/`, then `python3 tools/sync_skills.py`; it also fails when a SKILL.md's `name` differs from its folder, the description is missing, or one of the ten `## <Section>` headings (`SECTIONS` in `tools/sync_skills.py`) is missing or empty.
- `gap-matrix`: edit `reports/gap-matrix.json`, then `python3 tools/gap_matrix.py`; never edit `docs/gap-matrix.md` by hand.
- `doc-links`: fix the path or anchor (anchors are GitHub heading slugs); a URL pattern such as `{a,b}` goes in a code span.
- `knowledge-index` / `knowledge-paths`: run `python3 tools/knowledge_index.py` after adding or editing a record or research doc; a record citing paths that exist only on the owner's PC gets `"scope": "workbench"` and an `*_on_workbench` status.
- `fixtures-readme`: add a row for the new `fixtures/` entry saying what consumes it.
- `asset-provenance`: register the id through skill roblox-asset-intake, or use 0 as the placeholder; never commit ids of private assets on the owner's account.
- `rojo-sourcemap`: a failed project names the missing `$path`; an orphan `.luau` file needs a project entry (or deleting). The step regenerates the network place's `build/network/SourceManifest.luau` first. "The rojo on PATH does not run": put Rokit's bin before Aftman's (gap matrix T09).
- `luau_analyze` FAIL "pinned definitions missing or changed": run `python3 tools/luau_defs.py`; a sha256 mismatch means the download is not the pinned file, so nothing is kept. "baseline was recorded with other definitions": the lock changed; re-record the baseline in the same commit as the lock bump and say why.
- `luau_analyze` SKIPPED (exit 3): no luau-lsp binary or no rojo for the sourcemap. Report it as SKIPPED; CI installs both with rokit.
- `kit_tiers` FAIL: add the missing header or register the probe in a `fixtures/kits/<side>/<prefix>_probes.luau` registry (roblox-studio-testing). Never lower a tier to dodge a probe.
- Toolchain missing: `rokit install`; without rokit, `cargo install stylua --features luau` and `cargo install selene lune`.

## Related
roblox-luau-testing, roblox-scene-authoring, roblox-procedural-generation, blender-asset-qa, roblox-research, roblox-asset-intake.
