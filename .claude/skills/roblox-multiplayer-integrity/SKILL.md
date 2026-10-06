---
name: roblox-multiplayer-integrity
description: Find and fix multiplayer state and server-authority bugs with the GameKit platform modules - guarded remotes (RemoteGuard, Schema, RateLimit), ownership, desync, join/leave/respawn/round transitions, combat damage authority, exploit paths, fail-closed policy and text filtering, matchmaking queues, parties and teleports - verified with Lune specs and Server & Clients multi-client tests. Use for desync, exploits, remote spam, combat bugs, "players see different things", PvP fairness, queue or party bugs.
---

# Multiplayer integrity and combat authority

## Purpose
The server owns every outcome that matters (damage, rewards, currency, positions, cooldowns, match membership) and every client sees the same state after every transition. **Gate:** production skill. It acts on a game repository only after an explicit game-build request (AGENTS.md, Boundary); in this factory repo run it only against fixtures. Never publish, spend Robux or touch production data.

## Triggers
Desync, "players see different things", exploits, remote spam, combat or hit-registration bugs, PvP fairness, bugs on join/leave/respawn/round change, unfiltered player text, queue or party bugs, failed teleports.

## Inputs
The game's remotes and replicated attributes, its state machines (round, match, player, weapon), known exploit reports and repro steps.

## Required context
- Usage guide: `docs/gamekit-platform.md` (Remotes, Policy and text, Matchmaking).
- Remotes: `packages/GameKit/RemoteGuard.luau` (closed reject reasons, rate first, no client timestamps), `Schema.luau` (NaN, inf and invalid UTF-8 always rejected), `RateLimit.luau`, `RemoteGuardRoblox.luau` (binding fails closed on an unguarded remote).
- Policy and text: `PolicyGate.luau` and `PolicyGateRoblox.luau` (fail closed), `TextFilter.luau` and `TextFilterRoblox.luau` (failure shows nothing).
- Matchmaking: `Queue.luau` (parties never split, deterministic plans), `MemoryQueueRoblox.luau`, `TeleportRoblox.luau`, `PartyRoblox.luau`.
- Network faults: `packages/Diagnostics/FaultQueue.luau`, `fixtures/network/` with `tests/diagnostics/network.luau`; `references/legacy-combat-hardening.md`.

## Tools
Lune specs (`lune run tests/run.luau gamekit_platform_remotes`, `gamekit_platform_queue`); Studio MCP in **Server & Clients** (2-4 clients): `start_stop_play`, `execute_luau`, `get_console_output`, `screen_capture`, input simulation; the probes `platform_remoteguard_flood`, `platform_policy_emulator` and `platform_party_simulator` (Party Simulator beta).

## Procedure
1. Map every RemoteEvent, RemoteFunction, UnreliableRemoteEvent and replicated attribute: who sends, what is trusted, validation, rate limit, reply. Flag client-trusted damage, rewards, currency, positions or cooldowns.
2. Declare each remote in one `RemoteGuard` (kind, `Schema` args, rate, `dedupe` for request ids, `authorize` for ownership, distance and cooldowns) and bind with `RemoteGuardRoblox.bind`, which refuses unguarded remotes.
3. Map the state machines and their transitions on join, leave, death, respawn, teleport and server shutdown. Look for stale state and duplicated handlers (connections never disconnected); call `guard:forget(player)` on leave.
4. Gate region-restricted features with `PolicyGate` predicates and route player-written text through `TextFilter.submit` before anyone else sees it.
5. Matchmaking: build tickets with `PartyRoblox.ticket`, plan with `Queue`, move tickets between servers with `MemoryQueueRoblox`, teleport with `TeleportRoblox` (with `bindRetry`). Record match membership server-side; teleport data is untrusted.
6. Test with scripted abuse: Lune specs for floods, NaN vectors, extra arguments and duplicate request ids; then Server & Clients spam from a client command bar (docs/gamekit-platform.md, Studio probes). Leave mid-action, respawn mid-reload, inject delay and loss with the FaultQueue pattern.
7. Record each exploit path: before (reproduced), fix, after (blocked) with console evidence or `guard:stats()` counts.

## Outputs
A remote/authority inventory, the guard schema table, the exploit table (path, repro, fix, evidence), server-side fixes and specs for the pure validation logic.

## Acceptance
Every remote is declared in a guard and its spec has a failure case. No client-trusted authority for damage, rewards or economy. Multi-client tests show consistent state across clients after every transition.

## Failure
- Cannot reproduce with one client: replication bugs need Server & Clients; add clients before concluding.
- A fix only works on the host: retest on a non-host client, with fault injection on.
- Teleports, MemoryStore queues and the live Party API cannot run in Studio: keep their logic in the cores and leave the adapters T4, owner-run in a published game.

## Related
roblox-persistence-and-commerce, roblox-release-pass, roblox-studio-testing, roblox-luau-testing.
