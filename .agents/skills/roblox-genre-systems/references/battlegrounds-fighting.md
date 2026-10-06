# Playbook: Battlegrounds and fighting

Kind: genre
Covers: Action > Battlegrounds & Fighting
Also: Action > Open World Action; RPG > Action RPG

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no characters, abilities, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Arena**: a shared map (free-for-all drop-in) or rounds in arenas; respawn after defeat.
- **Kit selection**: a character or moveset with abilities, chosen before or during play.
- **Combat**: basic attacks with combos, abilities on cooldowns, blocks, dodges, stuns, knockback and ragdoll.
- **Feedback**: hit-stop, camera shake, hit effects and sounds that sell each hit.
- **Score**: kills, streaks, damage, round wins; kill feed and boards.
- **Progression** (optional): unlock movesets, cosmetics, ranked play.

## Kit modules
- `GameKit/Abilities`, `GameKit/Cooldowns`: ability definitions, cooldowns and costs.
- `GameKit/Hitbox`, `GameKit/HitboxRoblox`: shape sweeps between poses with the initial-overlap check; validation of client-reported hits (distance, angle, latency window).
- `GameKit/Projectile`: ranged abilities with segment casts.
- `GameKit/Knockback`, `GameKit/StatusEffects`: impulses, ragdoll requests, stuns and buffs.
- `GameKit/Vitals`, `GameKit/Movement`: health, block and stamina; dash and other movement as data.
- `GameKit/AnimSet`, `GameKit/AnimSetRoblox`: clips/1 slots with `action_1..action_8` for moves (at most 8 playing tracks per Animator).
- `GameKit/RoundLoop`, `GameKit/TeamBalance`: rounds and teams when the arena is round-based.
- `GameKit/InputMap`: actions bound for keyboard, gamepad and touch.
- `Feel/HitStop`, `Feel/Shake`, `Feel/Haptics`, `AVKit/VfxLibrary`, `AVKit/AudioCues`: hit feel.
- `UIKit/Components/TouchActionButton`, `UIKit/Components/StatBar`: touch ability buttons and health.
- `ProcGen/Arena`: seeded arena layouts; `Validate.arena` checks spawn fairness and spawn-to-spawn sightlines.

## Data to author
- Movesets: ability list per moveset with hit shapes, timing (start-up, active, recovery), damage, cooldown, effects (TBD).
- Combo rules: chain windows, cancels, end-of-combo knockback (TBD).
- Status effects: stun, slow, guard break, durations and stacking (TBD).
- Arena list: layout seeds or authored maps, spawn points (TBD).
- Input bindings per platform (TBD).

## Authority and abuse risks
- **Hit claims**: the server validates distance, angle and timing or computes hits itself; under Server Authority, combat runs in `BindToSimulation` with `time()`.
- **Cooldown bypass**: cooldowns live on the server; a request during cooldown is refused.
- **Speed and teleport**: movement is server-simulated under Server Authority; otherwise check displacement per step.
- **Animation-driven hitboxes**: never trust client animation timing for damage; use server timings from the moveset data.
- **Remote spam**: rate-limit ability requests (`GameKit/RateLimit`, `GameKit/RemoteGuard`).

## Performance pitfalls
- Spatial queries per frame per player: sweep only during active frames of an attack.
- Effects for every hit for every viewer: pool and cull by distance (`AVKit/Pool`).
- Animation track limits: more than 8 playing tracks per Animator stops new ones.
- Ragdolls on many characters at once: cap and time out.

## Policy notes
- Violence and blood levels go into the Maturity & Compliance questionnaire.
- Moveset rolls bought with Robux follow the paid random items rules (`GameKit/OddsTable`, `GameKit/PolicyGate`).
- Flashing hit effects respect the reduced-motion setting and safe-flash limits.

## Test checklist
- [ ] Hit validation boundaries: a claim just inside and just outside distance, angle and latency limits.
- [ ] Each hit applies once per activation (dedupe), including the initial-overlap case.
- [ ] Ability during cooldown, while stunned or while dead is refused.
- [ ] Generated arenas pass `Validate.arena` (`spawn_fairness`, `spawn_sightline_blocked`); a spawn with a direct sightline to another is reported.
- [ ] Every action has a binding for keyboard and mouse, gamepad and touch (`GameKit/InputMap` check).
- [ ] Server & Clients test with simulated latency: hits feel consistent and none are double-counted (T3).
- [ ] Animation probe: playing tracks stay at or under 8 per Animator through a full combo.

## Design questions (TBD)
- TBD: Free-for-all drop-in arena or round-based matches?
- TBD: How are movesets obtained: free choice, unlocks or rolls?
- TBD: Is there blocking, parrying or dodging, and how do they interact?
- TBD: Are ragdolls part of knockback?
- TBD: Is there ranked play?

## Reference systems
- Roblox templates "Combat" and "Team/FFA Arena" as read-only references ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5).
- Hitbox and Projectile designs and the WorldRoot query facts in the [gameplay libraries research](../../../../docs/research/gameplay-libraries-2026-10.md), sections 3 and 7.1.
- Fixture `arena` in [build_fixtures.luau](../../../../tools/lune/build_fixtures.luau); systems X09, X10 and X21 in the genre coverage research.
