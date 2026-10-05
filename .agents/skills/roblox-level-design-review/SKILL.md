---
name: roblox-level-design-review
description: Measure and review a map for player scale, spawns, sightlines, cover, routes, dead zones, door/ceiling/corridor clearance, jump reach and camera clearance using SceneKit.Measure and ProcGen validators, then fix the geometry. Use for "fix bad spawns", "improve sightlines and cover", "map feels empty/cramped".
---

# Level-design review

## Purpose
Replace opinion-only map polish with measured checks, then targeted, reversible geometry fixes.

## Triggers
Map polish, spawn complaints, unfair angles, cramped interiors, unreachable areas, jumps that feel impossible, empty-looking spaces.

## Inputs
The map as a SceneKit Scene (rebuilt from its plan and seed), a ProcGen layout, or part boxes exported from a Studio place; spawn, objective and lane positions; the game's movement settings (WalkSpeed, JumpHeight, avatar scale, camera mode).

## Required context
- `packages/SceneKit/Measure.luau`. `Measure.ENGINE` holds Roblox defaults and `Measure.GUIDE` holds level-design minimums; override both per game.
  - Pure numbers: `jumpReach(rise, engine?)`, `canJump(gap, rise, margin?)` (default margin 0.15), `doorClearance(w, h)`, `ceilingClearance(h)`, `corridorWidth(w, players?)`, `coverClass(height)` (`"full"`/`"half"`/`"none"`), `slope(rise, run)`, `distance`, `horizontalDistance`, `angle`.
  - Geometry: `sightline(scene, from, to, ignoreRoles?)` returns `{visible, blocker, distance}`, and `cameraClearance(scene, characterPos, back, boom?)` returns `{clear, available}`. Points are `{x, y, z}` tables. Both read `scene.specs` (`pos`, `size`, `rot` as `{x, y, z}`, `role`, `transparency`), so they need a Scene or a `{ specs = ... }` table of that shape, not a manifest (whose `parts` store arrays). Parts with transparency of 0.5 or more never block. Boxes are axis-aligned bounds, which is conservative for rotated parts.
- ProcGen grid checks: `Validate.rooms/arena/grid`, `Validate.lineOfSight(grid, a, b)`, `grid:walkDistance(a, b)`, `grid:clearWidth(x, y)`.
- `references/legacy-map-polish.md` for the qualitative checklist.

## Tools
Lune (`lune run`) for SceneKit/ProcGen maps; Studio MCP `execute_luau` for places (`require(game.ReplicatedStorage.Workbench.SceneKit.SceneKit)` once `fixtures/factory.project.json` is synced); visual-qa for captures.

Studio part boxes in the shape `Measure` reads (`workspace.Map` is the map's root; run Measure in the same script, or `HttpService:JSONEncode` the table and decode it in Lune):
```lua
local specs = {}
for _, p in workspace.Map:GetDescendants() do
	if p:IsA("BasePart") then
		local c, s = p.CFrame, p.Size
		local rx, ry, rz = c:ToOrientation()
		table.insert(specs, { id = p:GetAttribute("SceneKitId") or p:GetFullName(), role = p:GetAttribute("Role") or p.Name,
			pos = { x = c.Position.X, y = c.Position.Y, z = c.Position.Z }, size = { x = s.X, y = s.Y, z = s.Z },
			rot = { x = math.deg(rx), y = math.deg(ry), z = math.deg(rz) }, transparency = p.Transparency })
	end
end
local map = { specs = specs } -- SK.Measure.sightline(map, a, b), SK.Measure.cameraClearance(map, pos, back)
```

## Procedure
1. Get geometry. SceneKit map: rebuild the Scene from the same plan and seed (deterministic). ProcGen map: `SceneKit.Layout.toScene(scene, layout, { wallHeight, placement })`. Studio place: the export above.
2. Measure door, ceiling and corridor clearance, `canJump` for every intended gap, `sightline` spawn-to-spawn and spawn-to-objective, `cameraClearance` in interiors, and `coverClass` along lanes.
3. Grid checks (ProcGen output, or a rasterised walkable area): connectivity, dead ends with no purpose, spawn fairness spread.
4. Rank issues by player impact; fix with SceneKit ops (move or resize walls, add cover via `Props`, widen openings), keeping changes reversible.
5. Re-measure and capture before/after views (visual-qa).

## Outputs
Issue table (location, metric, value, limit, fix), updated geometry, before/after captures.

## Acceptance
Every intended jump passes `canJump` with margin; no spawn has direct sight to an enemy spawn; corridors and doors meet the GUIDE minimums; no purposeless dead end.

## Failure
- `attempt to iterate over a nil value` in `Measure`: a manifest or raw part list was passed; pass a Scene or `{ specs = ... }`.
- A GUIDE value conflicts with the game's design: override it in the game repo and note the reason; do not delete the check.
- Rotated parts block too eagerly (AABB): confirm with a Studio raycast before moving geometry.

## Related
roblox-scene-authoring, roblox-procedural-generation, visual-qa, roblox-genre-systems.
