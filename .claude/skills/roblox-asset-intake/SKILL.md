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
`docs/mcp.md` (safety gates: `insert_asset` asks first), `references/legacy-creator-store.md`, existing records in `knowledge/records/`.

## Tools
Studio MCP `search_asset`, `insert_asset` (gated), `execute_luau` (inspection), `search_game_tree`; `python3 tools/blender/factory.py qa <file>` for downloaded meshes; Lune `@lune/roblox` (`serializeModel`) to hash an inserted model.

## Procedure
1. **Search** with `search_asset` or the Creator Store website; prefer Roblox-verified creators and assets without scripts. Do not buy anything.
2. **Insert only into the diagnostic place** (`insert_asset` asks Ethan once per batch). Never insert into a game place for review.
3. **Inspect** with `execute_luau`: list every Script/LocalScript/ModuleScript, `require(<number>)`, `getfenv`/`setfenv`, `loadstring`, `HttpService`, `MarketplaceService`, `TeleportService`, `InsertService:LoadAsset`, obfuscated strings, invisible or hidden parts, unexpected welds/constraints, Sound/Decal/Texture ids, part and triangle counts.
4. **Decide**: reject on any remote require, loadstring or obfuscation; strip scripts from purely visual models; run blender-asset-qa on downloaded meshes where possible.
5. **Record** provenance: asset id, creator, URL, licence/terms, date, model hash, modifications, decision and reviewer. Research media never becomes a production asset.
6. Replace SceneKit placeholders (the part `asset` attribute) only with approved entries.

## Outputs
A provenance record per candidate (approved or rejected with reason) and the script-review findings.

## Acceptance
Every approved asset has a provenance record and a clean script review; every rejected one lists the reason.

## Failure
- Any script whose purpose you cannot explain: reject, or strip it and record that.
- Licence unclear: reject; never assume Creator Store items are free to reuse.
- A hook asked or denied: insertion and uploads are gated on purpose; do not work around it.

## Related
roblox-research, blender-asset-qa, visual-qa.
