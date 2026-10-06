---
name: roblox-asset-intake
description: Source, vet and register third-party or Creator Store/Toolbox assets (models, meshes, audio, images, plugins) with licence/provenance records and a security review for embedded scripts, backdoors, require() by id, remote loaders and hidden welds before anything enters a project; fetch CC0 files (textures, HDRIs, models) from the allow-listed sources with a per-item pin, sha256 and licence-text evidence. Use for "find assets", "use this free model", Toolbox inspection, CC0 texture or model fetches and asset approval.
---

# Asset intake and security review

## Purpose
Better visuals without importing someone else's backdoor or licence problem. Nothing enters a project without a provenance record and a clean script review.

## Triggers
"Find assets", "use this free model", Toolbox/Creator Store inspection, a plugin or mesh from outside, a CC0 texture, HDRI or model file for a bake or material library, replacing SceneKit placeholders with real assets.

## Inputs
Candidate asset ids, links or files (for CC0 files: an `assets/sources.json` key and item id); intended use; the game's style profile.

## Required context
`docs/mcp.md` (safety gates: `insert_asset` asks first), `references/legacy-creator-store.md`, `assets/provenance.json` (the provenance registry: `policy` and `fields` for Roblox asset ids in `assets`, `files_policy` and `files_fields` for fetched files in `files`), `assets/sources.json` (asset-sources/1: at most 12 CC0 sources, each with its host, item pattern, allowed types and size cap, and the pinned CC0 legal code text), `docs/research/visual-audio-assets-2026-10.md` section 6.5, research and records listed in `knowledge/INDEX.md`.

## Tools
- Studio MCP `search_asset`, `insert_asset` (gated), `execute_luau` (inspection), `search_game_tree`; Lune `@lune/roblox` (`serializeModel`) to hash an inserted model.
- `python3 tools/blender/factory.py qa <file>` for downloaded meshes.
- CC0 files: `python3 tools/fetch_assets.py --list`; `--source <key> --item <id>` is a dry run (no network, no writes); `--pin --purpose "..."` fetches, verifies and records; a manual source (Kenney, Quaternius) takes `--from-file <zip>` that the owner downloaded.
- `python3 tools/asset_sources.py --check` validates `assets/sources.json` and every `files` pin in `assets/provenance.json` (CC0 only, allow-listed hosts, anchored item patterns, no item pinned twice, only JSON and Markdown under `assets/`).

## Procedure
1. **Search** with `search_asset` or the Creator Store website; prefer Roblox-verified creators and assets without scripts. Do not buy anything.
2. **Insert only into the diagnostic place** (`insert_asset` asks the owner once per batch). Never insert into a game place for review.
3. **Inspect** with `execute_luau`: list every Script/LocalScript/ModuleScript, `require(<number>)`, `getfenv`/`setfenv`, `loadstring`, `HttpService`, `MarketplaceService`, `TeleportService`, `InsertService:LoadAsset`, obfuscated strings, invisible or hidden parts, unexpected welds/constraints, Sound/Decal/Texture ids, part and triangle counts.
4. **Decide**: reject on any remote require, loadstring or obfuscation; strip scripts from purely visual models; run blender-asset-qa on downloaded meshes where possible.
5. **Record** provenance in `assets/provenance.json`, approved or not: `id`, `kind`, `name`, `source` URL, `creator`, `license`, `approval` (`approved`, `research_citation` or `rejected`), `reviewer` and `script_review` (findings, model hash, modifications; required for `approved`), `date`, `purpose`, `origin` (`intake`). Research media never becomes a production asset. Never commit ids of private assets on the owner's account.
6. **CC0 files** take the fetch route instead of steps 2 to 5:
   - Pick the item on the source's site, then dry-run `fetch_assets.py --source <key> --item <id>` and show the owner the URL and the cache folder.
   - Run `--pin` only with the owner's approval for that one item. It refuses non-CC0 sources, items outside the pattern, a licence text whose sha256 differs, the wrong file type, oversize files and unsafe zip members.
   - The file lands in `build/asset-cache/<key>/<item>/` (gitignored) and is never committed. The pin is a `files` entry: `source_key`, `item`, `url`, `sha256`, `bytes`, `type`, `licence`, `licence_text_sha256`, `date`, `purpose`, `approval: pinned`.
   - A model file still goes through blender-asset-qa. Kits cite a pinned file as `cc0:<source_key>:<item>`.
   - Adding a source: CC0-1.0 only, one of the hosts `tools/asset_sources.py` allows, never the Poly Haven API host. Run `asset_sources.py --check`.
7. Replace SceneKit placeholders (the part `asset` attribute) only with approved entries. The gate step `asset-provenance` fails on any unregistered asset id in a committable file (0 is the placeholder) and on any id that is not `approved` in place content (`.luau`, `.project.json`, `.model.json`, `.rbxmx`).

## Outputs
An `assets/provenance.json` entry per candidate (approved or rejected with reason) and the script-review findings; for CC0 files, a `files` pin and the cache folder under `build/`.

## Acceptance
Every approved asset has a registry entry with reviewer and a clean script review; every rejected one lists the reason; every fetched file has a `files` pin whose sha256 matches the cache; `python3 tools/check.py` passes `asset-provenance` and `python3 tools/asset_sources.py --check` reports 0 problems.

## Failure
- Any script whose purpose you cannot explain: reject, or strip it and record that.
- Licence unclear: reject; never assume Creator Store items are free to reuse.
- A hook asked or denied: insertion and uploads are gated on purpose; do not work around it.
- `asset-provenance` fails: register the id with an honest `approval` (or replace it with 0); never mark an id `approved` to get green.
- `fetch_assets.py` refuses: the licence text changed (the source moved its legal code; re-verify before touching the pin), the sha256 differs from an existing pin (the file changed upstream; pin a new item instead), a redirect left the allow-listed hosts, or the type or size is outside the source's limits. Never widen a limit or a host to get a file through.
- The proxy blocks the host: record it as BLOCKED_EXTERNAL; download on the owner's PC and pin with `--from-file` only for a manual source.

## Related
roblox-research, blender-asset-qa, visual-qa.
