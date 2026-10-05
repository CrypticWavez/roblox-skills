---
name: luau-quality
description: Format, lint and test Luau and the factory's Python/Blender tooling with the repo gates - StyLua, Selene, Lune unit tests, fixture builds, Blender QA - in fast/pre-commit/pre-release tiers. Use after editing any .luau/.py file and before committing.
---

# Quality gates

| Tier | When | Command | Time |
|---|---|---|---|
| FAST_ON_EDIT | automatic Claude hook after Edit/Write | `tools/hooks/fast_on_edit.py` (format check, JSON parse, secret scan of the touched file) | < 1 s |
| PRE_COMMIT | before every commit | `python3 tools/check.py --tier pre-commit` (stylua --check, selene, `lune run tests/run.luau`, skill sync check, manifest/JSON validity, secret scan of staged files) | ~10 s |
| PRE_RELEASE | before a PR is marked ready / CI | `python3 tools/check.py --tier pre-release` (pre-commit + fixture builds + Blender templates + round-trip) | minutes |

## Procedure
1. Edit; read the hook's message if it flags formatting or JSON errors.
2. Before committing run PRE_COMMIT; fix failures at the root (no skipping tests, no lowering validation limits silently).
3. New Luau logic gets a Lune spec in `tests/*.spec.luau` (pure modules) or a Studio diagnostic (Roblox-only APIs).
4. Install hooks for git once: `python3 tools/check.py --install-git-hook`.

**Toolchain.** Pinned in `rokit.toml` (rojo, lune, stylua with Luau syntax, selene, luau-lsp). In cloud sessions without rokit: `cargo install stylua --features luau`, `cargo install selene lune`.

**Related.** roblox-luau-testing, roblox-scene-authoring.
