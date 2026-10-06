---
name: roblox-asset-intake
description: Source, vet and register third-party or Creator Store/Toolbox assets (models, meshes, audio, images, plugins) with licence/provenance records and a security review for embedded scripts, backdoors, require() by id, remote loaders and hidden welds before anything enters a project. Use for "find assets", "use this free model", Toolbox inspection and asset approval.
---

# Asset intake and security review

## Purpose
Better visuals without importing someone else's backdoor or licence problem. Nothing enters a project without a provenance record and a clean script review.

## Triggers
"Find assets", "use this free model", Toolbox/Creator Store inspection, a plugin or mesh from outside, replacing SceneKit placeholders with real assets.

## Inputs
Candidate asset ids, links or files; intended use; the game's style profile.

## Required context
`docs/mcp.md` (safety gates: `insert_asset` asks first), `references/legacy-creator-store.md`, `assets/provenance.json` (the provenance registry: its `policy` and `fields` say what an entry needs), research and records listed in `knowledge/INDEX.md`.

## Tools
Studio MCP `search_asset`, `insert_asset` (gated), `execute_luau` (inspection), `search_game_tree`; `python3 tools/blender/factory.py qa <file>` for downloaded meshes; Lune `@lune/roblox` (`serializeModel`) to hash an inserted model.

## Procedure
1. **Search** with `search_asset` or the Creator Store website; prefer Roblox-verified creators and assets without scripts. Do not buy anything.
2. **Insert only into the diagnostic place** (`insert_asset` asks Ethan once per batch). Never insert into a game place for review.
3. **Inspect** with `execute_luau`: list every Script/LocalScript/ModuleScript, `require(<number>)`, `getfenv`/`setfenv`, `loadstring`, `HttpService`, `MarketplaceService`, `TeleportService`, `InsertService:LoadAsset`, obfuscated strings, invisible or hidden parts, unexpected welds/constraints, Sound/Decal/Texture ids, part and triangle counts.
4. **Decide**: reject on any remote require, loadstring or obfuscation; strip scripts from purely visual models; run blender-asset-qa on downloaded meshes where possible.
5. **Record** provenance in `assets/provenance.json`, approved or not: `id`, `kind`, `name`, `source` URL, `creator`, `license`, `approval` (`approved`, `research_citation` or `rejected`), `reviewer` and `script_review` (findings, model hash, modifications; required for `approved`), `date`, `purpose`, `origin` (`intake`). Research media never becomes a production asset. Never commit ids of private assets on the owner's account.
6. Replace SceneKit placeholders (the part `asset` attribute) only with approved entries. The gate step `asset-provenance` fails on any unregistered asset id in a committable file (0 is the placeholder) and on any id that is not `approved` in place content (`.luau`, `.project.json`, `.model.json`, `.rbxmx`).

## Outputs
An `assets/provenance.json` entry per candidate (approved or rejected with reason) and the script-review findings.

## Acceptance
Every approved asset has a registry entry with reviewer and a clean script review; every rejected one lists the reason; `python3 tools/check.py` passes `asset-provenance`.

## Failure
- Any script whose purpose you cannot explain: reject, or strip it and record that.
- Licence unclear: reject; never assume Creator Store items are free to reuse.
- A hook asked or denied: insertion and uploads are gated on purpose; do not work around it.
- `asset-provenance` fails: register the id with an honest `approval` (or replace it with 0); never mark an id `approved` to get green.

## Related
roblox-research, blender-asset-qa, visual-qa.
