---
name: roblox-genre-systems
description: Genre-specific audit and improvement checklists for horror pacing, obby checkpoints, RPG quests/dialogue/inventory, simulator progression, tower-defense waves/pathing, tycoon economy/rebirth, social hubs/cosmetics, ranked/leaderboards, party/matchmaking, live-ops events/shops and practice ranges. Load only the reference for the game's genre.
---

# Genre systems

**Gate.** Production skill: it acts on a game repository only after an explicit game-build request (see `FUTURE_GAME_BUILD_PROMPT.md` in the workbench). In this factory repo, run it only against fixtures. Never publish, spend Robux, create live products or touch production data without fresh approval. The genre itself is chosen by Ethan in a game-build request; this skill never picks one.

## Procedure
1. Identify the game's genre(s) from its brief and load only the matching file in `references/`:
   horror-atmosphere-and-event-flow, obby-checkpoint-and-flow, rpg-quest-dialogue-and-inventory, simulator-progression, tower-defense-wave-and-pathing, tycoon-economy-and-rebirth, social-hub-and-cosmetics, ranked-and-leaderboards, party-and-matchmaking, liveops-events-and-shop, practice-range-builder.
2. Turn the checklist into measurable acceptance items in the game's completion contract (e.g., TD paths validated with ProcGen graph checks, obby jumps with `Measure.canJump`, economy curves with fixture simulations).
3. Execute fixes through the cross-cutting skills (multiplayer integrity, persistence/commerce, UI/UX, level design, performance).

**Acceptance.** Each checklist item maps to evidence or an explicit deferral.

**Related.** roblox-level-design-review, roblox-persistence-and-commerce, roblox-multiplayer-integrity.
