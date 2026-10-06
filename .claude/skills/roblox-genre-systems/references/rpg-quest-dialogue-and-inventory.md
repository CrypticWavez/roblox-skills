# Playbook: RPG, open world and exploration (quests, dialogue, inventory, combat)

Kind: genre
Covers: RPG > Action RPG; RPG > Open World & Survival RPG; RPG > Turn-based RPG; Action > Open World Action; Adventure > Exploration

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no setting, story, characters, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **World**: regions, towns and dungeons connected by travel; discovery points and fast travel (open world and exploration).
- **Character growth**: experience, levels, stats and skills; equipment changes stats.
- **Combat**: real-time abilities with cooldowns and hit validation (action RPG, open world action) or turns with an action queue (turn-based RPG).
- **Quests**: objectives with prerequisites, tracked progress and rewards; dialogue with branching choices.
- **Loot and inventory**: drops, equipment slots, stacking, selling and crafting.
- **NPCs**: enemies with perception and behaviour trees, vendors and quest givers.
- **Exploration rewards**: discovery logs, collectables and map reveal.

## Kit modules
- `GameKit/Objectives`, `GameKit/Dialogue` (dialogue/1): quests, achievements and branching conversations; `UIKit/Components/DialogueBox` shows them.
- `GameKit/Inventory`, `GameKit/ItemDefs`, `GameKit/Crafting`: items, equipment slots, recipes.
- `GameKit/Progression`, `GameKit/Vitals`, `GameKit/StatusEffects`: levels, stats, health and buffs.
- `GameKit/Abilities`, `GameKit/Cooldowns`, `GameKit/Hitbox`, `GameKit/Projectile`, `GameKit/Knockback`: real-time combat.
- `GameKit/Fsm`: turn order and phases for turn-based combat (state lives in one attribute).
- `GameKit/NavAgent`, `GameKit/NavAgentRoblox` (T3), `GameKit/Perception`, `GameKit/BehaviorTree`: NPC movement, sight and hearing, decisions.
- `GameKit/WaveDirector`: encounter spawns in dungeons and events.
- `GameKit/Zones`, `GameKit/Interact`: regions, discovery points, prompts.
- `GameKit/WorldCycle`: day and night, weather (G5).
- `Cinematics/Cinematics`: story beats and boss intros.
- `ProcGen/Dungeon`, `ProcGen/Cave`, `ProcGen/Forest`, `ProcGen/Settlement`: seeded layouts for dungeons, caves, wilds and towns.
- `UIKit/Components/InventoryGrid`, `UIKit/Components/StatBar`, `UIKit/Components/Tooltip`: inventory and stats.

## Data to author
- Item definitions, equipment slots and stat formulas (TBD).
- Quest graph: objectives, prerequisites, rewards; dialogue/1 trees with conditions (TBD).
- Enemy archetypes: perception ranges, behaviour trees as data, drop tables (TBD).
- Ability definitions: cooldowns, costs, hit shapes, effects (TBD).
- Region list: level bands, spawn tables, discovery points (TBD).
- Turn-based: action set, turn order rule, timeouts (TBD).

## Authority and abuse risks
- **Hit claims**: the server validates every client-reported hit (distance, angle, latency window) or computes hits itself; under Server Authority, combat runs in `BindToSimulation`.
- **Quest completion**: progress is counted from server events, never from a client "complete" call.
- **Loot**: drops roll on the server from seeded tables; pickup checks distance and ownership.
- **Dialogue choices**: the server checks that the chosen option was available in the current node.
- **Duplication**: inventory moves (equip, trade, craft) are single server transactions saved with the profile.
- **Turn-based**: the server owns the turn; actions out of turn or after timeout are refused.

## Performance pitfalls
- Open worlds under streaming: NPCs and quest targets outside the streamed area need server-side logic that does not depend on client parts.
- Many NPCs with pathfinding: cap concurrent path computations, use cheap waypoint following, sleep NPCs far from players.
- Behaviour trees ticking every frame for every NPC: use the per-tick budget and tick distant NPCs less often.
- Large inventories in one remote payload: page them (`UIKit/Components/VirtualList`) and send deltas.

## Policy notes
- Violence, blood and fear levels go into the Maturity & Compliance questionnaire.
- AI-driven NPC conversations (generated text) are an "AI interactions" questionnaire item and need text filtering (`GameKit/TextFilter`).
- Paid loot boxes follow the paid random items rules; traded paid items check `IsPaidItemTradingAllowed`.

## Test checklist
- [ ] Quest graph validation: no unreachable quests, no cycles in prerequisites; a broken prerequisite is reported.
- [ ] Dialogue trees validate (every option leads to a node or an end; conditions name known flags).
- [ ] Forged hit, loot and quest-complete remotes change nothing.
- [ ] Inventory operations conserve items across equip, craft, drop and rejoin (scenario bots).
- [ ] NPC probes `lvl_pathfinding_probe` and `lvl_navagent_door` (T3) on the diagnostic place.
- [ ] Every generated dungeon or region passes its ProcGen validator.
- [ ] Turn-based: an action out of turn and a timed-out turn are refused.

## Design questions (TBD)
- TBD: Real-time combat, turn-based combat, or none (exploration only)?
- TBD: Open world, hub with instanced dungeons, or linear regions?
- TBD: Solo, co-op or shared world, and how many players per server?
- TBD: How do players get gear: drops, crafting, vendors or quests?
- TBD: Is there a level cap, and what happens after it?

## Reference systems
- Roblox templates "Combat" and "Mansion of Wonder" and the Missions feature package as read-only references ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5).
- Fixtures `dungeon`, `forest` and `settlement` in [build_fixtures.luau](../../../../tools/lune/build_fixtures.luau).
- Systems X04, X06, X07, X08, X09 and X31 in the genre coverage research; Server Authority rules in [runtime-kits.md](../../../../docs/runtime-kits.md), section 6.
