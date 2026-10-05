---
name: roblox-multiplayer-integrity
description: Find and fix multiplayer state and server-authority bugs - remote validation, rate limits, ownership, desync, join/leave/respawn/round transitions, combat damage authority and exploit paths - verified with Server & Clients multi-client tests. Use for desync, exploits, combat bugs, "players see different things", PvP fairness.
---

# Multiplayer integrity and combat authority

## Purpose
The server owns every outcome that matters (damage, rewards, currency, positions, cooldowns) and every client sees the same state after every transition. **Gate:** production skill. It acts on a game repository only after an explicit game-build request (AGENTS.md, Boundary); in this factory repo run it only against fixtures. Never publish, spend Robux or touch production data.

## Triggers
Desync, "players see different things", exploits, combat or hit-registration bugs, PvP fairness, bugs on join/leave/respawn/round change.

## Inputs
The game's remotes and replicated attributes, its state machines (round, match, player, weapon), known exploit reports and repro steps.

## Required context
`packages/Diagnostics/FaultQueue.luau` (synthetic delay and packet loss for diagnostic packets), `fixtures/network/` (echo client/server and settings) with `tests/diagnostics/network.luau`, `references/legacy-combat-hardening.md`.

## Tools
Studio MCP in **Server & Clients** (2-4 clients): `start_stop_play`, `execute_luau`, `get_console_output`, `screen_capture`, input simulation; Lune specs for pure validation logic.

## Procedure
1. Map every RemoteEvent, RemoteFunction and replicated attribute: who sends, what is trusted, validation, rate limit, reply. Flag client-trusted damage, rewards, currency, positions or cooldowns.
2. Map the state machines and their transitions on join, leave, death, respawn, teleport and server shutdown. Look for stale state and duplicated handlers (connections never disconnected).
3. Fix on the server: validate types, ranges, ownership, distance, line of sight and cooldowns; idempotent handlers; per-player rate limits; authoritative timers.
4. Test in Server & Clients with scripted abuse: spam remotes, invalid arguments, leave mid-action, respawn mid-reload; inject delay and loss with the FaultQueue pattern.
5. Record each exploit path: before (reproduced), fix, after (blocked) with console evidence.

## Outputs
A remote/authority inventory, the exploit table (path, repro, fix, evidence), server-side fixes and specs for the pure validation logic.

## Acceptance
No client-trusted authority for damage, rewards or economy; multi-client tests show consistent state across clients after every transition.

## Failure
- Cannot reproduce with one client: replication bugs need Server & Clients; add clients before concluding.
- A fix only works on the host: retest on a non-host client, with fault injection on.

## Related
roblox-persistence-and-commerce, roblox-release-pass, roblox-studio-testing, roblox-luau-testing.
