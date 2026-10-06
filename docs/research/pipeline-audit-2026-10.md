# Pipeline audit for production quality (verified 2026-10-06)

This is a code audit of the factory's production pipeline, from concept to release. It asks one question per stage: could a team build a top-chart-quality Roblox game of any genre with what this repo ships today? It also judges the day-one state of a game repository made with `tools/new_project.py`.

It extends [tooling-2026-10.md](tooling-2026-10.md) and [tooling-2026-10-addendum.md](tooling-2026-10-addendum.md) and the gap matrix ([reports/gap-matrix.json](../../reports/gap-matrix.json)). Six topic passes ran in parallel with this one and propose new packages. This doc cites them by file name and does not repeat their research:
- `docs/research/ui-cinematics-feel-2026-10.md` (UIKit, Cinematics, Feel);
- `docs/research/gameplay-libraries-2026-10.md` (GameKit, PlayerData over ProfileStore, Blink, Wally);
- `docs/research/genre-coverage-2026-10.md` (33 cross-genre systems, ProcGen Course, verification tiers T0 to T4);
- `docs/research/release-monetization-analytics-2026-10.md` (`tools/release_check.py`, Telemetry, commerce adapters);
- `docs/research/visual-audio-assets-2026-10.md` (Lighting schema 2, `vfx/1`, AudioGraph, asset sources);
- `docs/research/blender-animation-pipeline-2026-10.md` (`bkit/bake.py`, clips, R15 profiles).

Section 6 resolves the places where those proposals overlap or conflict.

**Method.**
- Every module in `packages/Runtime`, `packages/Creator`, `packages/Diagnostics`, `packages/Pipeline` and `packages/SceneKit` was read, and the public functions of `packages/ProcGen` were listed. Also read: `tools/blender` (factory, bkit ops, templates, QA), `tools/check.py`, `tools/new_project.py`, `templates/starter`, all 20 skills and every gap-matrix row with a status below VERIFIED.
- The commands in section 2 were run in a Linux container. Studio MCP is not reachable from the container, so every Studio claim cites a dated report in [reports/studio/](../../reports/studio/) or the gap matrix.
- Four Roblox reference pages were fetched on 2026-10-06 through the `.md` page variants (sources at the end). Library versions and licences come from `tooling-2026-10.md` section 10.
- Nothing was installed, bought or signed up for. No repository file other than this doc was changed. A starter scaffold was written to a temporary directory outside the repository and its gate was run there.

**Decision rule** (as in the addendum): **SELECT** means use now inside SETUP_ONLY; **REJECT** means do not adopt; **REVISIT** waits for a stated trigger.

---

## 1. Verdict in brief

1. **The authoring half is strong; the runtime half is mostly missing.** SceneKit (4,480 lines), ProcGen (2,978 lines) and the Blender factory are data-first, seeded, Lune- or bpy-tested and gated by golden hashes. The game-runtime half (UI, VFX, audio, animation, gameplay, persistence, analytics) is 4,124 lines of inherited first-pass code. It is diagnostic-grade. Six of its modules have no Lune case: five run only as Studio fixture scripts, and RobloxReceiptAdapter runs nowhere.
2. **A starter repo today has zero lines of game runtime code.** The scaffold copies SceneKit, ProcGen and Pipeline (about 324 KB of authoring code on disk) into `ReplicatedStorage`, which replicates to every client. `src/server`, `src/client` and `src/shared` are empty, and there is no player data, UI kit, input layer, networking layer, telemetry, or pre-release gate.
3. **The greybox-to-art link is promised but missing.** SceneKit tags its placeholder props, trees and decor with an `asset` attribute "that an approved-asset swap step can replace later" (`packages/SceneKit/Props.luau:4`). No swap step exists anywhere in the repo, so approved Blender or Creator Store models cannot reach a SceneKit scene. This is the single most important missing piece for visual quality.
4. **The inherited UI, VFX and audio modules answer the question "is it usable?" with no.**
   - NativeUI is one fixed panel, not a UI kit.
   - EffectsPool is a sound pool with a closed set of three recipes, so the pool must open up before any VFX library can use it.
   - AudioMixer is a correct gain envelope, but no module in the repo plays a sound.

   Section 4 gives details.
5. **The copied skills and the starter disagree.**
   - `roblox-release-pass` starts by running "the game repo's pre-release gate", but the starter gate has only `fast` and `pre-commit`.
   - Six of the 14 copied skills name Runtime, Creator or Diagnostics modules that a default scaffold does not copy.
6. **Studio parity is old.** The only engine evidence is two reports from 2026-10-05: the factory smoke at commit 9c12091, and the static marker round trip. Lighting, terrain, dressing, Model ops, UI, VFX, audio and animation have never been observed in Studio at HEAD (gap rows S02, S05, S07, S08, R02, B07).
7. **The sibling proposals cover most runtime gaps, but not all of them.** No pass owns a runtime animation layer, the placeholder swap, a runtime-kit Studio smoke, a capture manifest tied to scene hashes, or the starter's runtime/authoring split. Those are this doc's main deliverables (section 7).

## 2. Evidence run in this session

| Command | Result |
|---|---|
| `lune run tests/run.luau` | 117 passed, 0 failed (10 files), 16 s |
| inherited suites (`tests/runtime/run.luau`; `tests/creator/{animation,audio_movement,effects,ui,world}.luau`; `tests/diagnostics/network.luau`) | 28, 22, 6, 15, 9, 15, 11 passed (106) |
| `python3 tools/check.py --tier fast` | PASS (stylua, json-valid, secret-scan) |
| `python3 tools/new_project.py <tmp>/daydemo`, then `git init` and that repo's `python3 tools/check.py` | pre-commit PASS; Selene SKIPPED (its Roblox std needs network). `rojo build` wrote a 124 KB place. Packages: Pipeline, ProcGen, SceneKit. `src/*` hold only `.gitkeep` |
| Lune probe: `Instance.new` through `@lune/roblox` (Lune 0.10.5) | ScreenGui, Frame, UIFlexItem, CanvasGroup, StyleSheet, StyleRule, StyleLink, StyleQuery, AudioPlayer, AudioEmitter, AudioFader, Wire, InputContext, InputAction, InputBinding, ParticleEmitter, Beam, SurfaceAppearance, MaterialVariant, ColorGradingEffect, BloomEffect, Atmosphere, Sky, EditableMesh, Animator and AnimationController all construct. `FontFace`, `StyleRule.Selector` and `Wire.SourceInstance` can be set |
| same probe: layout | Reading `Frame.AbsoluteSize` errors ("missing default value"), so layout and text fit cannot be tested in Lune |
| same probe: reflection database | Version 0.728. `Workspace.FilteringEnabled` is tagged `Deprecated, Hidden, NotReplicated`; `Workspace.SignalBehavior` is `NotScriptable`; `Lighting.LightingStyle`, `PrioritizeLightingQuality` and `Workspace.AuthorityMode` exist |
| `rg` coverage map: which test files require each module | Below |

**Automated coverage per inherited module.** "Fixture" means a Studio client script under [fixtures/](../../fixtures/), which has never run in CI.

| Module | Lune cases | Other |
|---|---|---|
| Runtime/ReceiptLedger | 19 (runtime suite) + 5 (`tests/inherited.spec.luau`) | none |
| Runtime/Lifetime, Motion, AudioMixer, CommerceCatalog | in the 28 runtime cases and the inherited spec | none |
| Runtime/NativeUI, NativeEffects | **0** | `fixtures/runtime/Diagnostic.client.luau` |
| Runtime/NativeAudio | **0** | `fixtures/creator/AudioMovement.client.luau` |
| Runtime/RobloxReceiptAdapter | **0** | none |
| Creator/EffectsPool | 15 | none |
| Creator/Effects | **0** | `fixtures/creator/Effects.client.luau` |
| Creator/UI | 9 (pure validators only) | `fixtures/creator/UI.client.luau` |
| Creator/AnimationInspector, WorldInspector | 22, 15 (threshold and budget maths only) | fixtures |
| Creator/Observation | **0** | `fixtures/observation/` |
| Creator/AudioDirector, MovementProfile | 6 | fixture |
| Diagnostics/FaultQueue | 11 | `fixtures/network.project.json` |
| Pipeline/ImportInspector | 18 (`tests/import_inspector.spec.luau`) | one Studio run at 9c024fb |
| Pipeline/FactorySmoke, SceneKit/*, ProcGen/* | 117-case spec suite (every SceneKit submodule except `Style` is called through the facade) | Studio smoke at 9c12091 only |

The starter's own spec cannot even load NativeUI, Effects or Observation. It lists them in `ROBLOX_ONLY` (`templates/starter/tests/packages.spec.luau`), because they use `script.Parent` requires or `game` at load time.

## 3. Pipeline stages

Each stage gives: what exists, how it is verified today, the weakest point, and the fix. "Sibling" points to one of the six parallel docs.

### 3.1 Concept and pre-production
- **Exists.**
  - The starter's `AGENTS.md` has a Game decisions table (nine TBD fields) and a `docs/decisions.md` log.
  - Skill `roblox-genre-systems` has 11 checklist references.
  - The genre-coverage sibling has a dated chart snapshot.
  - `fixtures/briefs/*.json` are two planning briefs that nothing in this repo reads.
- **Verified.** `starter-smoke` checks that placeholders are filled. Nothing validates a decision.
- **Weakest point.** There is no machine-readable brief. `roblox-genre-systems` step 1 says "identify the genre(s) from the brief", but a game repo has no brief file, and no design-doc skeletons exist (core loop, first-time user experience, economy sheet, art bible, target devices). Visual references are MISSING (row Q05).
- **Fix.** Gap 13: `docs/design/brief.json` (`game-brief/1`, TBD allowed in every field) with genre-neutral design templates and a gate check. Add a `roblox-production-pipeline` skill that walks the stages below with entry and exit evidence. Neither picks content.

### 3.2 Greybox and level design
- **Exists.**
  - SceneKit: buildings, props, paths, vegetation, terrain plans, lighting, Measure, Validate, Model ops, Camera and Apply with undo.
  - ProcGen: dungeon, cave, arena, settlement and forest generators, with validators.
  - Skill `roblox-level-design-review`.
- **Verified.** VERIFIED_STRONG in Lune: 117 cases, sabotage cases and fixture goldens (rows S03, P01, P03). Studio parity PARTIAL: it matched at 9c12091 only (S02).
- **Weakest point.**
  - Parity at HEAD is unproven.
  - There are no course, track or lane generators, which obby, tower, racing and tower-defense maps need (sibling genre-coverage P-1).
  - `Apply.terrain` replays a heightmap as one `FillBlock` per cell (`packages/SceneKit/Apply.luau:192`). That is fine for fixtures and slow for large maps; the WriteVoxels path is selected but not implemented (addendum D).
- **Fix.** Owner re-runs the S02 steps. Then ProcGen `Course` (sibling), WriteVoxels apply (addendum), and gap 1, so a greybox can become art without being rebuilt.

### 3.3 Art and models
- **Exists.**
  - `tools/blender/bkit`: 13 templates; ops for primitives, modifiers, UVs, PBR constants, retopology, LOD and skin weights; 30 `_check` call sites in `qa.py`; export probe; round trip.
  - `Pipeline/ImportInspector` for the Studio half.
- **Verified.**
  - B01 and B04 VERIFIED_STRONG and B08 VERIFIED_ACCEPTABLE, headless on three bpy versions.
  - Studio half PARTIAL: one static marker, pivot defect found and fixed (B05).
  - Colour loss MISSING (B06). Rigged import BLOCKED_EXTERNAL (B07).
- **Weakest point.**
  - Templates are box blockouts (`templates.py` `humanoid()` joins six boxes) and are fixtures, not art.
  - More importantly, nothing moves an approved model into a scene: the `asset` placeholders in `Props.luau`, `Vegetation.luau` and `Building.luau:967` have no consumer.
- **Fix.** Gap 1: a kit registry plus `Apply.swap`, with a Blender kit export that writes nominal sizes. The sibling Blender doc covers baking (B06), avatar profiles and clips.

### 3.4 Materials and lighting
- **Exists.** `SceneKit/Style.luau`: three profiles of role to `Enum.Material` plus RGB. `SceneKit/Lighting.luau`: five profiles of Lighting plus Atmosphere. `ops.pbr_material` sets constant Principled values.
- **Verified.** `apply` and `inspect` against a Lune Lighting service; never captured in Studio (S05 PARTIAL).
- **Weakest point.**
  - No Sky, Clouds, post-processing, MaterialVariant or SurfaceAppearance path.
  - The light range cap in `SceneKit/Validate.luau` is stale (sibling visual-audio).
  - No Studio image exists of any profile.
- **Fix.** Sibling Lighting schema 2 and `material-library/1`, plus gap 8 so that every look claim has a capture tied to a commit and a scene hash.

### 3.5 Animation
- **Exists.** `ops.keyframe_clip`, clip QA and the export probe; `Creator/AnimationInspector` (read-only Studio capture); `Runtime/Motion.validateMarkers` and `contactDrift`.
- **Verified.** On the Blender side a clip survives export. Inspector maths: 22 Lune cases. Nothing has run in Studio (B07).
- **Weakest point.** There is no runtime animation layer. `roblox-animation-integration` step 3 prescribes "one Animator per rig, preload, explicit priorities, … stop or fade on state exit, a fallback when an id fails to load", and no module implements it. Neither GameKit nor Feel in the sibling docs owns it.
- **Fix.** Gap 6 (`GameKit/AnimSet`), plus the sibling Blender doc's `bkit/clips.py` and `inspectClips`.

### 3.6 UI
- **Exists.** `Runtime/NativeUI.luau` (302 lines), `Creator/UI.luau` (757 lines) and `Runtime/Motion.luau`.
- **Verified.** 9 Lune cases on string and item validators. NativeUI has no test, and its layout has not been measured since the workbench receipts (R02 WEAK).
- **Weakest point.** Neither module is a kit:
  - fixed layouts with hard-coded offsets;
  - legacy `Enum.Font.Gotham*`;
  - open and close toggle `Visible` with no transition, so the reduced-motion setting has nothing to reduce;
  - focus restore, `make()` and theme code duplicated across both files.
- **Fix.** Sibling `packages/UIKit`. Section 2's probe shows that its token, style-rule and instance-tree specs can run in Lune 0.10.5, while layout and text fit stay Studio-only. Gap 10 removes the duplication.

### 3.7 VFX and audio
- **Exists.**
  - `Creator/EffectsPool` (bounded pool, 15 cases) and `Creator/Effects` (Beam/Trail/ParticleEmitter adapter, Studio-only).
  - `Runtime/NativeEffects` (a translucent diagnostic ball).
  - `Runtime/AudioMixer` (pure gains) and `Creator/AudioDirector` (pure event routing).
  - `Runtime/NativeAudio` (SoundGroup volumes).
- **Verified.** Pool and mixer maths in Lune. Nothing in Studio at HEAD.
- **Weakest point.**
  - The pool admits only `telegraph`, `impact` and `reward` with five numeric fields.
  - No module calls `Sound:Play()` or creates an `AudioPlayer`: AudioDirector's `backend.play` is caller-supplied, and NativeAudio has no play or stop.
  - SoundGroup is the legacy route (siblings).
- **Fix.** Gap 5 (open the pool, add a template-clone adapter). Then sibling `vfx/1`, `Runtime/AudioGraph` (the probe shows AudioPlayer, Wire and AudioFader trees build in Lune) and `packages/Feel`.

### 3.8 Gameplay systems
- **Exists.** `Creator/MovementProfile` (planar preview maths) and the 11 genre checklists.
- **Verified.** 6 Lune cases (movement and audio).
- **Weakest point.** The genre-coverage sibling counts 26 of 33 cross-genre systems as missing and 7 as partial or weak (row Q07).
- **Fix.** Sibling `packages/GameKit`, with the naming decisions in section 6 and the bootstrap skeleton in gap 3 that wires it into a game repo.

### 3.9 Multiplayer and security
- **Exists.** `Diagnostics/FaultQueue` (synthetic loss, duplication and reordering), the network echo diagnostic place and skill `roblox-multiplayer-integrity`.
- **Verified.** 11 Lune cases. Echo place: workbench receipts only.
- **Weakest point.** No remote validation, no abuse harness and no Server Authority fixture (row Q03).
- **Fix.** Sibling `GameKit/Schema`, `RemoteGuard` and Blink, and the Server & Clients abuse script inside gap 7's integration place.

### 3.10 Persistence and commerce
- **Exists.**
  - `Runtime/ReceiptLedger`: grant-once `UpdateAsync` transform, v1 migration, corrupt-schema refusal.
  - `RobloxReceiptAdapter`: legacy `ProcessReceipt` callback.
  - `CommerceCatalog` and `Creator/UI.shopDisplay`: preview-only displays.
- **Verified.** The ledger is the best-tested runtime module (24 cases, including concurrent servers and lost acknowledgements). The adapter has never run.
- **Weakest point.**
  - There is no session-locked player profile.
  - The two catalog displays use different field names for the same thing (gap 9).
  - The ledger refuses every purchase after 2,048 receipts in one account (`limits.receipts`, `ReceiptLedger.luau:68` and `:205`) and has no migration helper.
- **Fix.** Sibling `GameKit/PlayerData` over ProfileStore and `Adapter.bind` on `BindReceiptHandler`, plus gap 9.

### 3.11 Analytics
- **Exists.** `fixtures/analytics/`: inputs and an expected report for a tool that lives only on the workbench (row Q08 MISSING).
- **Fix.** Sibling `GameKit/Telemetry` and the `tools/analytics_report.py` port. Gap 15 removes or wires the dead fixtures.

### 3.12 Performance and device QA
- **Exists.**
  - Static budgets: ProcGen `performance_part_estimate`, Blender triangle budgets and SceneKit `maxParts`.
  - `SceneKit.Model.optimize`: reports, and applies safe fixes.
  - `Creator/Observation` samples client `frame_ms` and `gcinfo()`.
  - Skill `roblox-performance-pass`.
- **Verified.** Static budgets in the gate. Runtime measurement: none (row Q01 PARTIAL).
- **Weakest point.** Nothing captures server heartbeat, memory categories, network rates or the Script Profiler into a report, and there are no device-tier thresholds.
- **Fix.** Gap 12 (`Diagnostics/PerfProbe` plus a report schema), with the sibling `SceneKit/Budgets.luau` as its threshold source and Device Simulator captures through Studio MCP. Physical devices stay with the owner.

### 3.13 Visual QA
- **Exists.**
  - `factory.py render-manifest`: Cycles CPU previews of manifests and templates.
  - Structural goldens: fixture hashes and the Studio smoke.
  - `Scene.compare` and skill `visual-qa`.
- **Verified.** Previews were reviewed by eye (B03). Hash goldens are in the gate (Q04 PARTIAL).
- **Weakest point.**
  - Engine-truth images are stale and are not bound to what they show: a capture records no commit or scene hash, so nobody can tell that it no longer matches HEAD.
  - No motion evidence exists, and stills cannot prove motion.
- **Fix.** Gap 8 (`Pipeline/CaptureSet` plus a capture manifest with stale detection). Motion evidence through FFmpeg owned-window capture on the PC (addendum F). Pixel baselines stay REVISIT.

### 3.14 Release
- **Exists.** Skill `roblox-release-pass`: a checklist that writes `reports/release-readiness.json` in the game repo. The guard hooks deny publishing.
- **Verified.** None (row Q02 MISSING).
- **Weakest point.** The skill's step 1 runs a pre-release tier that the starter gate does not have (`templates/starter/tools/check.py:133` accepts only `fast` and `pre-commit`).
- **Fix.** Gap 4 (starter pre-release tier and a consistency check), then the sibling `tools/release_check.py` with its A/S/O/P tiers.

## 4. Module verdicts

| Module (lines) | Tests | Studio-only | Duplicates or overlaps | Usable in a real game? | Verdict |
|---|---|---|---|---|---|
| Runtime/NativeUI (302) | none | yes, `game:GetService` | Creator/UI (panel, theme, focus restore) | **No.** One fixed screen (title, status, card grid, primary button); hard-coded offsets; legacy Gotham fonts; no transitions | Extract the state machine, focus restore and `inspect` into UIKit; then retire |
| Creator/UI (757) | 9 (validators) | `UI.new` | NativeUI; `shopDisplay` duplicates CommerceCatalog with another schema | **No** as a UI. Yes for `validateStrings`, `localize`, `guard` and `audit` | Extract those four into UIKit; retire `UI.new` |
| Runtime/Motion (105) | yes | no | UIKit `Ease` and Feel `Spring` (sibling) | Partly: `validateMarkers` and `contactDrift` are real tools; `curve` is smoothstep only | Keep the validators; point the curves at UIKit `Ease` |
| Runtime/AudioMixer (103) | yes | no | none | **Yes, as a pure gain core** (fades, ducks, master) | Keep; it becomes AudioGraph's control layer |
| Runtime/NativeAudio (66) | none | yes | AudioGraph (sibling) | **No.** Legacy SoundGroup; no play or stop; a 64-sound cap | Replace with AudioGraph |
| Creator/AudioDirector (132) | yes | no | none | Yes, as routing. No module implements its backend | Keep |
| Creator/EffectsPool (276) | 15 | no | Lifetime (a simpler scheduler) | **The pool, yes:** bounded, priority eviction, reduced effects, poisoning on a failed destructor. **The recipes, no:** closed set (`EffectsPool.luau:20`, `:72`) | Keep; open the registry (gap 5) |
| Creator/Effects (186) | none | yes | NativeEffects | **No.** A hard-coded Beam cross, no textures beyond two built-ins, no light or sound | Rewrite as the `vfx/1` template-clone adapter (gap 5) |
| Runtime/NativeEffects (33) | none | yes | Effects | Diagnostic marker only | Keep as a diagnostic |
| Runtime/Lifetime (92) | yes | no | EffectsPool, GameKit `Scope` | Yes, for bounded timed cleanup. Misused by `Creator/UI.luau:224` and `:732` as a once-only destroy guard (capacity 1, a 300 s entry nobody steps) | Keep; fix the misuse (gap 10) |
| Runtime/ReceiptLedger (266) | 24 | no | PlayerData's receipt ring (sibling) | Yes. Fails closed after 2,048 receipts per account | Keep; add a capacity policy (gap 9) |
| Runtime/RobloxReceiptAdapter (42) | none | yes | `Adapter.bind` (sibling release doc) | Legacy `ProcessReceipt` path only | Extend (sibling), and add a fake-marketplace spec |
| Runtime/CommerceCatalog (61) | yes | no | `Creator/UI.shopDisplay` | Not in a live shop: entries must be "verified and disabled" (`CommerceCatalog.luau:18`) | Unify the schema; add a game mode (gap 9) |
| Creator/AnimationInspector (451) | 22 (maths) | yes | Motion, Observation | Diagnostic. Requires a `WorkbenchOwned` rig, SHA-256 source manifests and `GameId == 0 and PlaceId == 0` | Keep as a diagnostic; relax the target guard (gap 14) |
| Creator/Observation (592) | none | yes | SceneKit.Camera (presets) | Diagnostic capture with heavy ceremony; its camera snapshot and restore are reusable (sibling Cinematics) | Keep; lift the camera lease into Cinematics |
| Creator/WorldInspector (395) | 15 (maths) | yes | SceneKit.Measure, ProcGen Validate (sightlines, spawns) | No at map scale: hard ceiling of 512 parts and 64 queries | Keep for small scopes; map review uses SceneKit and ProcGen validators |
| Creator/MovementProfile (63) | yes | no | `Measure.ENGINE` | Preview maths only | Keep |
| Diagnostics/FaultQueue (202) | 11 | no | none | Yes, as a test double for message handling (RemoteGuard specs, sibling) | Keep |
| Pipeline/ImportInspector (516) | 18 | readers only | none | Yes (static meshes) | Keep; extend for clips and kits |
| Pipeline/FactorySmoke (56) | via golden | no | none | The parity pattern to copy for runtime kits | Keep; generalise (gap 7) |
| SceneKit (16 modules, 4,480) | 117-case suite | `Apply`/`Model` Studio paths only | none | Yes for greybox. Primitive parts only (`Apply.luau` creates `Part`, `WedgePart` and `CornerWedgePart`) | Keep; add Kit and swap (gap 1) |

**Code-level duplication.**
- A local `finite()` helper is defined in 10 modules.
- `copy()` deep copies appear in ReceiptLedger, AnimationInspector and Observation.
- `make()` appears in both UI files.
- Two require styles are mixed: string requires in SceneKit, ProcGen and Pipeline; `script.Parent…` in `Creator/Effects.luau:3` and `Creator/UI.luau:193-194`. The `script.Parent` style is why the starter spec needs its `ROBLOX_ONLY` list.

## 5. The game starter on day one

A repo made today with `python3 tools/new_project.py <dest>` passes its own gate (section 2). It is safe and well-governed: guards for Claude and Codex, a decisions log, pinned tools, CI with `--strict`, and package hashes for `--update`. For building a top-chart game, it lacks the following.

| # | Missing on day one | Why it matters | Where the fix lives |
|---|---|---|---|
| 1 | Any runtime code: no server or client bootstrap, module loader, config or error boundary | Every team writes the same skeleton first, and agents invent a different one each time | Gap 3 |
| 2 | Player data with session locking, autosave and `BindToClose` | Data loss is the most expensive early bug | Sibling `GameKit/PlayerData` (ProfileStore) |
| 3 | UI kit, input actions, focus navigation, transitions | Every genre has HUD, menus and settings | Sibling UIKit; `GameKit/InputMap` (section 6) |
| 4 | Networking layer with validation and rate limits | Exploits arrive on day one of a public test | Sibling `Schema`/`RemoteGuard` and Blink |
| 5 | VFX presets, audio playback, feel cues, cutscenes | The visual and feel bar of chart games | Gap 5; siblings `vfx/1`, AudioGraph, Feel, Cinematics |
| 6 | Runtime animation state layer | Every character, NPC and tool | Gap 6 |
| 7 | Telemetry and offline report | Funnel and retention questions start at the first playtest | Sibling Telemetry |
| 8 | Engine settings as recorded decisions: StreamingEnabled, AuthorityMode, SignalBehavior, LightingStyle | Workspace docs: StreamingEnabled "is not scriptable and therefore must be set on the Workspace object in Studio". The Lune reflection database marks SignalBehavior NotScriptable. Late changes to these are costly | Gap 2 |
| 9 | A sensible Rojo tree | Authoring packages sit in `ReplicatedStorage.Workbench`, and the ReplicatedStorage docs say objects there "are fully replicated to clients". ServerStorage contents "will not replicate to the client". No `StarterGui`, `ReplicatedFirst` (loading screen), `ServerStorage` assets or `Packages` mapping exists. The template sets `Workspace.FilteringEnabled`, which the Workspace docs call "discontinued and no longer takes effect" | Gap 2 |
| 10 | A pre-release tier and release checks | The release skill assumes them | Gap 4; sibling `release_check.py` |
| 11 | Skills that match the copied packages | 6 of 14 copied skills name modules a default scaffold lacks (table below) | Gap 4 |
| 12 | A machine-readable brief and design templates | The genre-systems skill reads "the brief" | Gap 13 |
| 13 | Type checking | `luau-lsp` is pinned in `rokit.toml` but no gate runs `luau-lsp analyze` (addendum E: selected, not implemented) | Gap 11 |
| 14 | A Studio smoke for the runtime kits | Only the authoring packages have a Lune-to-Studio parity check | Gap 7 |

Copied skills that name modules a default scaffold does not copy (from `rg` over `.agents/skills/*/SKILL.md`):

| Skill | Names |
|---|---|
| `roblox-ui-ux-pass` | NativeUI, `packages/Creator/UI`, `Motion.transition` (its description says "using NativeUI tooling") |
| `roblox-performance-pass` | EffectsPool, Lifetime |
| `roblox-persistence-and-commerce` | ReceiptLedger, CommerceCatalog, RobloxReceiptAdapter |
| `roblox-luau-testing` | ReceiptLedger and its adapter (as the pattern to copy) |
| `roblox-multiplayer-integrity` | FaultQueue |
| `roblox-animation-integration` | AnimationInspector, `Motion.validateMarkers`, `Motion.contactDrift` |

## 6. Integration decisions across the sibling proposals

The six parallel docs sometimes propose two homes for one concept. One owner per concept keeps the implementation plan coherent.

| Concept | Proposals | Recommendation |
|---|---|---|
| State machine | `GameKit/Fsm` (gameplay-libraries); `GameKit/StateMachine` + `RoundLoop` (genre-coverage) | One `GameKit/Fsm`. `RoundLoop` is a validated Fsm spec plus timers, not a second engine |
| Player data | `GameKit/PlayerData` over injected ProfileStore (gameplay-libraries); `GameKit/SessionStore` + `Migrations` (genre-coverage); release check A15 says "writes only through SessionStore" | `GameKit/PlayerData` is the only public API, with migrations inside it. `tests/fakes/FakeDataStore.luau` and a ProfileStore-shaped fake are shared. Rename A15 to PlayerData |
| Cutscenes | `packages/Cinematics` (ui-cinematics); `GameKit/Sequence` (genre-coverage) | `packages/Cinematics` (the fuller spec: `cinematics/1`, sampling, skip rules) |
| Feedback and juice | `packages/Feel` (ui-cinematics); `GameKit/Feedback` (genre-coverage P-5) | `packages/Feel`. Its VFX channel uses `vfx/1` presets through the opened pool (gap 5); its sound channel uses AudioDirector over AudioGraph |
| Input | `GameKit/InputMap` (genre-coverage); UIKit `Nav` with an IAS `UI` context (ui-cinematics) | `GameKit/InputMap` owns InputContexts and actions. UIKit `Nav` consumes the `UI` context and does not create its own |
| Toasts | `GameKit/Toasts` (genre-coverage); UIKit Toast (ui-cinematics) | UIKit Toast only |
| Hit validation | `GameKit/Hitbox` with `validateClaim` (gameplay-libraries); `Combat` + `HitValidation` (genre-coverage) | `GameKit/Hitbox` only. Damage rules are game design and stay in the game repo |
| Starter defaults | UIKit, Cinematics and Feel by default (ui-cinematics); GameKit by default (gameplay-libraries); GameKit and UIKit opt-in until Studio-verified (genre-coverage) | Default-include every content-free runtime kit, so day one is not empty. `starter.json` records each module's verification tier (T0 to T3), and the generated `AGENTS.md` lists the Studio-unverified adapters (gap 3). Runtime, Creator and Diagnostics stay opt-in until gap 10 retires their duplicates |
| Package placement | `ReplicatedStorage.Packages` plus `Workbench` (gameplay-libraries) | Runtime kits in `ReplicatedStorage.Kits`; Wally in `ReplicatedStorage.Packages` and `ServerStorage.ServerPackages`; authoring packages in `ServerStorage.Authoring` (gap 2) |

## 7. Deliverables this audit adds

These are the items no sibling owns, or that the siblings depend on. Each has a container-side proof; Studio steps are owner-run on the unpublished diagnostic place.

1. **Greybox-to-art swap (P0).**
   - `SceneKit/Kit.luau`: a `kit/1` registry entry is `{ id, template, nominalSize, pivot = "base-centre", provenance, collision }`, where `template` is an Instance path string and `provenance` is an `assets/provenance.json` id or `"local-template"`.
   - `Kit.validate` checks the registry.
   - `Apply.swap(model, kit, { dryRun, tolerance })`: for every part with an `asset` attribute, clone the template, place it at the placeholder's base centre and yaw, check its size against `nominalSize`, and remove the placeholder. Unknown ids are reported. All of it runs in one ChangeHistory recording.
   - Blender half: `factory.py kit <out>` exports modular pieces at the world origin (the B05 pivot rule) and writes the matching `kit/1` sizes.
   - Lune spec on `@lune/roblox` templates: swap count; transforms equal the placeholder base (pivot maths reused from `SceneKit.Model`); dry run changes nothing; an unknown id is reported; an oversized template fails.
2. **Starter Rojo tree and engine decisions (P0).**
   - Move authoring packages to `ServerStorage.Authoring` and runtime kits to `ReplicatedStorage.Kits`. Add `StarterGui`, `ReplicatedFirst`, `ServerStorage.Assets` and the Wally mappings. Drop `Workspace.FilteringEnabled`.
   - Add an "Engine settings" TBD table (StreamingEnabled, AuthorityMode, SignalBehavior, LightingStyle and PrioritizeLightingQuality) to `AGENTS.md.tmpl`. When a value is decided, it goes in the project file or Studio, and is logged.
   - Update the copied skills that say `ReplicatedStorage.Workbench` for game repos.
   - `starter-smoke` deserialises the built place with Lune and asserts the placement.
3. **Runtime skeleton (P0).**
   - `src/server/init.server.luau`, `src/client/init.client.luau` and `src/shared/Config.luau`: a deterministic boot order (config → kits → PlayerData → remotes → Telemetry sink → UI root → input contexts), an error boundary, and injection points with no content.
   - A Lune spec drives the boot order with fakes.
4. **Starter consistency (P0).**
   - Add a `pre-release` tier to `templates/starter/tools/check.py`: pre-commit, Rojo build artifact, `luau-lsp analyze` and `release_check.py` (when present). Studio-only items are listed as BLOCKED_EXTERNAL, never PASS.
   - New `skills-packages` step: every `packages/<Pkg>/<Module>` that a copied skill names must exist in the repo, or the skill must mark it optional.
   - `starter-smoke` runs both.
5. **Open the effects pool (P0).**
   - `EffectsPool.new(adapter, { recipes, fields })`: recipes are named and validated against a field schema, and the three defaults stay as the neutral set.
   - `Effects` gains a template-clone adapter: an owned Attachment tree of ParticleEmitter, Beam, Trail and light; `Emit(n)`; disable after the duration; ParticleEmitter Lifetime is "internally capped at 20" (addendum C).
   - This unblocks sibling `vfx/1` and Feel.
6. **Runtime animation layer (P1).** `GameKit/AnimSet`:
   - Pure core: a state-to-clip table with priority order, fades, required markers (`Motion.validateMarkers`), a fallback clip and cleanup triggers.
   - Studio adapter: `Animator:LoadAnimation` with Studio-only temporary ids from `AnimationClipProvider` (sibling Blender doc).
   - Animation Graphs stay a game-repo option, because graphs "must be published as assets" (genre-coverage section 5).
7. **Runtime-kit Studio smoke (P1).**
   - `Pipeline/KitSmoke`, on the FactorySmoke pattern (Lune computes a golden; Studio Run prints `KIT_SMOKE` JSON).
   - It mounts the UIKit gallery, a Feel cue, a Cinematics fixture, an AudioGraph test cue, a SceneKit scene plus swap, and a Server & Clients RemoteGuard abuse script, in one `fixtures/kits.project.json` place.
8. **Capture manifest (P1).**
   - `Pipeline/CaptureSet`: shot lists from `Camera.captureSet` angles × lighting profiles, plus a Studio `apply(i)` that sets a Scriptable camera.
   - The agent loop is `execute_luau` (shot i), then `screen_capture`, then save.
   - `reports/studio/captures-<date>/manifest.json` records commit, scene hash, profile, shot and Studio version.
   - New gate step `capture-staleness` flags a capture set whose scene hash no longer equals the current golden.
9. **Commerce fixes (P1).**
   - One `catalog/1` schema shared by `CommerceCatalog` and the UIKit shop display. Today `CommerceCatalog.luau:22` reads `entry.id` and `Creator/UI.luau:174` reads `entry.productId`.
   - `mode = "setup" | "game"`: setup keeps "verified and disabled"; game allows enabled entries but still never prompts.
   - A ledger capacity policy: an age-out ring, or a migration helper that moves older PurchaseIds to an archive key, with specs.
10. **Inherited cleanup (P1).**
    - String requires everywhere, so every module loads in Lune and the starter's `ROBLOX_ONLY` list is empty.
    - A shared `Check` helper for `finite`, `integer` and `label`.
    - Replace the Lifetime destroy-guard misuse with `GameKit/Scope`.
    - `FontFace` instead of `Enum.Font.Gotham*`; `PreRender` instead of `RenderStepped` (ui-cinematics sibling).
11. **`luau-lsp analyze` gate step (P1).** Count a baseline over `packages/` with a Rojo sourcemap, then fail on new diagnostics. This was selected in addendum E and is not implemented. The binary is pinned (1.68.1) but absent from this container, so CI installs it through Rokit.
12. **PerfProbe (P1).** `Diagnostics/PerfProbe.luau`:
    - Pure: a report schema, per-device-tier thresholds (sibling `SceneKit/Budgets.luau`) and comparison logic.
    - Studio adapter: memory, instance and network counters plus `ScriptProfilerService` start, stop and export (the Stats member names are UNVERIFIED).
    - Writes `reports/studio/perf-*.json`.
13. **Brief and pipeline runbook (P1).**
    - `templates/starter/docs/design/brief.json` (`game-brief/1`; every field may be `"TBD"`; genre values from the official taxonomy in the genre-coverage sibling).
    - Neutral design templates (core loop, first-time user experience, economy sheet, art bible, devices), and a starter gate check of the brief schema.
    - New `roblox-production-pipeline` skill: stage order, the entry and exit evidence per stage (section 3), and which skill to load. A `docs/pipeline.json` tracker records the status and evidence path per stage.
14. **Diagnostic target guard (P2).**
    - Observation, AnimationInspector and WorldInspector assert `game.GameId == 0 and game.PlaceId == 0`. The DataModel docs say an unpublished place's PlaceId "will correspond with the template being used", so a diagnostic place made from a Studio template may be refused (UNVERIFIED in Studio).
    - Replace the guard with `RunService:IsStudio()`, a place attribute the diagnostic projects set, and a protected-ids list. Make source manifests optional (recorded as "not supplied"). Raise WorldInspector's ceilings, or chunk the scan.
15. **Dead fixtures (P2).** `fixtures/analytics`, `briefs`, `content`, `observation/neutral-case.json` and `runtime/economy_assumptions.json` are consumed by nothing (`fixtures/README.md` says so). Port their consumer (Telemetry report, brief schema) or delete them. The `fixtures-readme` step then rejects "consumed by nothing".

**Suggested order.**
1. Container-only work first: 2, 4, 5, 9, 10, 11, 15, and the pure cores of the sibling kits.
2. Then 1, 3, 6, 8, 12 and 13.
3. Then the owner's Studio session: S02 rerun, KitSmoke, captures, perf, and the asked-first imports.
4. Last, the first real scaffold pushed to GitHub, so the generated CI runs once (row T12).

## 8. Tool and API records

Only the items this audit relies on. Other candidates are in the earlier docs.

| Name | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Lune `@lune/roblox` (instance trees, `deserializePlace`, reflection database) | github.com/lune-org/lune | lune-org | 0.10.5 (bundled reflection database 0.728, observed) | 2026-07-02 (crates.io, per `tooling-2026-10.md` section 10) | active | MPL-2.0 | free |
| luau-lsp `analyze` | github.com/JohnnyMorganz/luau-lsp | JohnnyMorganz | 1.69.0 latest; repo pins 1.68.1 | 2026-07-18 | active | MIT | free |
| Rojo `build` and `sourcemap` | github.com/rojo-rbx/rojo | rojo-rbx | 7.7.1 (this container); repo pins 7.7.0 | 2026-10-02 | active | MPL-2.0 | free |
| ServerStorage / ReplicatedStorage placement | create.roblox.com docs, class pages | Roblox | engine | tracks engine | active | Roblox terms | free |
| Workspace engine settings (StreamingEnabled, FilteringEnabled, AuthorityMode) | create.roblox.com docs, Workspace class page | Roblox | engine | tracks engine | active | Roblox terms | free |

| Name | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Expected benefit | Decision |
|---|---|---|---|---|---|---|
| Lune `@lune/roblox` | Builds real Instance trees for UI styling, Audio API graphs, IAS contexts, VFX templates and kit swaps. Cannot compute layout (`AbsoluteSize` errors). Its reflection database (0.728) trails Studio (version 741 per `tooling-2026-10.md` section 10), so properties newer than 0.728 are unknown to it | local only | Studio MCP for layout and look | both agents run `lune run` | moves most kit verification to tier T0 (CI) | **SELECT** (in use). Extend the specs to instance trees |
| luau-lsp `analyze` | type and lint diagnostics with Rojo sourcemap resolution | local; downloads type definitions at setup | Selene (lint only) | CLI for both agents | catches type errors across the new kits before Studio | **SELECT**, not yet implemented (gap 11) |
| Rojo | builds the starter and fixture places; with Lune `deserializePlace`, lets the gate assert the tree layout | local | none | CLI | starter structure becomes testable (gap 2) | **SELECT** (in use) |
| ServerStorage for authoring packages | "Objects descending from ServerStorage will not replicate to the client"; ReplicatedStorage objects "are fully replicated to clients" | keeps tool code off clients | ReplicatedStorage | Rojo project | smaller client payload; authoring code stays server-side | **SELECT** (gap 2) |
| Workspace settings as recorded decisions | StreamingEnabled "is not scriptable and therefore must be set on the Workspace object in Studio"; FilteringEnabled "is discontinued and no longer takes effect"; AuthorityMode is read-only to scripts (RobloxScriptSecurity) | none | sibling Server Authority facts | owner sets them in Studio, or in the project file (Rojo support UNVERIFIED, as the visual-audio sibling also notes) | no silent defaults for settings that are expensive to change | **SELECT** (gap 2) |

Rejected in this audit:
- NativeUI or `Creator/UI.new` as the game UI kit.
- `Creator/Effects` recipes as production VFX.
- NativeAudio's SoundGroup backend.
- Shipping Runtime, Creator and Diagnostics unchanged as starter defaults.
- Layout or text-fit assertions in Lune (observed impossible).
- WorldInspector as a map-scale validator.
- Pixel baselines now (REVISIT, addendum F).
- Jest Lua inside factory packages (game repos only, gameplay-libraries sibling).
- Open Cloud Luau Execution for in-engine CI (unchanged REJECT, row D03).

## 9. Proposed gap-matrix changes (not applied here)

- **R02**: name the six modules with no Lune case. NativeUI, NativeEffects, NativeAudio, Effects and Observation are exercised only by Studio fixture scripts; RobloxReceiptAdapter by nothing. Fix: gap 10 plus KitSmoke (gap 7).
- **Q02**: add the starter's missing pre-release tier and the release-pass mismatch (gap 4).
- **Q04**: add capture staleness (gap 8).
- **Q01**: add PerfProbe (gap 12).
- **T12**: add the day-one gaps in section 5. The status stays VERIFIED_ACCEPTABLE for what it does, with a new row for the runtime skeleton.
- **New rows:**
  - greybox-to-art swap (MISSING);
  - runtime animation layer (MISSING);
  - starter Rojo tree and engine decisions (WEAK);
  - skills that name absent modules (BROKEN in game repos);
  - commerce catalog schema split (BROKEN);
  - effects pool closed recipes (PARTIAL);
  - diagnostic target guard (WEAK, UNVERIFIED);
  - dead fixture inputs (REDUNDANT).

## 10. UNVERIFIED

- GameId and PlaceId of an unpublished place created from a Studio template. The docs give PlaceId as the template's id and say nothing about GameId. This decides whether gap 14 is a defect today.
- Whether Rojo `$properties` can set `Workspace.StreamingEnabled` and `Lighting.LightingStyle`, and whether Studio keeps them.
- `Stats` member names for PerfProbe (not fetched in this pass).
- That ModuleScripts in `ServerStorage` are requireable from the Studio command bar and `execute_luau` exactly as from `ReplicatedStorage`. This is expected from the ServerStorage page ("can be accessed by the server"), but no session ran it.
- How long Roblox keeps re-delivering an unacknowledged developer-product receipt, which bounds a safe age-out window for the ledger (gap 9).
- Template-clone VFX: `ParticleEmitter:Emit` on a reused clone behaves as on a fresh one (engine behaviour, not checked).
- The generated starter CI has never run on GitHub (row T12).

## Sources (fetched 2026-10-06)

- https://create.roblox.com/docs/reference/engine/classes/Workspace.md (FilteringEnabled "discontinued and no longer takes effect"; StreamingEnabled "not scriptable"; AuthorityMode)
- https://create.roblox.com/docs/reference/engine/classes/ReplicatedStorage.md ("fully replicated to clients")
- https://create.roblox.com/docs/reference/engine/classes/ServerStorage.md ("will not replicate to the client"; maps kept there save network traffic)
- https://create.roblox.com/docs/reference/engine/classes/DataModel.md (PlaceId of an unpublished place "will correspond with the template being used")
- Versions, dates and licences of Lune, Rojo and luau-lsp: [tooling-2026-10.md](tooling-2026-10.md) section 10, which lists its own sources.
- Local execution evidence: the commands in section 2, run in this session on branch `claude/factory-second-pass-y7bey4` at commit 3dd9fa9.
