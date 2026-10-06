# GameKit action kit (G2): API reference

Genre-neutral real-time gameplay systems for `packages/GameKit`: rounds, resource pools and damage, cooldowns, status effects, knockback, hit detection with lag compensation, projectiles, zones and courses, abilities, movement, vehicles, interaction and animation sets, all under the Server Authority rules of [docs/runtime-kits.md](runtime-kits.md) (section 6). The contract (env, tiers, probes, requires) is that file; this one is the API reference. The skill that says when to use what is [roblox-gameplay-kit](../.agents/skills/roblox-gameplay-kit/SKILL.md).

SETUP_ONLY: no content ships. Ids, numbers, effect kinds and clip names are the game's. Where a default is not a Roblox engine value it is labelled a convention, in the code and below.

## 1. Modules

Every core is T0 (pure Luau, runs in Lune with `tests/fakes/FakeEnv.luau`); every adapter is T3: its pure mappings run in Lune with `@lune/roblox` (specs), and its engine behaviour is pending the named Studio probe on the unpublished diagnostic place.

| Module | Tier | What it does | Spec |
|---|---|---|---|
| [RoundLoop](../packages/GameKit/RoundLoop.luau) | T0 | lobby, intermission, active, results on the Stage 0 Fsm; exact phase timing; late-join policies | `gamekit_action_round` |
| [RoundLoopRoblox](../packages/GameKit/RoundLoopRoblox.luau) | T3 `action_round_replication` | phase, time left, round, counts and fsm/1 state as six attributes, stepped by BindToSimulation | `gamekit_action_adapters` |
| [Vitals](../packages/GameKit/Vitals.luau) | T0 | health/shield/stamina pools, damage pipeline with modifiers and source records, death, downed, revive, regen | `gamekit_action_combat` |
| [Cooldowns](../packages/GameKit/Cooldowns.luau) | T0 | server-clock cooldowns with charges, capped keys | `gamekit_action_combat` |
| [StatusEffects](../packages/GameKit/StatusEffects.luau) | T0 | timed effects: stacking, ticks, tags, stat multipliers, immunity, se/1 serialisation | `gamekit_action_status` |
| [Knockback](../packages/GameKit/Knockback.luau) | T0 | velocity-change maths, blast falloff, ragdoll requests as events, combo limits | `gamekit_action_status` |
| [Hitbox](../packages/GameKit/Hitbox.luau) | T0 | sphere/box/capsule overlap and swept tests, pose history, melee activations, hit-claim validator (rewind at most 200 ms) | `gamekit_action_combat` |
| [HitboxRoblox](../packages/GameKit/HitboxRoblox.luau) | T3 `action_hitbox_shapecast` | GetPartBoundsInBox/Radius with an exact narrow phase, Raycast/Spherecast casters | `gamekit_action_adapters` |
| [Projectile](../packages/GameKit/Projectile.luau) | T0 | closed-form ballistic step (gravity, drag), pierce, simulation, client-shot validation | `gamekit_action_projectile` |
| [Zones](../packages/GameKit/Zones.luau) | T0 | AABB/sphere/prism zones with hysteresis, hazards, kill volumes, gates, courses (sectors, laps) | `gamekit_action_zones` |
| [ZonesRoblox](../packages/GameKit/ZonesRoblox.luau) | T3 `action_zones_enter_exit` | parts and attributes to zone definitions; a step that feeds character positions | `gamekit_action_adapters` |
| [Abilities](../packages/GameKit/Abilities.luau) | T0 | data-defined abilities, cast pipeline (cost, cooldowns, status blocks, range), channels | `gamekit_action_abilities` |
| [Movement](../packages/GameKit/Movement.luau) | T0 | sprint, jump (coyote, buffer, air jumps), dash, slide, ledge rules; teleport and fly checks | `gamekit_action_movement` |
| [MovementRoblox](../packages/GameKit/MovementRoblox.luau) | T3 `action_movement_humanoid` | applies controller output to a Humanoid; IAS input; ledge probe | `gamekit_action_adapters` |
| [Vehicles](../packages/GameKit/Vehicles.luau) | T0 | arcade car (throttle, steer, grip, drift, boost) in fixed steps; rig plan | `gamekit_action_vehicles` |
| [VehicleRigRoblox](../packages/GameKit/VehicleRigRoblox.luau) | T3 `action_vehicle_drive` | VehicleSeat chassis with hinge, servo, spring and prismatic constraints; arcade pivot mode | `gamekit_action_adapters` |
| [Interact](../packages/GameKit/Interact.luau) | T0 | server validation of prompt holds and touches: distance, hold time, line of sight, rate, cooldowns | `gamekit_action_interact` |
| [InteractRoblox](../packages/GameKit/InteractRoblox.luau) | T3 `action_interact_prompt` | ProximityPrompt builder and wiring, line-of-sight hook | `gamekit_action_adapters` |
| [AnimSet](../packages/GameKit/AnimSet.luau) | T0 | clips/1 slots and states, marker contract, an Animator-driving player (8-track cap) | `gamekit_action_animset` |
| [AnimSetRoblox](../packages/GameKit/AnimSetRoblox.luau) | T3 `action_animset_clip` | Animation hooks (game-supplied ids, or Studio-only temporary ids), priorities, Animator lookup | `gamekit_action_adapters` |
| [AuthorityRoblox](../packages/GameKit/AuthorityRoblox.luau) | T3 `authority_simulation_bind` | shared Server Authority plumbing: bindStep, the 64-attribute writer, AuthorityMode, raw IAS builder | `gamekit_action_adapters` |

`AuthorityRoblox` is not in the frozen module list of runtime-kits.md section 11; it is reported to the coordinator for addition.

## 2. Conventions shared by every module

- **Refuse, do not raise, on client data.** Every function that takes untrusted input (positions, claims, requests, inputs) returns `(false, reason)` or a record with `reason`, never raises, and changes nothing on refusal. Definitions are game data: `define`/`new` raise with every problem joined; `validate` returns the problem list.
- **Server clock only.** Time comes from `env.clock()` (`time()` in Roblox). No method takes a time from the caller except the claim timestamps the validators check against their rewind windows.
- **Steps never yield.** `step`, `tick` and `update` are safe inside `RunService:BindToSimulation`. Catch-up is bounded (`MAX_TRANSITIONS_PER_TICK`, `MAX_TICKS_PER_STEP`, `MAX_SUBSTEPS`, `Zones.MAX_TICKS_PER_UPDATE`).
- **Deterministic.** Randomness comes from `env.rng(seed)` (ProcGen/Rng): crits, drift noise and animation variants. Iteration that reaches events is ordered (ids, join order).
- **Bounded.** Keys, bodies, effects, projectiles, log sizes and history rings have caps, so spam cannot grow memory.
- **Integer-safe pools.** Vitals rounds damage to integers by default (`rounding = "round"`), carries fractional regen, and caps values at 2^31 - 1.

## 3. Combat: Vitals, Cooldowns, StatusEffects, Knockback

**Vitals.** `Vitals.define({ pools = { health = { max, start?, regen?, regenDelay? }, ... }, absorb?, rounding?, downed? = { bleedout, reviveHealth?, finishable? }, logSize?, modifiers? })`, then `Vitals.new(spec, { modifiers?, seed? }, env)`. `damage({ amount, kind?, crit?, source? = { attacker?, ability?, weapon?, position? }, tags? })` runs the modifiers in priority order (built-ins: `Vitals.crit`, `resist`, `armor`, `flatArmor`, `cap`, `scale`), rounds, absorbs through the pools in `absorb` order and returns a record `{ ok, reason?, requested, amount, applied, absorbed, overkill, kind, crit, lethal, state, source, t }`. Refusal reasons: `bad_input`, `bad_kind`, `dead`, `invulnerable`, `cancelled`. Also `heal`, `canSpend`/`spend`/`restore` (stamina, mana), `kill`, `revive`, `setInvulnerable`, `step(dt)` (regen, bleed-out), `recent`, `killer`, `assists`, `snapshot`. Signals: `changed`, `damaged`, `died`, `downed`, `revived`.

**Cooldowns.** `Cooldowns.new(env)` or `Cooldowns.new({ maxKeys }, env)`. `use(key, seconds, charges?) -> (ok, remaining, reason?)` with `cooldown` or `full`; `ready`, `remaining`, `charges`, `extend`, `reset`, `clear`, `snapshot`/`restore`. Charges recharge one per period, in sequence. Floating slack `EPSILON = 1e-9`.

**StatusEffects.** `StatusEffects.define({ { id, duration, stacking?, maxStacks?, maxDuration?, tickInterval?, tags?, modifiers?, immunityAfter?, dispellable? } })`, `StatusEffects.new(book, { limit? }, env)`. `apply(id, { source?, stacks?, duration?, magnitude? })` refuses with `unknown_effect`, `immune`, `full`, `ignored`, `bad_input`; `step()` emits `tick` and `expired` events in id order (at most 64 ticks per effect per step); `multiplier(stat)` multiplies modifiers per stack; `grantImmunity(key, seconds)` with `key` an id or `tag:<tag>`; `serialize()` packs everything into one `se/1` attribute string, `restore` reverses it.

**Knockback.** `Knockback.compute({ origin, target, direction?, force, upward?, radius?, falloff? = none|linear|quadratic, resistance?, maxSpeed?, horizontal? }) -> { velocity, speed, strength, direction, ragdoll, ragdollDuration }`; `Knockback.impulse(result, mass)` for `BasePart:ApplyImpulse`. `Knockback.new({ ragdollThreshold?, ragdollDuration?, immunity?, immunityScale?, comboWindow?, comboLimit? }, env)` tracks targets: `apply(target, params) -> (result?, reason?)` with `bad_params`, `immune`, `combo_limit`, `no_effect`, and fires `ragdollRequested(target, request)`; the core never touches physics. `DEFAULT_RAGDOLL = 1.5` s is a convention.

## 4. Hit detection: Hitbox and HitboxRoblox

**Shapes.** `Hitbox.sphere(center, radius)`, `Hitbox.box(center, size, rotation?)`, `Hitbox.boxAxes(center, size, right, up, back)`, `Hitbox.capsule(a, b, radius)`; `closestPoint`, `distance`, `contains`, `overlaps` (all nine pairs, box-box by separating axes), `segment(shape, origin, delta, radius?) -> (hit, fraction?, point?)` (first contact of a moving point or sphere), `sweepPoses(prev, curr, maxStep?)`, `bounds`, `translate`, `lerp`.

**History.** `Hitbox.history({ capacity? = 32 })`: `record(t, shape)` (non-decreasing time; equal time replaces), `at(t)` (interpolated; `too_old` before the oldest sample), `latest`, `oldest`.

**Melee.** `Hitbox.activation({ maxHits?, ignore? })`: `test(shape, targets)` and `sweep(prev, curr, targets, maxStep?)` hit each target at most once per swing, without tunnelling through thin targets.

**Claim validator.** `Hitbox.validator({ maxRange, maxRewind? <= 0.2, interpolationDelay? = 0.1, jitter? = 0.05, originTolerance? = 4, hitTolerance? = 0.5, maxAngle?, fireInterval?, burst? = 2, clampOld?, futureTolerance? = 0.01, seenLimit?, capacity?, lineOfSight?, alive? }, env)`. Each simulation step `record(id, shape)` for every entity; `setLatency(id, seconds)` from the server's measurement; `check({ shooter, target, time, origin, direction, hitPoint?, shotId? }) -> (ok, reason?, detail)`. The rewind window is `min(maxRewind, latency + interpolationDelay + jitter)`. Reasons, in check order: `bad_claim`, `rate_limited`, `self_hit`, `unknown_shooter`, `unknown_target`, `duplicate_shot`, `future_time`, `too_old`, `origin_mismatch`, `out_of_range`, `bad_angle`, `hitpoint_mismatch`, `miss`, `no_line_of_sight`, `target_dead`. `stats()` counts accepted and rejected by reason. The defaults other than the 200 ms cap are conventions.

**HitboxRoblox.** `shapeOf(part)`, `frame(shape, roblox)`, `query(worldRoot, shape, overlapParams, roblox)` (bounds broad phase, exact narrow phase), `sweepQuery(...)`, `caster(worldRoot, raycastParams, roblox, { resolve? })` (a Projectile cast: Raycast at radius 0, Spherecast otherwise, excluding what this projectile already hit through a per-cast copy of the params), `record(validator, id, part)`. Engine casts miss parts the cast starts inside.

## 5. Projectiles

`Projectile.define({ speed, maxRange, gravity? (number or vector), drag?, maxLifetime?, radius?, pierce? (count) })`. Motion is the closed form of `dv/dt = g - k v`, so `positionAt`/`velocityAt` agree with any step split and consecutive segments share endpoints. `launch(spec, origin, direction, { id?, owner?, inherit? })`, `step(spec, state, dt, cast?) -> (state, events)` (events `hit`, `expired`, with `pierced` on pierce); a cast is `(origin, delta, radius, state) -> { fraction, position, normal?, target?, pierceable? }?` and should ignore `state.hitSet`. `Projectile.simulation(spec, { maxActive? }, env)`: `fire`, `step(dt, cast)`, `get`, `remove`, `count`.

Client-predicted shots: `validateFire(spec, { origin, direction, time }, { now, window?, shooterPose?, originTolerance? })` (`bad_claim`, `future_time`, `too_old`, `origin_mismatch`), then `validateHit(spec, shot, { hitPoint, time, target? }, { now, targetPose?, positionTolerance? = 2, timeTolerance? = 0.1, ... })` which adds `bad_timing`, `too_late`, `off_trajectory` (tolerance + radius), `out_of_range` and `target_mismatch`. `validateShot` is the trajectory check alone. Tolerances are conventions.

## 6. Zones and courses

Shapes: `Zones.aabb(min, max)`, `Zones.box(center, size)`, `Zones.sphere(center, radius)`, `Zones.prism(points, minY, maxY)` (polygon in XZ; self-intersecting or zero-area polygons are refused). `distance` is the exact signed distance; `contains(shape, p, margin?)`; `crosses(shape, a, b)` is the exact segment test.

`Zones.define({ { id, shape, kind? = area|hazard|kill|gate, hysteresis? = 0.5, priority?, tags?, hazard? = { amount, interval, damageKind?, immediate? }, gate? = { order, finish?, direction?, minTime? }, data? } })`. `Zones.tracker(set, { maxBodies? }, env)`: `update(id, position) -> (events, reason?)` emits `enter`/`exit` (gates and kill volumes are swept, so fast bodies cannot pass through unseen), `hazard` ticks on the server clock and `kill`; `step(positions)`, `remove`, `inside`, `current`, `isInside`, `occupants`. The tracker only reports: the caller applies damage through Vitals. Hysteresis 0.5 studs is a convention.

`Zones.course(set, { laps? }, env)`: `start(body)`, `observe(trackerEvents)` or `cross(body, zone, forward)`, emitting `sector`, `lap`, `finish`, and refusals `wrong_gate` (out of order), `wrong_way` (crossed backwards) and `too_fast` (under `minTime`: teleports and shortcuts). `progress(body)`, `standings()`.

**ZonesRoblox.** `defFromPart(part)` reads `ZoneId`, `ZoneKind`, `ZoneHysteresis`, `ZonePriority`, `HazardAmount`, `HazardInterval`, `HazardKind`, `HazardImmediate`, `GateOrder`, `GateFinish`, `GateMinTime`, `GateDirectional` attributes; blocks become AABBs (or prisms when turned about Y), Ball parts spheres, other tilts are refused. `fromParts(parts)`, `positions(players)`, `start(tracker, { players, runService, course?, onEvents?, allowFallback? }, env)`.

## 7. Rounds

`RoundLoop.define({ phases?, durations = { intermission?, active?, results? }, minPlayers, maxPlayers?, lateJoin? = spectate|queue|join, joinWindow?, endOnAlive? })` (`endOnAlive` must be below `minPlayers`), `RoundLoop.new(spec, nil, env)`. `tick(now)` returns phase events `{ kind = "phase", phase, from, at, round, reason, result? }`; a late tick starts the next phase at the previous phase's end time, so 60 ticks a second and one tick a second give the same timeline. `join`/`leave`/`eliminate`, `finish(result?)`, `reset()`, `players`, `alive`, `spectators`, `queued`, `timeLeft`, `snapshot()` (`phase`, `timeLeft` (ceil, -1 when untimed), `round`, `players`, `alive`, `state` = `fsm/1:round:<phase>`). A player who played this round and left or was eliminated rejoins as a spectator. Signal `phaseChanged(phase, from, info)`.

**RoundLoopRoblox.** `attributes(snapshot, prefix?)` (six attributes, prefix `Round`), `read(holder, prefix?)`, `start(loop, { holder, players?, runService, prefix?, allowFallback?, onEvents? }, env) -> (stop, how)`.

## 8. Abilities

`Abilities.define({ { id, cost? = { [pool] = amount }, cooldown, charges?, castTime?, channel?, tickInterval?, effects = { { kind, phase? = release|tick|end, ... } }, target? = none|self|unit|point, range?, blockedBy?, interruptible?, refundOnInterrupt?, gcd? } })`. `Abilities.caster(book, { vitals?, cooldowns, statuses?, gcd?, origin?, locate?, checkTarget? }, env)`: `check(id, target?)`, `cast(id, target?)` refusing with `unknown_ability`, `dead`, `busy`, `blocked`, `global_cooldown`, `cooldown`, `bad_target`, `out_of_range`, `cost` (or the `checkTarget` hook's reason); `step()` releases wind-ups, ticks channels on exact times and interrupts on death or a blocking status; `interrupt(reason?, force?)`; `remaining(id)`; `serialize()` (fsm/1). Cost and cooldown are committed at cast start, so cast-cancel spam burns cooldowns. Effects are reported as events (and the `effect` Signal), never applied. `RANGE_TOLERANCE = 1` stud is a convention.

## 9. Movement

`Movement.define({ walkSpeed? = 16, gravity? = 196.2, sprint? = { multiplier, pool?, drain?, minToStart? }, jump? = { height? = 7.2, airJumps?, airJumpHeight?, coyoteTime? = 0.1, buffer? = 0.1 }, dash? = { distance, duration, cooldown?, charges?, airDashes?, cost? }, slide? = { speed, duration, minSpeed?, friction?, cooldown?, jumpCancel? }, ledge? = { minHeight, maxHeight, maxDistance, maxAngle?, climbTime } })`. `Movement.new(spec, { vitals?, cooldowns? }, env)`: `setInput(move, sprint)` (clamped to length 1, non-finite is zero), `setGrounded(bool)`, `request("jump"|"dash"|"slide"|"ledge", arg?)` refusing with `busy`, `cooldown`, `no_jumps`, `no_air_dash`, `bad_direction`, `cost`, `too_slow`, `bad_probe`, `too_far`, `too_low`, `too_high`, `not_facing`, `disabled`, `unknown_action`; `step() -> { mode, walkSpeed, velocity?, events }`; `maxSpeed()`, `serialize()` (fsm/1). The engine defaults are Roblox's; coyote time and the jump buffer are conventions.

Server travel checks: `Movement.limits(spec)` (or `Vehicles.limits`), `Movement.checkTravel(limits, from, to, dt, { tolerance? = 1.25, slack? = 2 })` refusing `bad_input`, `teleport`, `fly`; `Movement.watcher(spec, options, env)` keeps the last accepted position per body (`observe`, `teleport` for server-granted moves, `forget`) and returns `resetTo` for rubber-banding. Tolerance and slack are conventions.

**MovementRoblox.** `ACTIONS` (`gameplay.move`, `gameplay.sprint`, `gameplay.jump`, `gameplay.dash`, `gameplay.slide`), `readInput(controller, actions, last)` (IAS states to `setInput` and pressed edges), `apply(humanoid, root, output, roblox)`, `grounded(humanoid)`, `ledgeProbe(...)`, `start(controller, { humanoid, root, runService, roblox, actions?, names?, ledge?, allowFallback?, onOutput? }, env)`.

## 10. Vehicles

`Vehicles.define({ maxSpeed, acceleration, brake, reverseSpeed?, coast?, steerRate, steerSpeed?, grip, drift? = { grip, minSpeed?, steer?, exitSlip?, noise? }, boost? = { multiplier, duration, cooldown }, step? = 1/60, rig? })`. `Vehicles.new(spec, { position?, heading?, seed? }, env)`: `step(dt, { throttle?, steer?, handbrake?, boost? }) -> (state, events)` integrates whole fixed steps (at most 8 per call; a longer hitch is dropped), `speed`, `place(position, heading)`, `snapshot()`. Heading follows Roblox: yaw 0 looks down -Z, positive yaw (and positive `steer`) turns left. `Vehicles.limits(spec)` feeds `Movement.checkTravel` for client-owned vehicles; `Vehicles.rigPlan(spec)` is the chassis data VehicleRigRoblox builds.

**VehicleRigRoblox.** `build(plan, roblox, { cframe?, parent?, name? })` (chassis, welded VehicleSeat, per wheel a prismatic strut with a spring, a servo knuckle on steering wheels, a motor hinge on drive wheels), `drive(rig, plan, throttle, steer)`, `seatInput(seat)`, `pivot(model, state, roblox)`, `startArcade(vehicle, model, options, env)`. Motor and servo signs are UNVERIFIED until `action_vehicle_drive` runs.

## 11. Interaction

`Interact.define({ { id, position?, kind? = prompt|touch, maxDistance? = 10, holdDuration? = 0, cooldown?, sharedCooldown?, exclusive?, lineOfSight? = true, radius?, touch? = { damage?, kill?, interval?, damageKind? }, gate?, data? } })` (defaults are ProximityPrompt's). `Interact.server(set, { rate?, window?, lineOfSight?, locate? }, env)`: `begin(player, id, position)`, `finish(player, id, position) -> (ok, reason?, event?)` (the server times the hold on its own clock), `cancel`, `touch(player, id, position)`, `setEnabled`, `remaining`, `forget`, `stats`. Reasons: `bad_input`, `unknown_target`, `wrong_kind`, `disabled`, `rate_limited`, `too_far`, `no_line_of_sight`, `busy`, `cooldown`, `not_held`, `too_quick`. Distance slack, hold slack, touch radius and the rate limit (8 per second) are conventions.

**InteractRoblox.** `prompt(def, roblox, { action?, object? })`, `rootPosition(player)`, `lineOfSight(worldRoot, roblox, exclude?)`, `connect(server, { prompts?, touchParts?, players, onEvent?, onRefused? }, env)`.

## 12. Animation sets

`AnimSet.validateClips(doc)` checks a clips/1 sidecar (runtime-kits.md 9.4). `AnimSet.define({ clips, slots? = { [slot] = { priority?, fadeIn?, fadeOut?, looped?, speed?, markers?, layer? } }, states? = { [state] = slot } })` binds clips to the standard slots (`idle`, `walk`, `run`, `jump`, `fall`, `climb`, `swim`, `sit`, `land`, `action_1` to `action_8`) and enforces the marker contract: every marker a slot lists exists in every clip bound to it. `AnimSet.player(set, animator, { animation, configure?, seed? }, env)`: `play(slotOrState, { speed?, weight?, fade? }?)`, `setState(state)`, `stop(slot, fade?)`, `stopAll`, `playing`, `clip`, `onMarker(name, fn) -> disconnect`, `destroy`. Tracks load once per clip; locomotion slots share layer `base`, each `action_n` has its own layer; at most 8 tracks play (the oldest lowest-priority one stops first).

**AnimSetRoblox.** `animationHook(ids, roblox)` (Animation instances with the game's own ids; this repo ships none), `previewHook(sources, env)` (Studio-only temporary ids through AnimationClipProvider or KeyframeSequenceProvider, refused outside an unpublished place; the exact provider method names are UNVERIFIED until `action_animset_clip` runs), `configure(roblox)` (Enum.AnimationPriority, Looped), `animator(owner, roblox)`.

## 13. Server Authority plumbing: AuthorityRoblox

`bindStep(runService, fn, { allowFallback? }) -> (stop?, how)` binds through `RunService:BindToSimulation` (`how = "simulation"`), falls back to PostSimulation only when asked (`"fallback"`), else `(nil, "no_bind_to_simulation")`. The return shape of BindToSimulation is UNVERIFIED (the probe settles it); `stop` disconnects it when it can. `writeAttributes(instance, values) -> (written, problems)` writes changed values only, in sorted name order, and refuses past 64 attributes per Instance, bad names and non-finite numbers. `count`, `validName`, `mode(workspace)` (`Server`, `Automatic`, `unknown`; AuthorityMode is set in Studio, not by script). `validateActions`/`buildActions(spec, roblox, parent?)` build a raw IAS InputContext, InputActions and InputBindings from data (KeyCode names such as `MouseLeftButton`, `ButtonR2`, `Thumbstick1`); `readAction(action)`. G4's InputMap replaces the raw build after merge.

## 14. Authority fixture

Opt-in with Workspace attribute `SETUP_ONLY_KitFixture = "authority"` on the kits place ([fixtures/kits.project.json](../fixtures/kits.project.json)); refused outside an unpublished Studio place.

- [authority_Arena](../fixtures/kits/shared/authority_Arena.luau) (shared ModuleScript): the core. Server-owned body markers move from client input through Movement; claims go through Cooldowns and the Hitbox validator; zones (an area, a hazard pad, a kill volume) apply through Vitals; RoundLoop runs the rounds. Input is token-bucketed (`rate_limited`), validated (`bad_input`), clamped and sequenced (`stale`). Numbers in `Arena.CONFIG` are fixture values, not tuning.
- [authority_Sim.server](../fixtures/kits/server/authority_Sim.server.luau): builds the floor, zone volumes and markers at y = 800 (a convention), the `SETUP_ONLY_Authority` holder with an `Input` (UnreliableRemoteEvent) and a `Claim` remote, steps the arena through `bindStep`, writes attributes through `writeAttributes`, and prints `AUTHORITY_EVENT <json>` lines.
- [authority_Input.client](../fixtures/kits/client/authority_Input.client.luau): builds `Arena.ACTIONS` as raw IAS, sends camera-relative input with a sequence number, raycasts primary presses against the markers and sends claims stamped with the `ArenaClock` attribute it sees.
- Remotes carry discrete, sequenced messages. Under AuthorityMode Server the engine may replicate InputAction state itself (UNVERIFIED); the validated remote works either way.

Run it: build the place (`rojo build fixtures/kits.project.json -o build/kits.rbxl`), open it as an unpublished place, set Workspace.AuthorityMode to Server and `SETUP_ONLY_KitFixture` to `authority` in Studio, then play with Server and 2 clients.

## 15. Probes

Registries: [server/action_probes](../fixtures/kits/server/action_probes.luau) (`action_round_replication`, `action_hitbox_shapecast`, `action_authority_projectile`, `action_interact_prompt`, `action_animset_clip`, `action_vehicle_drive`, `action_zones_enter_exit`, `action_movement_humanoid`) and [shared/authority_probes](../fixtures/kits/shared/authority_probes.luau) (`authority_simulation_bind`, `authority_mode`, `authority_attribute_budget`, `authority_input_actions`). Studio entries: `tests/engine/action_<probe>.luau` for each action probe and [tests/engine/action_authority_suite.luau](../tests/engine/action_authority_suite.luau) for the four authority probes. Probes build at y = 800, clean up even when they raise, and refuse published places.

In Lune both registries run against FakeEnv and [tests/fakes/FakeWorld.luau](../tests/fakes/FakeWorld.luau) (`gamekit_action_adapters`): every check passes except the engine-only ones listed there with their reason (AuthorityMode reads Automatic, IAS state defaults, Pressed and ProximityPrompt signals, physics, Animator playback, Humanoid floor detection). That proves loading and probe logic, not engine behaviour: all of them are pending a Studio run and need AuthorityMode = Server on the kits place.

## 16. Exploit coverage

| Attempt | Refused by | Reason | Spec |
|---|---|---|---|
| Hit from an impossible distance | Hitbox validator | `out_of_range` | `gamekit_action_combat`, `gamekit_action_authority` |
| Shooting from where the shooter is not | Hitbox validator, Projectile.validateFire | `origin_mismatch` | combat, projectile, slices |
| Claim older than 200 ms or in the future | Hitbox validator, Projectile | `too_old`, `future_time` | combat, projectile, slices |
| Rapid fire | Cooldowns, validator token bucket | `cooldown`, `rate_limited` | combat, authority, slices |
| Replayed shot | Hitbox validator | `duplicate_shot` | combat |
| Hit point off the target or the aim | Hitbox validator | `hitpoint_mismatch`, `bad_angle` | combat, slices |
| Teleporting or flying | Movement.checkTravel / watcher | `teleport`, `fly` | movement, slices (time_trial) |
| Gate shortcuts and wrong way | Zones.course | `wrong_gate`, `too_fast`, `wrong_way` | zones |
| Cooldown abuse by cast-cancel | Abilities (cost and cooldown at cast start) | `cooldown` | abilities |
| Forged touch from across the map | Interact | `too_far` | interact |
| Instant hold | Interact | `too_quick`, `not_held` | interact |
| NaN or huge numbers | every core | `bad_input`, `bad_claim`, `bad_amount` | all |
| Input floods, reordered input | authority_Arena | `rate_limited`, `stale` | authority |

## 17. Slices and golden

[tests/gamekit_slices_action.spec.luau](../tests/gamekit_slices_action.spec.luau) runs two seeded slices and stores their digests in [tests/golden/gamekit-action.json](../tests/golden/gamekit-action.json): `round_arena` (8 bots, 600 fixed steps of the authority arena: RoundLoop, Movement, Vitals, Hitbox, Cooldowns, Zones; bot 7 has 150 ms latency so its view is always older than the rewind cap; bot 8 tries every exploit) and `time_trial` (two Vehicles on a four-gate Zones course for 900 steps; one car's client teleports and reports NaN and is rubber-banded). Same seed, same digest. Update only on intended change: `FACTORY_UPDATE_GOLDEN=gamekit-action lune run tests/run.luau gamekit_slices_action`.

## 18. UNVERIFIED until a Studio run

- `RunService:BindToSimulation` return shape and dt argument (`authority_simulation_bind`).
- Whether Server Authority replicates InputAction state to the server (`authority_input_actions` covers the build only).
- Motor and servo signs and tuning of the constraint car (`action_vehicle_drive`).
- AnimationClipProvider / KeyframeSequenceProvider temporary-id method names (`action_animset_clip`).
- `Player:GetNetworkPing()` as one-way or round-trip latency (the validator clamps either way).
- Humanoid `FloorMaterial` and launch-velocity behaviour under Server Authority (`action_movement_humanoid`).
