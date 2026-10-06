# Playbook: Practice range and training space (cross-cutting)

Kind: cross-cutting
Also: Action > Battlegrounds & Fighting; Shooter > Deathmatch Shooter

A neutral systems reference for any genre with skill-based combat or movement: it maps a warm-up and test space to kit modules, risks and checks. It picks no weapons, drills or numbers; every TBD belongs to the game's owner.

## Core loop as systems
- **Enter and leave**: a zone or menu puts the player in practice and takes them back without side effects.
- **Targets**: static, moving and scripted targets that report hits, damage and timing.
- **Drills**: timed or counted exercises with a result (accuracy, time to kill, reaction time).
- **Test loadouts**: try abilities or weapons without owning them, inside the range only.
- **Isolation**: nothing earned in practice reaches the real economy, ratings or quests.

## Kit modules
- `GameKit/Zones`: the range area and its entry and exit.
- `GameKit/Hitbox`, `GameKit/Projectile`, `GameKit/Abilities`, `GameKit/Cooldowns`: the same combat code as live play.
- `GameKit/Vitals`: target health and resets.
- `GameKit/NavAgent`, `GameKit/BehaviorTree`: moving targets along paths or simple behaviours.
- `GameKit/Fsm`: drill phases (ready, running, result).
- `GameKit/Leaderboard`: local drill bests (persisted boards only if the owner wants them).
- `UIKit/Components/Timer`, `UIKit/Components/StatBar`: drill readouts.
- `Feel/HitStop`, `Feel/Popups`: hit feedback identical to live play.

## Data to author
- Target types: health, movement path, reset rule (TBD).
- Drill definitions: duration, target sequence, scoring (TBD).
- Test loadout list and its limits (TBD).

## Authority and abuse risks
- **Reward leakage**: practice kills, damage and drills never call economy, quest or rating code; enforce with a flag checked server-side.
- **Loadout escape**: test items are removed on exit and cannot be saved, traded or carried into a match.
- **Drill boards**: if drill results are ranked, they are measured server-side like any other score.

## Performance pitfalls
- Many targets with Humanoids: use simple models with server-side health.
- Hit effects at high fire rates: pool effects and cap per frame.
- A range on every server: build it once and stream it, or place it in a separate place (TBD).

## Policy notes
- Weapon and violence presentation in the range counts towards the same Maturity & Compliance answers as the main game.
- Paid items offered "to try" must not be granted by the trial path (purchase only through `GameKit/CommerceRoblox`).

## Test checklist
- [ ] Entering and leaving restores the player's real loadout and state.
- [ ] Practice kills, damage and drill results change no currency, quest, rating or inventory.
- [ ] Test loadout items cannot leave the range (drop, trade, save, teleport).
- [ ] Static and moving targets register hits with the live hit validation.
- [ ] Drill timers and counters match server-side measurements.

## Design questions (TBD)
- TBD: Is practice a zone in the lobby, a separate place or a menu mode?
- TBD: Which drills, and are their results ranked?
- TBD: Can players try items they do not own?

## Reference systems
- Roblox templates "Laser Tag", "FPS System" and "Combat" as read-only references ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5).
- Hit validation design in the [gameplay libraries research](../../../../docs/research/gameplay-libraries-2026-10.md), section 7.1; skill `roblox-multiplayer-integrity`.
