---
name: roblox-animation-integration
description: Integrate and verify character, NPC, weapon and creature animations - Blender clip export, Animator/AnimationTrack wiring, priorities and fallbacks, markers for sounds/VFX, equip/fire/reload/idle/inspect states - using the animation inspection tools. Use for animation bugs, weapon feel, new clips or rigs.
---

# Animation integration

## Purpose
Clips that load, play at the right priority, fire their markers once and never get stuck across state changes. **Gate:** production skill. It acts on a game repository only after an explicit game-build request (AGENTS.md, Boundary); in this factory repo run it only against fixtures. Never publish, upload, spend Robux or touch production data.

## Triggers
Animation bugs (stuck, sliding, wrong priority, missing on other clients), weapon feel, new clips or rigs, equip/fire/reload/idle/inspect states.

## Inputs
Rig (R15-named or custom), clip list with intended states, priorities and loop flags, required markers, the game's state machine.

## Required context
`packages/Creator/AnimationInspector.luau` (read-only rig/Animator snapshots and marker subscriptions; asserts an unpublished Studio client and a `WorkbenchOwned` rig), `packages/Runtime/Motion.luau` (`validateMarkers`, `contactDrift`), blender-asset-factory (rig names, one clip per export), `references/legacy-weapons-animations.md`.

## Tools
Blender `ops.keyframe_clip` + `factory.py qa` (clip survives export); Studio Animation Editor/importer; Studio MCP `execute_luau`, `start_stop_play`, `get_console_output`, `screen_capture`; Lune for pure helpers (`tests/creator/animation.luau` is the existing suite).

## Procedure
1. Source: build or modify clips in Blender (`ops.keyframe_clip`), one clip per FBX; QA confirms the clip survives export (`animation_clip`, export probe).
2. Import via the Animation Editor/importer on the diagnostic place. Uploading creates assets under Ethan's account: ask first.
3. Wire: one Animator per rig, preload, explicit priorities (Idle < Movement < Action < Action4), stop or fade on state exit, a fallback when an id fails to load.
4. Markers drive sounds/VFX (`GetMarkerReachedSignal`); check names and order with `Motion.validateMarkers` and that each marker fires once per play.
5. Verify in Test and Server & Clients: tracks replicate, nothing stays playing after death, unequip or respawn.

## Outputs
State table (state, track, priority, loop, markers, fallback) with Studio evidence per row; the clip files and their QA reports.

## Acceptance
Every row of the state table observed in Studio this session; no orphan tracks after transitions; markers fire once per play.

## Failure
- Clip missing after import: check the FBX with blender-asset-qa (NLA baking, one action per export).
- Foot sliding: sample positions and use `Motion.contactDrift` or AnimationInspector contact segments before re-keying.
- Track never stops: find the state exit without `:Stop()` and the connection that was never disconnected.

## Related
blender-asset-factory, roblox-studio-testing, roblox-multiplayer-integrity.
