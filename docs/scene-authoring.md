# SceneKit / ProcGen namespace map

Conceptual operation -> implementation (all deterministic; seeds where randomness exists).

| Concept | Call |
|---|---|
| world.inspect / measure / validate | `Scene:bounds()`, `Scene:counts()`, `Measure.*` (jump reach, door/ceiling/corridor clearance, `cameraClearance`, sightline, cover), `Validate.scene`, `Validate.penetration(a, b)` (oriented-box overlap depth) |
| terrain.generate / sculpt / carve / paint / smooth / biome / validate | `Terrain.heightmap`, `Terrain.sculpt`, `Terrain.flatten`, `Terrain.carve`, `Terrain.water`, `Terrain.paint` (height bands + slope), `Terrain.smooth`, `Terrain.validate`, `Terrain.toOps` -> `Apply.terrain` (checks every op first, one undo recording) |
| building.create / floor / wall / window / door / roof / stairs / trim / interior / decorate / validate | `Building.create` (returns per-storey walls, openings and rooms), `.floor` (holes), `.wall` (openings: door/window/gap), `.windowRun`, `.roof` (gable/shed/flat+parapet), `.stairs`, `.ramp`, `.railing`, `.column`, `.arch`, `.trim`, `.foundation`, `.subdivide`, `.decorate(scene, building, opts)` (seeded: one ceiling/wall light per room, neutral props via `alignToWall`/`distribute`, doorways, open sides and windows kept clear; `opts.sign` adds a placeholder sign above the front door) |
| model.inspect / scale / pivot / material / collision / optimize | `Model.inspect(scope)` (bounds, part/mesh/light counts, materials, anchored/collision summary, pivot offset from base centre, warnings), `Model.scale(scope, factor, { about })`, `Model.pivot(scope, "base_center" \| "center" \| CFrame)`, `Model.material(scope, { material, color, filter })`, `Model.collision(scope, { canCollide, canQuery, canTouch, collisionGroup, collisionFidelity })`, `Model.optimize(scope, { apply })` (report; opt-in safe fixes), `Model.apply(changes)`, `Model.revert(result)` |
| selection scope | Every `Model.*` op takes an Instance, a list of Instances or `Model.selection()` (Studio `Selection:Get()`; `{}` under Lune) |
| prop.place / scatter / align / snap / distribute | `Props.place`, `.scatter` (Poisson disc), `.alignToWall`, `.snap`, `.distribute` |
| lights / signs | `Props.light(scene, { pos, mount = "ceiling" \| "wall", normal, class, room, range, ... })` (non-colliding fixture part with a `light` spec -> PointLight/SpotLight/SurfaceLight child), `Props.sign(scene, { pos, normal, text })` (plate with a `sign` spec -> SurfaceGui + TextLabel; placeholder text such as `SIGN_A`); `Validate.scene` adds `light_placement` (class, range <= 60, fixture inside its room) and `sign_text` (non-empty) only when a scene has lights or signs |
| path / road / fence | `Paths.path`, `Paths.road` (kerbs), `Paths.fence` |
| vegetation.scatter / cluster / clear | `Vegetation.scatter` (noise density), `.cluster`, `.clear` |
| lighting.apply_profile / inspect | `Lighting.apply`, `Lighting.inspect` (profiles: neutral-day, overcast, golden-hour, night, inspection-flat) |
| camera.frame / capture | `Camera.frame`, `Camera.captureSet` (front faces -Z) |
| scene.capture / compare / validate | Blender `render-manifest`, Studio `screen_capture`; `Scene.compare`; `Validate.scene` |
| layouts | `ProcGen.Dungeon/Cave/Arena/Settlement` -> `Placement.assign` -> `Validate.*` -> `SceneKit.Layout.toScene` |

Reversibility: `Apply.scene(scene, parent)` replaces the previous model of the same name by default (only if it carries `SceneKitHash`) inside one ChangeHistory recording; `{ replace = false }` keeps it; `{ dryRun = true }` returns counts and hash without creating anything. `Model.*` ops plan first: `{ dryRun = true }` returns the change list (`changes`: path, property, from, to) untouched; otherwise one recording (`Apply.withUndo`) wraps the apply, a failed set restores the earlier ones, and `Model.revert(result)` restores old values in Lune too. Values are computed in SceneKit (no `GetPivot`/`ScaleTo`) so Lune and Studio take the same path; pass `{ env = require("@lune/roblox") }` in Lune. `Model.scale` does not scale joint C0/C1 (it warns; use `Model:ScaleTo` for rigs).

Studio status: `Model.*`, light/sign instances and `Building.decorate` are specced in Lune on `@lune/roblox` instances (`tests/scenekit_model.spec.luau`, `tests/scenekit_dressing.spec.luau`) but not yet run in Studio; no fixture uses them, so fixture hashes are unchanged.

Previews: `factory.py render-manifest` takes `scene:manifest()` JSON directly; when the manifest has no `cameras` (only `tools/lune/build_fixtures.luau` adds them) it frames the part bounds as `Camera.captureSet` does. In Studio, `Camera.captureSet` returns plain `{x, y, z}` tables: wrap them in `Vector3.new` before `CFrame.lookAt` (skill `visual-qa`). Provenance: model attributes `SceneKitHash`, `SceneKitSeed`, `SceneKitStyle`, `Provenance`; parts carry `SceneKitId`, `Role` and `asset` placeholders for approved-asset swaps.

Player-scale constants: `Measure.ENGINE` (Roblox defaults) and `Measure.GUIDE` (level-design guidelines; override per game). `Measure.sightline` and `Measure.cameraClearance` read a Scene's `specs`, not a manifest's `parts` (skill `roblox-level-design-review` shows how to export Studio parts in that shape).
