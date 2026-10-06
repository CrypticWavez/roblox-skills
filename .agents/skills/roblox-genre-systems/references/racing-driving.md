# Playbook: Racing and driving (tracks, laps, vehicle sims)

Kind: genre
Covers: Sports & Racing > Racing; Simulation > Vehicle Sim
Also: Action > Open World Action

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no vehicles, tracks, setting, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Race**: grid, countdown, laps through ordered gates, positions, finish, results (racing).
- **Free driving**: an open map with roads, jobs, deliveries or events; owning, upgrading and customising vehicles (vehicle sim).
- **Vehicle model**: chassis, wheels, suspension, steering, throttle and brake, drift or boost (TBD).
- **Position and timing**: lap and sector timing, best laps, ghost or split comparisons.
- **Progression**: currency from races or jobs buys vehicles and upgrades; garage persistence.

## Kit modules
- `ProcGen/Course`: `Course.raceLoop` gives a closed spline track with width, banking and grade limits, gates and grid slots; `Validate.course` checks closure, minimum turn radius, bank, grade, gate spacing and coverage.
- `GameKit/Checkpoints`: ordered gates with laps, skip detection, splits, respawn on the last gate.
- `GameKit/Zones`: lap and sector gates, off-track and reset volumes.
- `GameKit/Vehicles`, `GameKit/VehicleRigRoblox`: vehicle state and the engine rig (Server Authority covers vehicles).
- `GameKit/RoundLoop`, `GameKit/Queue`: race sessions and matchmaking.
- `GameKit/Leaderboard`, `GameKit/LeaderboardRoblox` (T4), `GameKit/LiveBoard`: best laps and event boards.
- `GameKit/Inventory`, `GameKit/Wallet`, `GameKit/Progression`: owned vehicles, upgrades, currency.
- `GameKit/InputMap`: throttle, brake, steer on keyboard, gamepad (analogue) and touch.
- `UIKit/Components/Timer`, `UIKit/Components/Countdown`, `UIKit/Components/StatBar`: lap timer, start countdown, speed.
- `AVKit/AudioGraph`, `AVKit/AudioCues`, `Feel/Shake`: engine audio, boost and impact feel.

## Data to author
- Track parameters: seed, laps, width, banking and grade limits, minimum turn radius, gate count (TBD).
- Vehicle definitions: mass, power, grip, steering, upgrade slots (TBD).
- Race rules: laps, collision on or off, catch-up rules, finish timeout (TBD).
- Free-roam map: road network (`ProcGen/Settlement` roads or authored), job and event points (TBD).

## Authority and abuse risks
- **Gate skipping and shortcuts**: `GameKit/Checkpoints` refuses out-of-order and too-fast gates; off-track volumes reset.
- **Speed hacks**: vehicle physics is server-authoritative under Server Authority; otherwise check speed and displacement per step.
- **Lap times**: measured on the server from gate touches; boards accept only server times.
- **Vehicle ownership**: spawning a vehicle checks server-side inventory.
- **Collision griefing**: ghosting rules or penalties (TBD).

## Performance pitfalls
- Track mesh and part counts on long tracks: budget by section; streaming must keep the track ahead loaded.
- Many vehicles with full physics: limit active vehicles per server; despawn idle ones.
- Engine audio per vehicle for every listener: cap voices by distance.
- Gate checks with `Touched` at high speed: fast vehicles can pass through thin triggers; use thick triggers or swept checks between steps.

## Policy notes
- Vehicle crates bought with Robux follow the paid random items rules; trading vehicles checks `IsPaidItemTradingAllowed`.
- Real-world vehicle brands are intellectual property; IP takedowns are a Community Standards item.
- Violence settings if vehicles can damage players go into the Maturity & Compliance questionnaire.

## Test checklist
- [ ] Every generated track passes `Validate.course` (`loop_closed`, `min_turn_radius`, `max_bank`, `max_grade`, `gate_spacing`, `gate_coverage`, `track_clearance`).
- [ ] Laps: gates in order count, skipped or too-fast gates are refused; lap count and finish detected (`tests/gamekit_world_checkpoints.spec.luau`).
- [ ] Fast pass through a gate between two physics steps still registers (T3).
- [ ] Spawning an unowned vehicle through a forged remote is refused.
- [ ] Every control has keyboard, gamepad and touch bindings; analogue steering works on gamepad.
- [ ] Probe `lvl_course_run` (T3) for on-foot sections; vehicle rig probes belong to `GameKit/VehicleRigRoblox`.
- [ ] Preview render of the race loop inspected for track pieces that overlap or float.

## Design questions (TBD)
- TBD: Lap races, point-to-point, free roam, or several?
- TBD: Arcade or simulation handling?
- TBD: Are vehicles owned and upgraded, or chosen per race?
- TBD: Collisions between players on or off?
- TBD: Does the game include on-foot play?

## Reference systems
- Roblox templates "Racing" and "Classic Racing" as read-only references ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5); Server Authority covers vehicles (same research, section 5).
- Fixture `course_race_loop` in [build_fixtures.luau](../../../../tools/lune/build_fixtures.luau); Blender `vehicle` template for models.
- Systems X11, X17 and X19 in the genre coverage research.
