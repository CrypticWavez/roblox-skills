# SceneKit / ProcGen namespace map

Conceptual operation -> implementation (all deterministic; seeds where randomness exists).

| Concept | Call |
|---|---|
| world.inspect / measure / validate | `Scene:bounds()`, `Scene:counts()`, `Measure.*`, `Validate.scene`, `Validate.penetration(a, b)` (oriented-box overlap depth) |
| terrain.generate / sculpt / carve / paint / smooth / biome / validate | `Terrain.heightmap`, `Terrain.sculpt`, `Terrain.flatten`, `Terrain.carve`, `Terrain.paint` (height bands + slope), `Terrain.smooth`, `Terrain.validate`, `Terrain.toOps` -> `Apply.terrain` |
| building.create / floor / wall / window / door / roof / stairs / trim / interior / validate | `Building.create`, `.floor` (holes), `.wall` (openings: door/window/gap), `.windowRun`, `.roof` (gable/shed/flat+parapet), `.stairs`, `.ramp`, `.railing`, `.column`, `.arch`, `.trim`, `.foundation`, `.subdivide` |
| prop.place / scatter / align / snap / distribute | `Props.place`, `.scatter` (Poisson disc), `.alignToWall`, `.snap`, `.distribute` |
| path / road / fence | `Paths.path`, `Paths.road` (kerbs), `Paths.fence` |
| vegetation.scatter / cluster / clear | `Vegetation.scatter` (noise density), `.cluster`, `.clear` |
| lighting.apply_profile / inspect | `Lighting.apply`, `Lighting.inspect` (profiles: neutral-day, overcast, golden-hour, night, inspection-flat) |
| camera.frame / capture | `Camera.frame`, `Camera.captureSet` (front faces -Z) |
| scene.capture / compare / validate | Blender `render-manifest`, Studio `screen_capture`; `Scene.compare`; `Validate.scene` |
| layouts | `ProcGen.Dungeon/Cave/Arena/Settlement` -> `Placement.assign` -> `Validate.*` -> `SceneKit.Layout.toScene` |

Reversibility: `Apply.scene(scene, parent)` replaces the previous model of the same name by default (only if it carries `SceneKitHash`) inside one ChangeHistory recording; `{ replace = false }` keeps it; `{ dryRun = true }` returns counts and hash without creating anything.

Previews: `factory.py render-manifest` takes `scene:manifest()` JSON directly; when the manifest has no `cameras` (only `tools/lune/build_fixtures.luau` adds them) it frames the part bounds as `Camera.captureSet` does. In Studio, `Camera.captureSet` returns plain `{x, y, z}` tables: wrap them in `Vector3.new` before `CFrame.lookAt` (skill `visual-qa`). Provenance: model attributes `SceneKitHash`, `SceneKitSeed`, `SceneKitStyle`, `Provenance`; parts carry `SceneKitId`, `Role` and `asset` placeholders for approved-asset swaps.

Player-scale constants: `Measure.ENGINE` (Roblox defaults) and `Measure.GUIDE` (level-design guidelines; override per game). `Measure.sightline` and `Measure.cameraClearance` read a Scene's `specs`, not a manifest's `parts` (skill `roblox-level-design-review` shows how to export Studio parts in that shape).
