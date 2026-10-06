# Playbook: Roleplay and life sim (town, morphs, creatures)

Kind: genre
Covers: Roleplay & Avatar Sim > Life; Roleplay & Avatar Sim > Morph Roleplay; Roleplay & Avatar Sim > Animal Sim
Also: Action > Open World Action; Roleplay & Avatar Sim > Pet Care; Simulation > Vehicle Sim

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no setting, roles, characters, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Shared world**: a town or wilderness with public places, homes and interiors; players make their own stories.
- **Roles and jobs**: pick a role (occupation, team, family role) that unlocks tools, areas and interactions.
- **Homes**: claim a home, furnish it, invite or lock out others.
- **Body and look**: avatar outfits, or a morph that swaps the body for another character or creature (morph roleplay, animal sim).
- **Creature life** (animal sim): growth stages, needs such as hunger and thirst, abilities per species.
- **Props and vehicles**: usable items, vehicles, phone-style menus.
- **Time and world state**: day and night, weather, events.

## Kit modules
- `GameKit/Outfits`, `GameKit/OutfitsRoblox`: outfits and saved looks; morphs as an outfit-like body swap (TBD with the owning group).
- `GameKit/Plots`, `GameKit/PlacementGrid`: home claiming and furniture placement with serialise and restore.
- `GameKit/Interact`, `GameKit/InteractRoblox`, `GameKit/Zones`: doors, seats, job stations, private areas.
- `GameKit/Vehicles`, `GameKit/VehicleRigRoblox`: town vehicles.
- `GameKit/AnimSet`, `GameKit/AnimSetRoblox`: emotes and creature locomotion slots.
- `GameKit/Vitals`, `GameKit/StatusEffects`, `GameKit/Progression`: needs, growth stages, unlocks (animal sim).
- `GameKit/WorldCycle`: day and night, weather.
- `GameKit/TextFilter`, `GameKit/TextFilterRoblox` (T4): role names, signs, bios.
- `GameKit/NavAgent`, `GameKit/BehaviorTree`: ambient NPCs.
- `UIKit/Components/Tabs`, `UIKit/Components/Grid`, `UIKit/Components/Modal`: role menus, catalogues, phone-style screens.
- `ProcGen/Settlement`, `SceneKit/Building`: town layouts, roads, lots and buildings.

## Data to author
- Role list: role keys, tools, areas, limits per server (TBD).
- Home catalogue: plot sizes, furniture items with footprints (TBD).
- Morph or species definitions: rig, animation set, stats, growth stages (TBD).
- Needs model: decay rates, refill sources, effects of empty needs (TBD).
- Town layout: seed or authored districts, interiors (TBD).

## Authority and abuse risks
- **Home access**: lock and permission checks on the server for doors and furniture edits.
- **Role spoofing**: role-gated tools and areas check the server-side role, not a client flag.
- **Prop and vehicle spawning**: rate-limited and capped per player; spawned objects belong to the spawner and are cleaned on leave.
- **Griefing**: pushing, blocking doors, vehicle ramming; provide server-side rules (no-collide zones, kick from home).
- **Text**: every role name, sign or bio is filtered before others see it.

## Performance pitfalls
- Furnished homes for every player loaded at once: stream interiors or load them on entry.
- Many vehicles and props: cap per player and per server.
- Custom morph rigs: Adaptive Animation lets one animation play on custom rigs; check rig compatibility before authoring many clips.
- Ambient NPC counts: budget per district.

## Policy notes
- Romance and dating content are not allowed (Community Standards); family roleplay stays within that.
- "Social hangouts" and "free-form user creation" (if players build or write) are Maturity & Compliance questionnaire categories.
- Text filtering is mandatory for player-written text.
- Paid items that can be traded check `IsPaidItemTradingAllowed`.

## Test checklist
- [ ] Furniture placement refuses overlaps and out-of-plot cells; a home restores exactly after rejoin (`tests/gamekit_world_placement.spec.luau` pattern).
- [ ] Locked homes refuse entry and edits from non-members.
- [ ] Role-gated tools and areas refuse players without the role.
- [ ] Spawn caps hold under a client spamming spawn requests.
- [ ] Every player text path goes through the filter before display.
- [ ] Generated towns pass `ProcGen/Validate` settlement checks (road connectivity, lot count, footprints).
- [ ] Morph swap and back keeps the player's inventory and saved look.

## Design questions (TBD)
- TBD: Which roles exist, and are they limited per server?
- TBD: Are homes owned and persistent or per session?
- TBD: Default avatars, morphs, creatures, or several?
- TBD: Are there needs or growth stages?
- TBD: Is player-written text part of the experience?

## Reference systems
- Developer modules Friends Locator, Spawn With Friends and Social Interactions as read-only references ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5); Adaptive Animation in the same research, section 5.
- Fixture `settlement` in [build_fixtures.luau](../../../../tools/lune/build_fixtures.luau); skill `roblox-scene-authoring` for interiors.
- Systems X13, X17, X22, X32 and X33 in the genre coverage research.
