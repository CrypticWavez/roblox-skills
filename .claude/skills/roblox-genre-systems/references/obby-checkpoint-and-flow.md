# Playbook: Obby and platformer (checkpoints and flow)

Kind: genre
Covers: Obby & Platformer > Classic Obby; Obby & Platformer > Runner; Obby & Platformer > Tower Obby

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no theme, course content, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Course**: ordered stages of jumps, hazards and moving parts between checkpoints. Classic obbies are linear courses, tower obbies stack floors, and runners are linear courses with a forced forward speed or a timer.
- **Progress**: the server records the highest validated checkpoint per player. Death or reset respawns there.
- **Hazards**: kill or damage volumes, moving obstacles and timed parts, each with a readable warning before it acts.
- **Retry**: fail, respawn, retry with as little friction as possible (respawn delay, camera reset, no menus in the way).
- **Optional layers**: a run timer with splits and best-time boards, stage skips, difficulty-ordered stage lists.

## Kit modules
- `ProcGen/Course`: `linear` and `tower` generators (seed, length or floors, difficulty curve, segment kinds, player scale) with `Course.toScene` for a SceneKit plan.
- `ProcGen/Validate`: `Validate.course` checks every gap with `Measure.canJump` on the engine numbers, checkpoint spacing, reachability and a monotone difficulty curve.
- `SceneKit/Measure`: `canJump`, jump reach and air time for hand-built sections; `Measure.profile(playerScale)` when the character is scaled.
- `GameKit/Checkpoints`: ordered checkpoints, `fromCourse`, server validation (`skipped`, `too_far`, `too_fast`, `already_reached`), respawn points, splits, resume after rejoin.
- `GameKit/Zones`: hazards and kill volumes as data.
- `GameKit/Movement`: extra movement (double jump, dash, slide) as data, when the course uses it.
- `GameKit/Leaderboard`, `GameKit/LeaderboardRoblox` (T4), `GameKit/LiveBoard`: best times, ranked with stable tie-breaks.
- `GameKit/PlayerData`: persisted stage and best times.
- `UIKit/Components/Timer`, `UIKit/Components/ProgressBar`: run timer and stage counter.
- `Feel/Cues`, `AVKit/VfxLibrary`: checkpoint, death and finish feedback.
- `GameKit/Telemetry`: progression events per stage, so the drop-off stage is visible.

## Data to author
- Course parameters per section: seed, kind, length or floors, difficulty curve, allowed segment kinds (TBD).
- Checkpoint spec: positions, touch radius, slack on minimum leg time (`Checkpoints.fromCourse` derives it from distance and walk speed).
- Hazard table: kind, effect (kill, damage, push), warning time, cycle time (TBD).
- Movement profile when it differs from the default character (it changes every jump check).
- Board spec: lower time is better, tie-break by submission time, per stage or per run (TBD).

## Authority and abuse risks
- **Checkpoint skipping**: a client fires a later checkpoint. `Checkpoints` refuses out-of-order, too-distant and too-fast touches; only server-side touches count.
- **Fly and teleport**: under Server Authority movement is simulated by the server; without it, distance and speed checks at each touch are the floor.
- **Saved progress**: persist only server-validated checkpoints; never trust a client stage number on join.
- **Times**: the server measures run time from its own clock; boards accept only server-measured times.
- **Stage skips**: if sold, grant through receipts once per purchase id, and decide whether skipped stages count on boards (TBD).

## Performance pitfalls
- Hundreds of `Touched` kill parts: prefer zone checks at a fixed rate or `CanTouch` only on hazards.
- Moving obstacles driven by per-part server loops: drive them from one clock so every client computes the same pose.
- Tall towers and long runners under streaming (Server Authority forces StreamingEnabled): a floor that has not streamed in is a fall. Check streaming around the player's next stage.
- Part counts per stage: keep each stage inside the `SceneKit/Budgets` class budget.

## Policy notes
- Stage skips and checkpoints-for-sale are developer products: prompts go through `GameKit/CommerceRoblox`, and in agent Studio sessions the factory's hooks ask before those prompts (`docs/mcp.md`).
- Death effects with blood or gore must be declared in the Maturity & Compliance questionnaire (see the release research).
- Boards show Roblox names only; any player-written text (course names, messages) goes through `GameKit/TextFilter`.

## Test checklist
- [ ] Every generated course passes `Validate.course`; a deliberately widened gap is rejected with its exact reason (`tests/procgen_course.spec.luau`).
- [ ] Probe `lvl_course_run` on the diagnostic place: engine gravity, walk speed and jump height match `Measure.ENGINE`, landings hit pads (T3, pending until the owner runs it).
- [ ] Respawn returns to the latest validated checkpoint after death, reset and rejoin.
- [ ] Skipping, double touches, teleports and too-fast legs are refused with their reasons and logged.
- [ ] Saved stage survives rejoin and server shutdown (`BindToClose` flush).
- [ ] Every hazard is visible and warned before it acts (human sign-off with a capture).
- [ ] Run time starts and stops on the server; boards reject client-reported times.
- [ ] Touch controls can make every jump (human sign-off on a device or Device Simulator).
- [ ] Slice `course_checkpoints` matches `tests/golden/gamekit-world.json`.

## Design questions (TBD)
- TBD: Linear stages, tower floors or a forced-speed runner?
- TBD: What does a death cost: the last checkpoint, the stage start or the course start?
- TBD: Does the course need movement beyond the default character?
- TBD: Are stage skips offered, and do skipped stages count on boards?
- TBD: Is there a timer, and is the best time per stage or per run?

## Reference systems
- Roblox templates "Classic Obby" and "Platformer" ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5; read, do not vendor: licence not stated).
- Factory: fixtures `course_linear` and `course_tower` in [build_fixtures.luau](../../../../tools/lune/build_fixtures.luau); slice `course_checkpoints` in [gamekit-world.json](../../../../tests/golden/gamekit-world.json); skills `roblox-procedural-generation` and `roblox-level-design-review`.
- Systems X11 (checkpoints, stages, hazards) and X21 (movement abilities) in the genre coverage research.
