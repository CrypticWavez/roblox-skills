---
name: roblox-gameplay-kit
description: Build real-time gameplay from the GameKit action modules - rounds, health and damage, cooldowns, status effects, knockback, lag-compensated hit validation, projectiles, zones and race courses, abilities, movement, vehicles, interaction prompts and animation sets - with pure cores, thin Roblox adapters and Server Authority rules (BindToSimulation, IAS input, 64 attributes). Use when wiring combat, rounds, shooters, battlegrounds, racing, obby, horror or arena systems, or when reviewing hit registration, cooldown abuse, teleport or rapid-fire exploits.
---

# Gameplay kit (GameKit action systems)

## Purpose
Compose server-authoritative gameplay from the GameKit modules instead of one-off scripts: every rule (damage, rate of fire, rewind window, zone effects, round timing) runs in a pure, deterministic core that Lune tests, and only a thin `<Name>Roblox` adapter touches the engine. **Gate:** in this factory repo the kit is built and tested against fixtures only; using it in a game happens in a separate game repository after an explicit game-build request (AGENTS.md, Boundary). No content ships: ids, numbers, effect kinds and clip names are the game's.

## Triggers
A round loop, health or damage, cooldowns, buffs and debuffs, knockback, melee or ranged hit detection, projectiles, zones (hazards, kill volumes, checkpoints, lap gates), abilities, sprint/dash/slide/ledge movement, cars, interaction prompts, animation slots; exploit reports about hit distance, rapid fire, teleporting, cooldown abuse or forged touches; Server Authority migration.

## Inputs
The game's systems list (which modules), its data (ability, zone, effect, vehicle and clip definitions), the authority model (what the server owns, what clients send), and for animation a clips/1 sidecar from the Blender pipeline.

## Required context
- `docs/gamekit-action.md`: the API reference for every action module, the exploit coverage table and the UNVERIFIED list.
- `docs/gamekit-economy.md`: the economy and progression modules (wallet, inventory, odds, trade, plots, crafting, seasons, dialogue, onboarding) and their save formats.
- `docs/runtime-kits.md`: the frozen contract (sections 2 core plus adapter, 3 Env, 5 tiers, 6 Server Authority rules, 7 probes, 11 module list).
- `fixtures/kits/shared/authority_Arena.luau`: a worked composition (RoundLoop, Movement, Vitals, Cooldowns, Hitbox validator, Zones) with its server and client scripts in `fixtures/kits/server/authority_Sim.server.luau` and `fixtures/kits/client/authority_Input.client.luau`.
- `tests/gamekit_slices_action.spec.luau`: seeded slices (round_arena, time_trial) showing bots, exploits and digests.

## Tools
Lune (`lune run tests/run.luau gamekit_action`, `gamekit_slices_action`), Rojo (`rojo build fixtures/kits.project.json -o build/kits.rbxl`), the probe registries `fixtures/kits/server/action_probes.luau` and `fixtures/kits/shared/authority_probes.luau` with their Studio entries `tests/engine/action_*.luau`, and Studio MCP (coordinator only) for probe runs on the unpublished kits place.

Module index (docs/runtime-kits.md section 11; T3 = needs its Studio probe, T4 = needs a published place or live service). Action modules (G2), with when to use them:

| Module | Tier | Use when |
|---|---|---|
| `GameKit/RoundLoop` | T0 | lobby, intermission, active, results; minPlayers, late-join policy (spectate, queue, join), last standing |
| `GameKit/RoundLoopRoblox` | T3 | replicate a round as attributes from a BindToSimulation step |
| `GameKit/Vitals` | T0 | health, shield, stamina; damage with modifiers (crit, resist, armour, cap), death, downed, revive, regen, kill credit |
| `GameKit/Cooldowns` | T0 | any server-clock cooldown or charge count (weapons, dashes, interactions) |
| `GameKit/StatusEffects` | T0 | stun, slow, burn, shields as data: stacking, ticks, multipliers, immunity, one-attribute serialisation |
| `GameKit/Knockback` | T0 | hit and blast impulses, ragdoll requests, juggle limits |
| `GameKit/Hitbox` | T0 | melee swings, overlap tests, pose history and the server hit-claim validator (rewind at most 200 ms) |
| `GameKit/HitboxRoblox` | T3 | engine overlap queries with an exact narrow phase; Raycast/Spherecast/Blockcast casters and Shapecast for projectiles |
| `GameKit/Projectile` | T0 | ballistic shots (gravity, drag, pierce), server-simulated or client-predicted and validated |
| `GameKit/Zones` | T0 | areas, hazards, kill volumes, checkpoints and lap gates with hysteresis and swept crossings; courses |
| `GameKit/ZonesRoblox` | T3 | zones authored as parts with attributes; feeding character positions |
| `GameKit/Abilities` | T0 | data-defined abilities: cost, cooldown, cast time, channel, status blocks, range |
| `GameKit/Movement` | T0 | sprint, jump (coyote, buffer, air jumps), dash, slide, ledges; teleport and fly checks |
| `GameKit/MovementRoblox` | T3 | applying movement to a Humanoid with IAS input |
| `GameKit/Vehicles` | T0 | arcade cars (throttle, steer, grip, drift, boost) in fixed steps; travel limits |
| `GameKit/VehicleRigRoblox` | T3 | a VehicleSeat constraint car, or an anchored arcade pivot |
| `GameKit/Interact` | T0 | prompt holds and touches validated on the server (distance, hold, line of sight, rate) |
| `GameKit/InteractRoblox` | T3 | ProximityPrompt building and wiring |
| `GameKit/AnimSet` | T0 | clips/1 to standard slots, the marker contract, an 8-track Animator player |
| `GameKit/AnimSetRoblox` | T3 | Animation hooks (game-supplied ids, Studio-only preview ids), priorities |
| `GameKit/AuthorityRoblox` | T3 | bindStep, the 64-attribute writer, AuthorityMode, raw IAS (pending listing in section 11) |

Other GameKit modules (owners per section 11; a module exists here once its group merges): foundation (Stage 0) `Check`, `Json`, `Env`, `EnvRoblox`, `Signal`, `Scope`, `Fsm`, `Retry`, `Events`, `Settings`, `Catalog`, `Probe`; platform (G1) `RateLimit`, `Schema`, `RemoteGuard`, `RemoteGuardRoblox` (remote validation), `PlayerData`, `PlayerDataRoblox` (sessions; real ProfileStore T4), `Telemetry`, `TelemetryRoblox`, `Config`, `ConfigRoblox` (T4), `PolicyGate`, `PolicyGateRoblox`, `TextFilter`, `TextFilterRoblox` (T4), `SettingsStore`, `CommerceRoblox`, `Moderation`, `ModerationRoblox` (T4), `Queue`, `MemoryQueueRoblox` (T4), `TeleportRoblox` (T4), `PartyRoblox`; economy (G3) `Wallet`, `EconomySim`, `ItemDefs`, `Inventory`, `Progression`, `Objectives`, `Streaks`, `OddsTable`, `Followers`, `FollowersRoblox`, `Trade`, `Plots`, `Generators`, `Crafting`, `LiveOps`, `Outfits`, `OutfitsRoblox`, `Dialogue`, `Onboarding`, `UnlockGraph`, `SeasonTrack`, `VotingRound`; input (G4) `InputMap`, `InputMapRoblox` (replaces the raw IAS build); world (G5) `WorldCycle`; level and AI (G7) `Checkpoints`, `WaveDirector`, `NavAgent`, `NavAgentRoblox`, `Perception`, `BehaviorTree`, `PlacementGrid`, `Leaderboard`, `LeaderboardRoblox` (T4), `LiveBoard`, `LiveBoardRoblox` (T4), `TeamBalance`; harness (G9b) `DebugCommands`. Their references are their groups' docs.

## Procedure
1. **Pick modules by system, not by genre.** Shooter: Hitbox validator + Projectile + Cooldowns + Vitals. Battlegrounds: Abilities + StatusEffects + Knockback + Hitbox activations + Vitals. Racing: Vehicles + Zones course + Movement.checkTravel with Vehicles.limits. Obby: Zones (kill, hazard, gates) + Movement + RoundLoop. Arena: RoundLoop + everything above. Interaction-heavy (horror, puzzle): Interact + Zones.
2. **Write data, validate it.** Each module has `validate` (problem list) and `define` (raises with every problem); run validators in a spec before wiring.
3. **Keep the server authoritative.** Clients send only requests (input states, claims, prompt begin/finish). The server checks them through the core (`Hitbox.validator`, `Projectile.validateFire/validateHit`, `Movement.watcher`, `Interact.server`, `Abilities.caster`) and refuses with a reason; it never trusts client damage, positions, times or cooldowns.
4. **Step from one place.** Drive every core from one non-yielding callback through `AuthorityRoblox.bindStep` (RunService:BindToSimulation), read time from `env.clock()` (`time()`), take input from IAS actions (raw `AuthorityRoblox.buildActions`, or G4's InputMap once merged), and replicate with `AuthorityRoblox.writeAttributes` (at most 64 per Instance; machine state as one fsm/1 string).
5. **Lag compensation.** Record every entity's pose each step (`validator:record` or `HitboxRoblox.record`), set each shooter's measured latency, and validate claims at the client's view time; the rewind window is capped at 200 ms, so higher-latency claims are refused (`too_old`) rather than rewinding further.
6. **Test in Lune first.** Specs with FakeEnv (and `tests/fakes/FakeWorld.luau`, `tests/fakes/FakeAnimator.luau` for adapters) covering at least one refusal per untrusted input; a seeded slice with a golden digest for any composition.
7. **Probe the engine parts.** Every T3 adapter names a probe; run its `tests/engine/action_*.luau` entry on the unpublished kits place with AuthorityMode = Server and record the ENGINE_DONE line. Until then the adapter stays T3 and pending.

## Outputs
Module data and wiring, Lune specs (including refusal cases), a slice digest under `tests/golden/`, and for adapters the pending or observed probe lines.

## Acceptance
`lune run tests/run.luau` green with refusal cases for every untrusted input; the same seed gives the same digest; no client-trusted outcome remains (the exploit table in docs/gamekit-action.md covers the system); T3 parts reported pending until their probe runs.

## Failure
- A step yields or reads `tick()`/`os.clock()`: move the wait out, read `env.clock()`.
- Hits register for the shooter but are refused: check latency is set, poses are recorded every step and the claim time is the client's view time; claims older than 200 ms are refused by design.
- A fast body passes through a gate or kill volume: the zone kind must be gate or kill (swept), and positions must reach the tracker every step.
- Attribute writes fail past 64: replicate less, or move state into one serialised string (fsm/1, se/1).
- An adapter behaves differently in Studio than in the Lune fake: the fake proves wiring only; trust the probe and fix the adapter, not the fake.

## Related
roblox-multiplayer-integrity, roblox-persistence-and-commerce, roblox-presentation-pass, roblox-ui-ux-pass, roblox-luau-testing, roblox-animation-integration, roblox-genre-systems, roblox-studio-testing, luau-quality.
