---
name: roblox-genre-systems
description: Genre-specific audit and improvement checklists for horror pacing, obby checkpoints, RPG quests/dialogue/inventory, simulator progression, tower-defense waves/pathing, tycoon economy/rebirth, social hubs/cosmetics, ranked/leaderboards, party/matchmaking, live-ops events/shops and practice ranges. Load only the reference for the game's genre.
---

# Genre systems

## Purpose
Turn a genre's known failure points into measurable acceptance items for an existing game. **Gate:** production skill. It acts on a game repository only after an explicit game-build request (AGENTS.md, Boundary); in this factory repo run it only against fixtures. The genre is chosen by Ethan in that request; this skill never picks one.

## Triggers
Auditing or improving a game whose brief names one of the genres below; writing its completion contract.

## Inputs
The game's brief (genre, target players, devices), its completion contract or requirements matrix, current build.

## Required context
Only the matching file in `references/`: horror-atmosphere-and-event-flow, obby-checkpoint-and-flow, rpg-quest-dialogue-and-inventory, simulator-progression, tower-defense-wave-and-pathing, tycoon-economy-and-rebirth, social-hub-and-cosmetics, ranked-and-leaderboards, party-and-matchmaking, liveops-events-and-shop, practice-range-builder.

## Tools
SceneKit `Measure` (jumps, sightlines, clearance), ProcGen validators (paths, loops, fairness), Lune specs for economy and progression maths, the cross-cutting skills listed under Related.

## Procedure
1. Identify the genre(s) from the brief and load only the matching reference file.
2. Turn each checklist item into a measurable acceptance item, for example tower-defense paths validated with ProcGen graph checks, obby jumps with `Measure.canJump`, economy curves with fixture simulations in a Lune spec.
3. Execute fixes through the cross-cutting skills (multiplayer integrity, persistence/commerce, UI/UX, level design, performance).
4. Re-check each item and record its evidence.

## Outputs
The game's acceptance items per checklist entry, each with evidence or an explicit deferral.

## Acceptance
Each checklist item maps to evidence from this session or an explicit, reasoned deferral.

## Failure
- No reference fits the genre: use the closest one and say which items do not apply; do not invent a genre.
- An item cannot be measured: record it as a human sign-off (fun, art, fairness), not as a pass.

## Related
roblox-level-design-review, roblox-persistence-and-commerce, roblox-multiplayer-integrity, roblox-ui-ux-pass, roblox-performance-pass.
