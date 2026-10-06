# GameKit

Genre-neutral gameplay and platform systems: pure cores that run in Lune with an injected `env`, plus thin `<Name>Roblox.luau` adapters for the engine. No content, prices or economy numbers ship here. Contract, tiers and the module list: [docs/runtime-kits.md](../../docs/runtime-kits.md). Guides: [platform](../../docs/gamekit-platform.md), [action](../../docs/gamekit-action.md), [economy](../../docs/gamekit-economy.md), [input map](../../docs/uikit.md).

| Owner | Modules |
|---|---|
| Stage 0 (frozen foundation) | Check, Json, Env, EnvRoblox, Signal, Scope, Fsm, Retry, Events (kit-event/1), Settings (settings/1), Catalog (catalog/1), Probe |
| G1 platform services | RateLimit, Schema, RemoteGuard, PlayerData, Telemetry, Config, PolicyGate, TextFilter, SettingsStore, Commerce, Moderation, Queue and their adapters |
| G2 action | RoundLoop, Vitals, Cooldowns, Hitbox, Projectile, Zones, Abilities, Vehicles, Interact, AnimSet, Movement, StatusEffects, Knockback and adapters (including AuthorityRoblox, the shared Server Authority plumbing) |
| G3 economy | Wallet, EconomySim, ItemDefs, Inventory, Progression, Objectives, Streaks, OddsTable, Followers, Trade, Plots, Generators, Crafting, LiveOps, Outfits, Dialogue, Onboarding, UnlockGraph, SeasonTrack, VotingRound and adapters |
| G4 input | InputMap, InputMapRoblox |
| G5 world | WorldCycle |
| G7 level and AI | Checkpoints, WaveDirector, NavAgent, Perception, BehaviorTree, PlacementGrid, Leaderboard, LiveBoard, TeamBalance and adapters |
| G9b harness | DebugCommands |
