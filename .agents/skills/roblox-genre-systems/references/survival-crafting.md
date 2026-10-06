# Playbook: Survival and crafting

Kind: genre
Covers: Survival > (none)
Also: Adventure > Exploration; RPG > Open World & Survival RPG; Roleplay & Avatar Sim > Animal Sim

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no setting, creatures, recipes, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Gather**: harvest resources from nodes in the world with tools; nodes deplete and respawn.
- **Craft**: recipes turn resources into tools, structures and consumables, sometimes at stations.
- **Build**: place structures and a base on a grid or freely; defend it.
- **Survive**: meters (health, hunger, warmth or others) decay; threats come at night or in events.
- **Night or event pressure**: waves of creatures, weather, a timer to the next danger.
- **Progress**: days survived, tiers of tools, map areas, team goals.

## Kit modules
- `GameKit/Crafting`: recipes, stations, inputs and outputs.
- `GameKit/Inventory`, `GameKit/ItemDefs`: resources, tools, stacks and durability.
- `GameKit/Vitals`, `GameKit/StatusEffects`: survival meters and their effects.
- `GameKit/PlacementGrid`: structures and bases with footprints, rotation and serialise and restore.
- `GameKit/WaveDirector`: night attacks and events as data-defined waves.
- `GameKit/NavAgent`, `GameKit/NavAgentRoblox` (T3), `GameKit/Perception`, `GameKit/BehaviorTree`: creatures that see, hear, remember and act.
- `GameKit/WorldCycle`: day and night and weather (G5).
- `GameKit/Interact`, `GameKit/Zones`: resource nodes, stations, safe areas.
- `GameKit/Hitbox`, `GameKit/Abilities`, `GameKit/Cooldowns`: combat with tools.
- `ProcGen/Forest`, `ProcGen/Cave`, `ProcGen/Placement`: seeded biomes, caves and resource placement.
- `UIKit/Components/InventoryGrid`, `UIKit/Components/StatBar`: inventory and meters.

## Data to author
- Resource table: node kinds, yields, tools required, respawn (TBD).
- Recipe list: inputs, outputs, station, unlock condition (TBD).
- Meter model: decay rates, refills, thresholds and effects (TBD).
- Structure list: footprints, health, placement rules (TBD).
- Threat spec: waves per night, creature archetypes with perception and behaviour data (TBD).
- World parameters: biome seeds, sizes, resource density (TBD).

## Authority and abuse risks
- **Gathering**: the server checks distance, tool and node state; yields come from the server.
- **Crafting**: one server transaction removes inputs and adds outputs; refused when inputs are missing.
- **Building**: placement validated on the server (`PlacementGrid.canPlace`), ownership checked for edits and removal.
- **Duplication**: drop and pick-up of items are server-owned; no client-created items.
- **Base raiding** (if allowed): damage to structures validated like player damage.

## Performance pitfalls
- Thousands of resource nodes: spawn near players, pool, or represent depleted nodes as state, not instances.
- Player bases with many parts: cap structures per player and per server; save keys, not instances.
- Many creatures at night: cap active creatures, simplify far ones, budget perception and path computes per step.
- Lighting changes at day and night: keep them in one profile transition, not per-part changes.

## Policy notes
- Violence, blood and fear levels go into the Maturity & Compliance questionnaire.
- Player-built structures that others see can be "free-form user creation" in the questionnaire; signs or names need text filtering.
- Paid rolls for gear follow the paid random items rules.

## Test checklist
- [ ] Crafting conserves items: inputs removed and outputs added exactly once; missing inputs refused.
- [ ] Gathering out of range, with the wrong tool or from a depleted node is refused.
- [ ] Structures: placement refusals with reasons; a base restores exactly after rejoin.
- [ ] Night waves are deterministic for a fixed seed (`tests/gamekit_world_waves.spec.luau` pattern).
- [ ] Creature perception: sight blocked by walls, hearing by loudness, memory decay.
- [ ] Generated biomes and caves pass their ProcGen validators.
- [ ] Meters at zero apply their effect and recover when refilled.

## Design questions (TBD)
- TBD: Solo, co-op or competitive survival?
- TBD: Persistent world and bases, or a fresh world per session?
- TBD: Which meters exist, and how harsh are they?
- TBD: Is there a night cycle with waves, or roaming threats only?
- TBD: Grid or free building?

## Reference systems
- Fixtures `forest` and `cave` in [build_fixtures.luau](../../../../tools/lune/build_fixtures.luau); slice `wave_lane` in [gamekit-world.json](../../../../tests/golden/gamekit-world.json) for the wave and AI wiring.
- Systems X04, X08, X12, X18, X31 and X32 in the [genre coverage research](../../../../docs/research/genre-coverage-2026-10.md).
- Skill `roblox-procedural-generation` for biomes and resource placement.
