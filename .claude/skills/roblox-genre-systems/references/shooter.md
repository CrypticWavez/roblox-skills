# Playbook: Shooter (deathmatch, battle royale, PvE)

Kind: genre
Covers: Shooter > Battle Royale; Shooter > Deathmatch Shooter; Shooter > PvE Shooter

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no weapons, maps, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Match**: lobby, queue, spawn, fight, results; deathmatch rounds, a shrinking-zone last-team-standing (battle royale), or co-op against AI waves (PvE).
- **Weapons**: hitscan or projectile fire, fire rate, spread, recoil, reload, ammo, damage falloff.
- **Hit registration**: client feel with server validation.
- **Movement**: sprint, crouch, slide, aim; camera in first or third person.
- **Loot and loadouts**: fixed loadouts, unlocks, or ground loot (battle royale).
- **Score**: kills, assists, objectives, kill feed, scoreboard, boards and ranks.

## Kit modules
- `GameKit/Projectile`: ballistic projectiles with segment casts, pierce and bounce.
- `GameKit/Hitbox`, `GameKit/HitboxRoblox`: hit validation for client-reported shots (distance, angle, latency window).
- `GameKit/Vitals`, `GameKit/Cooldowns`, `GameKit/Movement`: health and armour, fire and reload timing, movement.
- `GameKit/Inventory`, `GameKit/ItemDefs`: weapons, attachments, ammo, ground loot.
- `GameKit/RoundLoop`, `GameKit/TeamBalance`, `GameKit/Queue`: rounds, teams, matchmaking.
- `GameKit/Zones`: the shrinking safe zone and out-of-bounds.
- `GameKit/WaveDirector`, `GameKit/NavAgent`, `GameKit/Perception`, `GameKit/BehaviorTree`: PvE enemies.
- `GameKit/InputMap`: aim, fire, reload bindings for all platforms.
- `GameKit/Leaderboard`, `GameKit/LeaderboardRoblox` (T4): boards and ranks.
- `UIKit/Components/TouchActionButton`, `UIKit/Components/StatBar`, `UIKit/Components/LeaderboardPanel`: touch fire, health and ammo, scoreboard.
- `Feel/Shake`, `Feel/Haptics`, `AVKit/VfxLibrary`, `AVKit/AudioCues`: recoil feel, muzzle and impact effects, positional sound.
- `ProcGen/Arena`: seeded arena layouts; `Validate.arena` checks spawn fairness and spawn-to-spawn sightlines.

## Data to author
- Weapon definitions: fire mode, rate, spread, recoil pattern, magazine, reload, damage by range and body part (TBD).
- Loadout or loot tables (TBD).
- Mode rules: score limit, time limit, respawn rule, team size, zone schedule (TBD).
- Map list with spawn points and lanes (TBD).
- PvE: enemy archetypes and wave specs (TBD).

## Authority and abuse risks
- **Shot claims**: the server checks fire rate, ammo, line of sight, distance and latency window before applying damage.
- **Aim assistance exploits**: aimbots cannot be fully stopped server-side; flag statistical outliers (TBD policy) rather than trust client aim.
- **Ammo and reload**: counts live on the server.
- **Wall and visibility**: replicated positions are readable by exploiters; do not send hidden-information positions earlier than needed.
- **Spawn killing**: spawn selection uses distance from enemies and line of sight.

## Performance pitfalls
- Raycasts per bullet at high fire rates: one cast per segment per step, capped per frame.
- Bullet effects: pool tracers and impacts; cap live decals.
- Battle royale map size under streaming: loot and zone logic must work for areas not streamed to a client.
- Many PvE enemies with pathfinding: share paths and cap computes per step.

## Policy notes
- Violence and blood levels go into the Maturity & Compliance questionnaire; realistic weapons may affect the audience.
- Weapon crates bought with Robux follow the paid random items rules; trading them checks `IsPaidItemTradingAllowed`.
- Ranked prizes cannot be Robux or real-value (Community Standards).

## Test checklist
- [ ] Shot validation boundaries: fire rate, range, line of sight and latency window, each just inside and just outside.
- [ ] Ammo, reload and fire rate hold under a client that spams the fire remote.
- [ ] Projectile positions over time match the kinematics and segment coverage has no gaps (`GameKit/Projectile` spec).
- [ ] Generated arenas pass `Validate.arena` (`spawn_fairness`, `spawn_sightline_blocked`); a spawn with a direct sightline to another is reported.
- [ ] Zone schedule: damage outside the zone, shrinking on time, no safe spot outside the map.
- [ ] Every action bound for keyboard and mouse, gamepad and touch.
- [ ] Server & Clients latency test: hits register consistently (T3).

## Design questions (TBD)
- TBD: Deathmatch rounds, battle royale, PvE, or several modes?
- TBD: Hitscan, projectile or mixed weapons?
- TBD: First person, third person or a toggle?
- TBD: Fixed loadouts, unlocks or ground loot?
- TBD: Team size and match length?

## Reference systems
- Roblox templates "FPS System", "Laser Tag", "Team/FFA Arena" and "Capture the Flag" as read-only references ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5).
- Projectile and Hitbox designs in the [gameplay libraries research](../../../../docs/research/gameplay-libraries-2026-10.md), section 7.1.
- Fixture `arena` in [build_fixtures.luau](../../../../tools/lune/build_fixtures.luau); systems X09, X10, X16 and X19 in the genre coverage research.
