---
name: roblox-asset-intake
description: Source, vet and register third-party or Creator Store/Toolbox assets (models, meshes, audio, images, plugins) with licence/provenance records and a security review for embedded scripts, backdoors, require() by id, remote loaders and hidden welds before anything enters a project. Use for "find assets", "use this free model", Toolbox inspection and asset approval.
---

# Asset intake and security review

**Purpose.** Better visuals without importing someone else's backdoor or licence problem.

**Inputs.** Candidate asset ids/links/files, intended use, the game's style profile.

## Procedure
1. **Search** with `search_asset` (Studio MCP) or the Creator Store website; prefer Roblox-verified creators and assets without scripts. Do not buy anything.
2. **Insert only into the diagnostic place** (`insert_asset` is gated: ask Ethan once per batch). Never insert into a game place for review.
3. **Inspect** with `execute_luau`: list every `Script/LocalScript/ModuleScript`, `require(<number>)`, `getfenv`/`setfenv`, `loadstring`, `HttpService`, `MarketplaceService`, `TeleportService`, obfuscated strings, `InsertService:LoadAsset`, hidden parts with zero transparency tricks, unexpected welds/constraints, `Sound` ids, `Decal`/`Texture` ids, part count and triangle counts.
4. **Decide**: reject on any remote require/loadstring/obfuscation; strip scripts from purely visual models; run blender-asset-qa on downloaded meshes where possible.
5. **Record** provenance: asset id, creator, URL, licence/terms, date, hash of the inserted model (serialize via Rojo/Lune), modifications, decision and reviewer. Research media never becomes a production asset.
6. Replace SceneKit placeholders (`asset` attribute) only with approved entries.

**Acceptance.** Every approved asset has a provenance record and a clean script review; rejected ones list the reason.

**Related.** visual-qa, blender-asset-qa, roblox-research.
