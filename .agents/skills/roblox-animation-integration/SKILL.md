---
name: roblox-animation-integration
description: Integrate and verify character, NPC, pet, weapon and creature animations. Covers Blender clip export (multi-clip GLB, per-clip FBX, clips/1 sidecar with standard slots, loop, root motion, priority and markers), R15 rig profiles, Animator/AnimationTrack wiring, priorities and fallbacks, markers for sounds/VFX, and equip/fire/reload/idle/inspect states, using the animation inspection tools and ImportInspector.inspectClips. Use for animation bugs, weapon feel, new clips or rigs.
---

# Animation integration

## Purpose
Clips that load, play at the right priority and length, fire their markers once and never get stuck across state changes. **Gate:** this is a production skill. It acts on a game repository only after an explicit game-build request (AGENTS.md, Boundary); in this factory repo run it only against fixtures. Never publish, upload, spend Robux or touch production data.

## Triggers
- Animation bugs: stuck, sliding, wrong priority or length, missing on other clients, markers not firing.
- Weapon feel.
- New clips or rigs.
- Equip/fire/reload/idle/inspect states.

## Inputs
- The rig: `r15_pose` (Motor6D character), `r15_avatar` (avatar body) or `custom`.
- The clip list with standard slots (`idle`, `walk`, `run`, `jump`, `fall`, `climb`, `swim`, `sit`, `land`, `action_1`..`action_8`), frame ranges, fps, loop and root-motion flags, priorities, weights and markers.
- The game's state machine.

## Required context
- `docs/runtime-kits.md` 9.4 (clips/1, frozen) and `docs/blender.md` (clips, R15 profiles, REVISIT notes on Animation Graphs and Adaptive Animation).
- `tools/blender/bkit/clips.py` (authoring and export) and `bkit/r15.py` (profiles).
- `packages/Pipeline/ImportInspector.luau` (`validateClips`, `inspectClips`, `studioClips`).
- G2's `GameKit/AnimSet`, which reads clips/1 and applies Looped, Priority and marker names.
- `packages/Creator/AnimationInspector.luau` (read-only rig and Animator snapshots; asserts an unpublished Studio client and a `WorkbenchOwned` rig) and `packages/Runtime/Motion.luau` (`validateMarkers`, `contactDrift`).
- `references/legacy-weapons-animations.md`.

## Tools
- Blender:
  - `clips.add_clip` and `clips.export_clips`;
  - `factory.py template pet_follower <dir>` as the worked example;
  - `factory.py qa` (`clip_*`, `marker_in_range`, `rig_profile*`);
  - `python3 tools/gltf_validate.py <asset>_clips.glb`, which lists animations and durations.
- Studio:
  - the 3D Importer or the Animation Clip Editor import (saves to `ServerStorage.RBX_ANIMSAVES`);
  - `tests/engine/import_clips.luau` (T3 probe);
  - MCP `execute_luau`, `start_stop_play`, `get_console_output`, `screen_capture`.
- Lune: `tests/import_inspector.spec.luau` and `tests/creator/animation.luau`.

## Procedure
1. Rig: name the bones for the profile. `r15_pose` drives the standard character: `HumanoidRootPart > LowerTorso > ...`, with the character's left at +X when facing -Y. `rig_profile*` QA must pass.
2. Author each clip as one action with `clips.add_clip(rig, name, keys, fps, start, end, loop, slot, root_motion, priority, weight, markers)`:
   - a loop's last frame repeats its first pose (`clip_loop_closed`);
   - in-place clips keep the root still (`clip_in_place`);
   - markers sit inside the range.
3. Export with `clips.export_clips`. It writes `<asset>_clips.glb` (one glTF animation per clip), `<asset>_<clip>.fbx` (Roblox's recipe: the clip's own range, every frame) and `<asset>_clips.json`. Validate the GLB with `gltf_validate.py` and the sidecar with `ImportInspector.validateClips`.
4. Import on the diagnostic place.
   - Uploading creates assets under the owner's account, so ask first. The Clip Editor import is local until uploaded.
   - Run `import_clips.luau`, which checks every clip present, lengths within half a frame and markers, and reports the play plan. Where Import 3D stores clips is UNVERIFIED until it runs.
5. Wire with AnimSet or by hand:
   - one Animator per rig, with preloading;
   - priorities from the sidecar, defaulting by slot (Idle < Movement < Action < Action4);
   - Looped from the sidecar, because files do not carry it;
   - stop or fade on state exit;
   - a fallback when an id fails to load.
6. Markers drive sounds/VFX (`GetMarkerReachedSignal`). Names and frames come from the sidecar, because FBX markers reaching Studio is UNVERIFIED. Check order with `Motion.validateMarkers` and check that each fires once per play.
7. Verify in Test and in Server & Clients: tracks replicate, and nothing keeps playing after death, unequip or respawn.

## Outputs
- A state table (state, track, priority, loop, markers, fallback) with Studio evidence per row.
- The clip files, the clips/1 sidecar and their QA and gltf-validate reports.
- The `import_clips` probe output.

## Acceptance
- Every row of the state table was observed in Studio this session.
- `inspectClips(...).pass` is true.
- There are no orphan tracks after transitions, and markers fire once per play.
- The sidecar validates against clips/1, and clip QA passes on the `.blend`.

## Failure
- Clip missing after import: check the file with blender-asset-qa and `gltf_validate.py`.
  - FBX: one clip per file; NLA baking off.
  - GLB: one animation per clip.
- Wrong length: FBX forced start/end keys or simplification. Use `clips.export_clip_fbx`.
- Clip plays mirrored or on the wrong limbs: the bone sides are swapped (`rig_profile_sides`) or the bone names do not match the parts (`clip_bones_known`).
- Foot sliding: sample positions with `Motion.contactDrift` or AnimationInspector contact segments before re-keying. Check `root_motion` against the clip.
- Track never stops: find the state exit without `:Stop()` and the connection that was never disconnected.
- A blend tree or state machine is needed: Animation Graphs are REVISIT, because graphs must be published as assets (`docs/blender.md`). Custom rigs needing R15 clips: Adaptive Animation is also REVISIT.

## Related
blender-asset-factory, blender-asset-qa, blender-roblox-roundtrip, roblox-studio-testing, roblox-multiplayer-integrity.
