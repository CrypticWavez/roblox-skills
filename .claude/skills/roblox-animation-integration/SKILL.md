---
name: roblox-animation-integration
description: Integrate and verify character, NPC, weapon and creature animations - Blender clip export, Animator/AnimationTrack wiring, priorities and fallbacks, markers for sounds/VFX, equip/fire/reload/idle/inspect states - using the animation inspection tools. Use for animation bugs, weapon feel, new clips or rigs.
---

# Animation integration

**Gate.** Production skill: it acts on a game repository only after an explicit game-build request (see `FUTURE_GAME_BUILD_PROMPT.md` in the workbench). In this factory repo, run it only against fixtures. Never publish, spend Robux, create live products or touch production data without fresh approval.

**Required context.** `packages/Creator/AnimationInspector.luau` (rig and track inspection), `blender-asset-factory` (rig names, one clip per export), `references/legacy-weapons-animations.md`.

## Procedure
1. Source: build/modify clips in Blender (`ops.keyframe_clip`), export one clip per FBX; QA confirms the clip survives export.
2. Import via the Animation Editor/importer on the diagnostic place; uploading creates assets under Ethan's account (ask first).
3. Wire: one Animator per rig, preload, explicit priorities (Idle < Movement < Action < Action4), stop/fade on state exits, fallbacks when an id fails to load.
4. Markers drive sounds/VFX (`GetMarkerReachedSignal`); test each marker fires once per play.
5. Verify in Test and Server & Clients: replication of tracks, no stuck tracks after death/unequip.

**Acceptance.** State table (state, track, priority, loop, markers) all observed in Studio with evidence; no orphan tracks after transitions.

**Related.** blender-asset-factory, roblox-studio-testing.
