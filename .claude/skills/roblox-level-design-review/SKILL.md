---
name: roblox-level-design-review
description: Measure and review a map for player scale, spawns, sightlines, cover, routes, dead zones, door/ceiling/corridor clearance, jump reach and camera clearance using SceneKit.Measure and ProcGen validators, then fix the geometry. Use for "fix bad spawns", "improve sightlines and cover", "map feels empty/cramped".
---

# Level-design review

**Purpose.** Replace opinion-only map polish with measured checks, then targeted fixes.

**Triggers.** Map polish, spawn complaints, unfair angles, cramped interiors, unreachable areas, empty-looking spaces.

**Inputs.** The map (Studio place or SceneKit/ProcGen manifest), game movement settings (WalkSpeed, JumpHeight, avatar scale, camera mode).

**Required context.** `packages/SceneKit/Measure.luau` (ENGINE vs GUIDE values; override GUIDE per game), `references/legacy-map-polish.md` for the qualitative checklist.

## Procedure
1. Export geometry: in Studio, `execute_luau` a script that walks the map and returns part boxes (or start from the SceneKit manifest).
2. Measure: door/ceiling/corridor clearance, `Measure.jumpReach/canJump` for every intended gap, `Measure.sightline` spawn-to-spawn and spawn-to-objective, `Measure.cameraClearance` in interiors, `Measure.coverClass` along lanes.
3. Grid-based checks (rasterise walkable area or reuse ProcGen output): connectivity, dead ends with no purpose, spawn fairness spread.
4. Rank issues by player impact; fix with SceneKit ops (move/resize walls, add cover via `Props`, widen openings) keeping changes reversible.
5. Re-measure; capture before/after views (visual-qa).

**Outputs.** Issue table (location, metric, limit, fix), updated geometry, before/after captures.

**Acceptance.** Every intended jump passes `canJump` with margin; no spawn has direct sight to an enemy spawn; corridors and doors meet GUIDE minimums; no purposeless dead end.

**Failure handling.** If a GUIDE value conflicts with the game's design, override it in the game repo and note the reason, do not delete the check.

**Related.** roblox-scene-authoring, roblox-procedural-generation, visual-qa.
