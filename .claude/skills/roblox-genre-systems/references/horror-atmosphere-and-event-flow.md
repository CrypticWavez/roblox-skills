# Playbook: Survival horror, chase and escape (1 vs All, escape runs)

Kind: genre
Covers: Survival > 1 vs All; Survival > Escape
Also: Adventure > Story; Puzzle > Escape Room

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no monster, setting, story, numbers or monetization; every TBD belongs to the game's owner. The doc behind the taxonomy maps horror to these two labels; the systems also fit non-horror asymmetric games.

## Core loop as systems
- **Round**: lobby, role assignment, match, results, back to lobby.
- **Asymmetric roles (1 vs All)**: one hunter (player or AI) against many survivors, sometimes with hidden roles; survivors complete objectives, hide or escape; the hunter tracks and eliminates.
- **Escape runs**: a team moves through rooms or floors, solving tasks while threats patrol or chase; progress unlocks the next room.
- **Threat AI**: perception (sight, hearing, memory), search and chase behaviour, scripted appearances.
- **Atmosphere events**: lighting changes, sound stingers, camera moments, timed or triggered by progress.
- **Hiding and evasion**: hiding spots, line-of-sight breaks, noise from actions.

## Kit modules
- `GameKit/RoundLoop`, `GameKit/RoundLoopRoblox`: round phases and transitions.
- `GameKit/TeamBalance`: role and team split; asymmetric sizes with party-aware splits.
- `GameKit/Perception`: vision cones with occlusion, hearing radius by loudness, memory decay.
- `GameKit/BehaviorTree`, `GameKit/NavAgent`, `GameKit/NavAgentRoblox` (T3): threat decisions and movement, doors and links via PathfindingModifier and PathfindingLink.
- `GameKit/Interact`, `GameKit/Zones`: objectives, doors, hiding spots and trigger volumes.
- `GameKit/Vitals`, `GameKit/Movement`: health, stamina, sprint.
- `Cinematics/Cinematics`, `Cinematics/CinematicsRoblox`: scripted camera moments (skippable).
- `SceneKit/Lighting`, `GameKit/WorldCycle`: lighting profiles and changes.
- `AVKit/AudioDirector`, `AVKit/AudioCues`, `AVKit/AudioGraph`: stingers, ambience, positional threat sounds.
- `Feel/Shake`, `Feel/Screen`: camera and screen effects within the settings limits (reduced motion, safe flashes).
- `ProcGen/Dungeon`: seeded room layouts for escape runs.

## Data to author
- Round spec: phases, durations, win conditions per role (TBD).
- Role rules: counts per player total, hidden or open roles, reveal rules (TBD).
- Threat profile: field of view, sight and hearing ranges, memory, speeds, behaviour tree as data (TBD).
- Objective set per map: tasks, positions, completion rules (TBD).
- Event script: triggers (time, zone, objective) mapped to lighting, audio and camera cues (TBD).
- Room sequence for escape runs: seeds or authored rooms, door rules (TBD).

## Authority and abuse risks
- **Hidden roles**: never replicate a hidden role to other clients before the reveal; attributes and remotes are visible to exploiters.
- **Threat position**: an exploiter can read any replicated position; design for that (the threat's position is not secret once streamed).
- **Eliminations**: hits and catches are validated on the server (distance, line of sight).
- **Objective spoofing**: completion is counted from server-side interactions only.
- **Hiding**: the server decides whether a player is hidden; a client cannot declare itself hidden.
- **Leaving to dodge a loss**: results and rewards are computed on the server when the round ends, including leavers (TBD rule).

## Performance pitfalls
- Perception for every survivor every frame: run it on the threat's side at a fixed rate, with occlusion casts capped per tick.
- Dynamic lights and shadows in many rooms: budget lights per room (`SceneKit/Budgets`), switch distant rooms off.
- Audio: many emitters in range at once; cap voices and use the audio graph's buses.
- Streaming: rooms ahead must be loaded before a chase reaches them.

## Policy notes
- Fear, violence and blood levels go into the Maturity & Compliance questionnaire; they decide the audience.
- Flashes and shakes respect the player's settings (settings/1 reduced motion) and safe-flash limits in `Feel/Screen`.
- Jump scares with loud audio: keep levels inside the mixer's master limits.

## Test checklist
- [ ] Round loop: every phase transitions; a round with all survivors gone and one with the hunter leaving both end cleanly.
- [ ] Team split is deterministic for a fixed seed and respects parties (`tests/gamekit_world_teams.spec.luau`).
- [ ] Perception: seen through an open door, not through a wall; hearing scales with loudness; memory decays (`tests/gamekit_world_perception.spec.luau`).
- [ ] Hidden roles are absent from every replicated attribute and remote payload before the reveal.
- [ ] Probes `lvl_navagent_door` and `lvl_pathfinding_probe` (T3): the threat routes through doors and around costly areas.
- [ ] Every scripted cue can fire twice or out of order without breaking the round.
- [ ] Captures of each lighting state pass a human readability check.

## Design questions (TBD)
- TBD: Player-controlled hunter, AI threat, or both?
- TBD: Hidden roles or open roles?
- TBD: How does a survivor win: objectives, escape, survival time?
- TBD: Authored rooms or seeded layouts for escape runs?
- TBD: What happens to eliminated players during the round?

## Reference systems
- Roblox reference "The Mystery of Duvall Drive" supporting-systems page (read only; [genre coverage](../../../../docs/research/genre-coverage-2026-10.md), sources).
- Engine: PathfindingService modifiers and links, WorldRoot casts for line of sight ([gameplay libraries research](../../../../docs/research/gameplay-libraries-2026-10.md), section 3).
- Systems X01, X08, X24 and X32 in the genre coverage research; fixture `dungeon` in [build_fixtures.luau](../../../../tools/lune/build_fixtures.luau).
