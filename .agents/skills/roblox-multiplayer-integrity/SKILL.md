---
name: roblox-multiplayer-integrity
description: Find and fix multiplayer state and server-authority bugs - remote validation, rate limits, ownership, desync, join/leave/respawn/round transitions, combat damage authority and exploit paths - verified with Server & Clients multi-client tests. Use for desync, exploits, combat bugs, "players see different things", PvP fairness.
---

# Multiplayer integrity and combat authority

**Gate.** Production skill: it acts on a game repository only after an explicit game-build request (see `FUTURE_GAME_BUILD_PROMPT.md` in the workbench). In this factory repo, run it only against fixtures. Never publish, spend Robux, create live products or touch production data without fresh approval.

## Procedure
1. Map every RemoteEvent/RemoteFunction/attribute replication: who sends, what is trusted, validation, rate limit, reply. Flag client-trusted damage, rewards, currency, positions or cooldowns.
2. Map state machines (round, match, player, weapon) and their transitions on join, leave, death, respawn, teleport, server shutdown. Look for stale state and duplicated handlers (connections not disconnected).
3. Fix server-side: validate types/ranges/ownership/distance/line of sight/cooldown on the server; idempotent handlers; per-player rate limits; authoritative timers.
4. Test in **Server & Clients** (2-4 clients) with scripted abuse: spam remotes, invalid args, leave mid-action, respawn mid-reload. Use `packages/Diagnostics/FaultQueue.luau` and the network fixtures for fault injection patterns.
5. Record each exploit path: before (reproduced), fix, after (blocked) with console evidence.

**Acceptance.** No client-trusted authority for damage/reward/economy; multi-client tests show consistent state across clients after every transition.

**References.** `references/legacy-combat-hardening.md`.

**Related.** roblox-persistence-and-commerce, roblox-release-pass, roblox-studio-testing.
