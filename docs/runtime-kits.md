# Runtime kits: contract

Status: frozen at Stage 0 (2026-10-06) for the parallel build, then updated when all ten groups merged (same day). Every module in section 11 now exists. Change it like any shared contract: in the same commit as the code, with the specs that pin the change. Module names listed here are what playbooks, skills and the starter cite (`tools/playbook_lint.py` checks them).

The kits are SETUP_ONLY tooling: genre-neutral systems with no content, prices, economy numbers, themes or production UI. Function names (`primary_button`, `currency_a`, `enemy_basic`), never flavour.

## 1. Packages

| Package | Holds | Owner |
|---|---|---|
| `packages/GameKit` | Gameplay and platform systems; the Stage 0 foundation | Stage 0, G1, G2, G3, G4 (input), G5 (world cycle), G7, G9b (debug) |
| `packages/UIKit` | Tokens, styles, components, transitions, navigation, localisation, audits | G4 |
| `packages/Cinematics` | cinematics/1 cutscenes and camera paths | G4 |
| `packages/AVKit` | vfx/1 effects with pooling, audio-graph/1 mixer and cues | G5 |
| `packages/Feel` | Springs, shake, hit-stop, popups, safe flashes, haptics, cues | G5 |

Leaves the kits may also require (they stay require-free): `ProcGen/Rng`, `ProcGen/Grid`, `ProcGen/Graph`, `SceneKit/Vec`, `SceneKit/Lighting`. Authoring packages (`SceneKit`, `ProcGen`, `Pipeline`) and the inherited first pass (`Runtime`, `Creator`, `Diagnostics`) are not kits.

Places: [fixtures/kits.project.json](../fixtures/kits.project.json) maps every package under `ReplicatedStorage.Workbench` plus the kit fixtures ([fixtures/kits/README.md](../fixtures/kits/README.md)); `factory`, `creator` and `diagnostic` projects map the five kits too, so moved-module shims and probes resolve there. Use guides per kit: [gamekit-platform](gamekit-platform.md) (G1), [gamekit-action](gamekit-action.md) (G2), [gamekit-economy](gamekit-economy.md) (G3), [uikit](uikit.md) (G4, with Cinematics and InputMap), [presentation](presentation.md) (G5), [blender](blender.md) (G6), [scene-authoring](scene-authoring.md) (G7 courses and kit swaps).

## 2. Pure core plus adapter

- **Core** (`<Name>.luau`): pure Luau that runs unchanged in Lune and Roblox. It never touches Roblox globals: no `game`, `workspace`, `script`, `task`, `time`, `tick`, `os.time`, `os.clock`, `math.random`, `Random`, `Instance.new`, `GetService`. Time, scheduling, services, randomness and Roblox datatypes arrive through `env` (section 3). Vectors are plain tables in the `SceneKit/Vec` style (`{ x, y, z }`).
- **Adapter** (`<Name>Roblox.luau`): the thin layer that calls engine APIs (services, Instances, IAS, Audio, PathfindingService). It does no game logic beyond wiring and translation. Adapters are tier T3 or T4. Every engine-touching module uses the `Roblox` suffix: the planned `TeleportAdapter`, `PartyAdapter` and `VfxPoolAdapter` are named `TeleportRoblox`, `PartyRoblox` and `VfxPoolRoblox`.
- **Signatures**: `env` is the last parameter (`X.new(options, env)`, `Signal.new(env)`, `Fsm.new(spec, hooks, env)`, `Retry.run(fn, options, env)`); pure functions that need no time, services or randomness take none. Validators return a list of problem strings (empty when valid); `define`/`new` raise with every problem joined. Specs exercise the core with fakes and adapters only through their pure mapping functions (as `EnvRoblox.fromGlobals`).
- **Step functions** never yield, so an adapter can call them from `RunService:BindToSimulation` (section 6). Anything that yields (`Retry.run`, `Signal:Wait`) is documented as such and stays out of step functions.
- **Data keys**: Luau-first runtime tables use camelCase (settings/1, catalog/1, cinematics/1, vfx/1, audio-graph/1); formats written or read by Python tools use snake_case (kit-event/1 JSONL, clips/1, kit/1, material-library/1, perf/1, game-brief/1, release-check/1). Ids, keys, event names, states and slots are lower_snake labels (`Check.label`: a letter, then letters, digits or `_`, at most 64).
- **Conventions are labelled.** Limits not sourced from Roblox (44 px touch targets, breakpoint widths, retention windows, uiScale range) say "convention" in code and docs.
- **No init.luau** in kits: flat module files; a package facade is `<Kit>.luau` (for example `UIKit/UIKit.luau`), added by the coordinator after merge where the group file does not own it.

## 3. Env

[packages/GameKit/Env.luau](../packages/GameKit/Env.luau) defines the shape every core receives:

| Field | Meaning | Roblox (`EnvRoblox.studio()`) | Lune ([tests/fakes/FakeEnv.luau](../tests/fakes/FakeEnv.luau)) |
|---|---|---|---|
| `clock()` | Simulation seconds | `time()` (never `tick`, `os.time`, `os.clock`) | manual; `env:advance(dt)` |
| `defer(fn, ...)` | Run later this frame | `task.defer` | FIFO; `env:flush()` |
| `spawn(fn_or_thread, ...)` | Run now on a new thread | `task.spawn` | runs now; errors to `env.errors` |
| `wait(seconds?)` | Yield the calling thread | `task.wait` | parks until `advance` passes it (threads from `spawn`/`defer` only) |
| `services` | Name to service or fake | lazy `game:GetService`, cached | `env:register(name, fake)` |
| `rng(seed?)` | `ProcGen/Rng` factory | seeded, or entropy from `Random.new()` when no seed | seeded, or `"<seed>:<n>"` from a counter |
| `place` | `{ isStudio, gameId, placeId, isServer?, isClient? }` | `RunService` and `game.GameId`/`PlaceId` | Studio, unpublished, server |
| `roblox` | Roblox datatypes (`Instance`, `Vector3`, `CFrame`, `Color3`, `Enum`, `UDim2`, ...) | the globals | `require("@lune/roblox")` when a spec passes it |
| `report(message)` | Where swallowed errors go | `warn` | `env.reports` |

- `Env.new(parts)` fills defaults (clock, defer and wait required); `Env.validate(env)` lists problems; `Env.service(env, name)` raises naming a missing fake.
- `Env.check(place) -> (ok, reason)` is the diagnostic-place guard: ok only when `isStudio` and `GameId == 0` and `PlaceId == 0`; reasons `missing_place`, `invalid_place`, `not_studio`, `published_game`, `published_place`. `Env.assertDiagnostic(env, what)` raises. Debug-only code (DebugCommands, inspectors, probes) uses it. A Studio template place may report a non-zero PlaceId (UNVERIFIED); it is refused, which is the safe failure.
- `Env.studio()` (T3) forwards to [EnvRoblox](../packages/GameKit/EnvRoblox.luau)`.studio()`, the env for any Roblox session (Studio or live). Its mapping is `EnvRoblox.fromGlobals(globals)`, tested in Lune with fake globals; probe `foundation_env_studio` checks the real one.
- `tests/fakes/FakeEnv.luau` and `tests/lib/Golden.luau` are shared Stage 0 helpers: read them, never edit them. Group fakes are `tests/fakes/Fake<Thing>.luau` with names nobody else uses.

## 4. Stage 0 modules (frozen APIs)

Groups may require these (and only these) across group lines.

| Module | API |
|---|---|
| `GameKit/Check` | `finite(v)`, `integer(v)` (finite, whole, within 2^53), `label(v, max?)`, `assertFinite(v, what?)`, `copy(v)` (deep, cycle-safe), `freeze(v)` (deep), `describe(v)` |
| `GameKit/Json` | `encode(v, { indent? })`: canonical JSON (sorted keys, shortest round-trip numbers, NaN/inf to null, `Json.EMPTY_OBJECT` for `{}`); encode only |
| `GameKit/Env`, `EnvRoblox` | section 3 |
| `GameKit/Signal` | `new(env?)`; `:Connect(fn)`, `:Once(fn)`, `:Wait()`, `:Fire(...)`, `:FireDeferred(...)` (needs `env.defer`), `:DisconnectAll()`, `:Destroy()`; connection `.Connected`, `:Disconnect()`. Handlers run in connection order, each on its own thread; one that errors or yields never stops the rest; a Fire snapshots its handlers |
| `GameKit/Scope` | `new(env?)`; `:Add(obj, method?)` (functions, threads, Instances, connections, tables with Destroy/Disconnect), `:Connect(signal, fn)`, `:Extend()`, `:Remove(obj)`, `:Clean()` (LIFO, keeps going after an error, reusable), `:Destroy()` (final) |
| `GameKit/Fsm` | `define({ name?, initial, states = { s = { terminal? } }, transitions = { { from \| "*", event, to, guard? } } })`, `validate(def)`, `new(spec, { onEnter, onExit, onTransition }, env?)`; `:send(event, ctx) -> (ok, reason)` with reasons `unknown_event`, `no_transition`, `guard_rejected`, `queue_full` and `(true, "queued")` from hooks (queue of 32); `:can`, `:state`, `:pending`, `.changed` Signal; `:serialize()` gives `fsm/1:<name>:<state>`; `restore(spec, text, hooks?, env?) -> (machine?, reason?)` with `bad_format`, `wrong_spec`, `unknown_state` |
| `GameKit/Retry` | `run(fn(attempt), options, env?) -> (ok, resultOrError, attempts)`; options `attempts` (4), `base` (0.5 s), `factor` (2), `maxDelay` (30 s), `jitter` `full`/`equal`/`none`, `rng`, `retryable(err, attempt)`, `wait`, `onRetry`; `delay`, `delays`, `validate`, `classify(err)` (`throttle` for 301-306, `transient` for 5xx and uncoded errors, `fatal` for other codes), `dataStore(rng)` preset |
| `GameKit/Events` | kit-event/1 (section 9.1): builders `custom`, `economy`, `progression`, `funnel`, `onboarding`, `purchaseIntent`; `validate`, `isValid`, `stamp`, `encode`; sinks `recorder({ clock?, strict?, envelope? })` and `null()` |
| `GameKit/Settings` | settings/1 (section 9.2): `FIELDS`, `schema(extra)`, `defaults`, `validate`, `sanitize`, `merge`, `set`, `get`, `migrate(raw, { version, migrations, schema })`, `effective(values, system?)` |
| `GameKit/Catalog` | catalog/1 (section 9.3): `validate`, `define` (validated, frozen), `find(key)`, `byId(id)`, `list(tag?)`, `normalizeKind(legacyKind)` |
| `GameKit/Probe` | probe line protocol (section 7): `runAll(registry, { emit, env, kit, only })`, `run(name, fn, options)`, `checkLine`, `doneLine`, `validName` |

## 5. Tiers and the module header

Every kit module starts:

```luau
--!strict
-- @tier T3
-- probe: platform_remoteguard_flood
-- RemoteGuardRoblox: one or more lines saying what the module is.
```

| Tier | Meaning | Evidence |
|---|---|---|
| T0 | Pure Luau, proven in Lune | `lune run tests/run.luau <spec>` |
| T1 | Lune with `@lune/roblox` Instances | the same, with a Lune DataModel (the reflection DB may lack 2026 classes: check first, else load-only) |
| T2 | Builds and loads only | `rojo build` of a project that maps it, plus `kits_load` |
| T3 | Needs Studio on the unpublished diagnostic place | a named probe run on the owner's PC (pending until its output exists) |
| T4 | Needs a published place or live services (DataStores, MemoryStore, ConfigService, real text filtering, teleports, AnalyticsService delivery, purchases, BanAsync) | never claimed as verified in this factory; BLOCKED_EXTERNAL |

A module carries the tier of its least provable part. T3 modules must name a probe (`-- probe: <name>`); T4 modules may. The header block is the comment lines right after `--!strict`. [tests/kits_load.spec.luau](../tests/kits_load.spec.luau) enforces the header, the probe name and its registration, the require allowlist, no `GetService` in cores, no `init.luau`, and that every core loads in Lune; adapters are checked for header and requires only.

## 6. Server Authority rules

From the 2026 Server Authority release (gameplay-libraries research, section 3):

- **Stepping.** Simulation cores expose a non-yielding `step(dt)` or `tick(now)`; the adapter drives it from `RunService:BindToSimulation()` in a module initialised on both server and client. Nothing in the simulation path uses Heartbeat loops, `wait`, or yields.
- **Time.** Cores read `env.clock()`; adapters pass `time()`. Never `tick()`, `os.time()` or `os.clock()` in simulation code. Daily resets and live-ops windows take UTC seconds as an explicit argument from the adapter.
- **Input.** Only adapters read input, and only through Input Action System actions (`InputContext`, `InputAction`, `InputBinding`); never `UserInputService.InputBegan` in the simulation. `GameKit/InputMap` (G4) owns contexts and reserved actions (`ui.back`, `ui.confirm`, `cinematic.skip`); other groups take action names as strings. G2's authority fixture builds its actions through `InputMap` and `InputMapRoblox`.
- **Attributes.** Replicated simulation state lives in attributes written only inside `BindToSimulation` callbacks, at most 64 per Instance; a machine's state is one string attribute (`Fsm:serialize()`). Instances created in a simulation callback are parented before the frame ends. Remote events can arrive out of order with attribute updates, so remotes carry discrete requests only.
- **Signals.** Code works under `SignalBehavior = Deferred`: use `Signal:FireDeferred` (or engine events) and never rely on a handler having run synchronously.
- **Animation.** At most 8 playing tracks per Animator.

## 7. Probe contract

A T3 module is proven by a probe that runs in Studio, in a play session on the unpublished diagnostic place built from `fixtures/kits.project.json`.

- **Name.** `^[a-z][a-z0-9_]+$`, at most 64 characters, starting with an owner prefix: `foundation_` (Stage 0); `platform_` (G1); `authority_`, `action_` (G2); `economy_` (G3); `ui_`, `cin_`, `inputmap_` (G4); `lookdev_`, `av_`, `feel_`, `worldcycle_` (G5); `import_` (G6); `level_`, `lvl_` (G7); `kitsmoke_`, `perf_` (G9b). The module header's `-- probe:` line names it.
- **Registration.** A probe is a function `probe(ctx)` registered by name in its group's registry ModuleScript `fixtures/kits/<server|client|shared>/<prefix>_probes.luau`, which returns `{ [probeName] = fn }` and has no requires. Probes that cannot live in the kits place (G6's `import_*`, run after a manual import) are standalone `tests/engine/<probe>.luau` files. `kits_load` accepts either location.
- **Context.** `ctx.check(check, ok, detail?) -> ok` records one result; `ctx.env` is the runner's Env (`EnvRoblox.studio()` in Studio, FakeEnv in Lune); `ctx.kit("GameKit/Signal")` loads a kit module (from `ReplicatedStorage.Workbench` in Studio, by path in Lune); `ctx.probe` is the name. A probe that raises records check `error` with `ok = false`.
- **Lines.** The runner ([GameKit/Probe](../packages/GameKit/Probe.luau)) prints canonical JSON, one line per check and exactly one done line per run:

  ```text
  ENGINE_CHECK {"check":"place_is_diagnostic","detail":{"reason":null},"ok":true,"probe":"foundation_env_studio"}
  ENGINE_DONE {"checks":10,"errors":0,"failed":0,"ok":true,"passed":10,"probes":["foundation_env_studio"]}
  ```

  `ENGINE_CHECK` fields: `probe`, `check`, `ok`, `detail` (omitted when nil). `ENGINE_DONE` fields: `probes` (names run, sorted), `checks`, `passed`, `failed`, `errors` (probes that raised; their `error` check also counts as failed), `ok` (at least one check, none failed, none raised). A run without `ENGINE_DONE` failed.
- **Runners.** `tests/engine/<probe>.luau` is a Studio RunScript entry that loads the registry and calls `Probe.runAll(registry, { env = EnvRoblox.studio(), kit = loader, only = { name } })`; [tests/engine/foundation_env_studio.luau](../tests/engine/foundation_env_studio.luau) is the template. G9b owns `tools/studio_run.py` (Studio CLI, refuses `--placeId`, BLOCKED_EXTERNAL where Studio is absent) and `Pipeline/KitSmoke` (discovers every `*_probes` registry and runs them in one place).
- **Staging.** A probe that needs a world builds it at a high y offset (G2 uses 800, a convention), cleans up even when it raises, and refuses a published place (`Env.check`). Level probes (G7) get Workspace through `ctx.env`; in Lune their specs pass a stand-in table `{ instance = <Lune Workspace>, Gravity, Raycast }` plus a RaycastParams shim, because Lune has neither, and the registry's `stage()` accepts either form.
- **Play-session fixtures.** Probes that need Play run from the kits place when the Workspace attribute `SETUP_ONLY_KitFixture` names a fixture key (`kitsmoke`, `authority`, `ui-gallery`, ...; list in [fixtures/kits/README.md](../fixtures/kits/README.md)); `tools/studio_run.py --from-output` turns the saved Output into `reports/engine/<probe>.json`. Server Authority probes also need `Workspace.AuthorityMode = Server`, which only the owner can set in Studio.
- **Proof here.** Each group runs its registry in a Lune spec with FakeEnv and a path loader, so it loads and its logic holds against fakes. That is not Studio evidence: the probe stays pending and the module stays T3 until the owner's run produces the lines.

## 8. Require allowlist

String requires only: `require("./X")`, `require("../GameKit/Signal")`. A kit module may require:

- modules of its own package and of the other four kits;
- the leaves `../ProcGen/Rng`, `../ProcGen/Grid`, `../ProcGen/Graph`, `../SceneKit/Vec`, `../SceneKit/Lighting` (G5 keeps Lighting require-free; G8's starter copies the leaves next to the kits).

Never: `Runtime`, `Creator`, `Diagnostics`, `Pipeline`, other `ProcGen`/`SceneKit` modules, `tests/`, aliases (`@lune/...`, `@self`, `@game`), or instance requires (`require(script.Parent.X)`). The target must exist in your worktree: across groups, depend only on the Stage 0 modules (section 4) or on an interface the caller passes in (section 10); never require a module another group is writing in parallel.

## 9. Cross-group data contracts

### 9.1 kit-event/1 (GameKit/Events; producers: every kit; consumers: G1 Telemetry and analytics report)

One record per event. Envelope keys: `schema` (`"kit-event/1"`), `category`, `name` (lower_snake, at most 64), and optional `t` (simulation seconds from `env.clock`, stamped by the sink when absent), `timestamp` (UTC ISO 8601), `event_id`, `player` (opaque key such as `tostring(UserId)`, never a user name), `session_id`, `synthetic` (true for Lune, Studio and fixtures), `environment` (`lune`, `studio`, `live`), `fields` (at most 3 label keys to strings of 1-64 characters without commas or quotes; no free text).

| Category | Body | AnalyticsService target (G1 adapter) |
|---|---|---|
| `custom` | `value` (finite number, optional) | `LogCustomEvent` |
| `economy` | `economy = { flow = "source" \| "sink", currency (label), amount (> 0), balance (ending, >= 0), transaction_type (IAP, Shop, Gameplay, ContextualPurchase, TimedReward, Onboarding or a label), sku? }` | `LogEconomyEvent` |
| `progression` | `progression = { path (label), status = start \| complete \| fail \| custom, level (integer >= 0), level_name? }` | `LogProgressionEvent` |
| `funnel` | `funnel = { funnel (label), step (1-100), step_name (label), funnel_session_id }` | `LogFunnelStepEvent` |
| `onboarding` | `onboarding = { step (1-100), step_name (label) }` | `LogOnboardingFunnelStepEvent` |
| `purchase_intent` | `purchase = { stage = offer_viewed \| prompted \| prompt_closed \| granted \| failed, product (catalog/1 key), kind (devproduct \| gamepass \| subscription), surface? }` | G1 maps it (a funnel or custom event) and documents the mapping |

Limits enforced downstream by G1 Telemetry (Roblox-documented): 100 custom names, 10 funnels of 100 steps, 5 currencies, 20 transaction types, 3 custom fields. A sink is any table with `:emit(event) -> (accepted, reason?)`; producers take a sink as a parameter and never require Telemetry. Emit economy events after the durable write, never inside an `UpdateAsync` transform. `granted` comes from a processed receipt, never from a prompt-finished event. The canonical JSONL line is `Events.encode(event)`. The inherited `fixtures/analytics/neutral_events.jsonl` predates this format (schema_version 1 rows); G1's report reads both.

```json
{"category":"economy","economy":{"amount":10,"balance":25,"currency":"currency_a","flow":"source","transaction_type":"Gameplay"},"environment":"lune","name":"wallet_credit","player":"1","schema":"kit-event/1","synthetic":true,"t":12.5}
```

### 9.2 settings/1 (GameKit/Settings; persistence G1 SettingsStore; panel G4; readers G4, G5, G2 camera)

| Path | Kind | Default | Range or choices |
|---|---|---|---|
| `volume.master`, `volume.music`, `volume.sfx`, `volume.ui`, `volume.ambience`, `volume.dialogue`, `volume.world` | number | 1 | 0-1 (linear gain; buses match audio-graph/1) |
| `reducedMotion` | boolean | false | OR-ed with `GuiService.ReducedMotionEnabled` by `effective` |
| `screenShake` | number | 1 | 0-1 (scale) |
| `reduceFlashing` | boolean | false | the "flashes" setting; Feel also caps flashes at 3 per second (WCAG 2.3.1) |
| `subtitles` | boolean | true | |
| `colorblindMode` | enum | `none` | `none`, `protanopia`, `deuteranopia`, `tritanopia` |
| `uiScale` | number | 1 | 0.75-1.5 (convention) |
| `haptics` | boolean | true | |
| `cameraSensitivity` | number | 1 | 0.1-4 (convention) |
| `invertY` | boolean | false | |
| `language` | locale | `auto` | `auto` or a lowercase locale id (`en-us`, `pt-br`) |

The table also holds `schema = "settings/1"` and `version` (integer; the game bumps it with a migration). Each field has `group` (audio, display, accessibility, controls, language, game) and `labelKey = "settings.<path>"` for the panel. A game adds fields only under `game.*` through `Settings.schema(extra)`. Untrusted input (a client's change) goes through `merge`/`sanitize` on the server: values are clamped or defaulted and unknown keys dropped, with notes. Kits read `Settings.effective(values, { reducedMotion, hapticsSupported, locale })`: `reducedMotion`, `shakeScale` (0 under reduced motion), `allowFlashes`, `haptics`, `volume[bus]` (master x bus), `uiScale`, `colorblindMode`, `cameraSensitivity`, `invertY`, `subtitles`, `language` (auto resolves to the system locale, else `en-us`). Kits receive that table as a parameter; none reads settings globally.

```lua
{ schema = "settings/1", version = 1,
  volume = { master = 1, music = 0.6, sfx = 1, ui = 1, ambience = 1, dialogue = 1, world = 1 },
  reducedMotion = false, screenShake = 0.5, reduceFlashing = true, subtitles = true, colorblindMode = "none",
  uiScale = 1, haptics = true, cameraSensitivity = 1, invertY = false, language = "auto" }
```

### 9.3 catalog/1 (GameKit/Catalog; ownership checks and prompts G1 CommerceRoblox; display G4 ShopCard; legacy Runtime/CommerceCatalog moves to it, G1)

`{ schema = "catalog/1", mode = "setup" | "game", products = { Product } }`. Product keys:

| Key | Rule |
|---|---|
| `key` | label, unique; what code, UI and kit-event/1 `purchase.product` use |
| `kind` | `devproduct`, `gamepass`, `subscription` (legacy `developer_product`, `pass` map through `normalizeKind`) |
| `id` | integer > 0, or an `EXP-` id for subscriptions; placeholders `0` and `"EXP-0"`; real ids unique |
| `grants` | non-empty list of `{ type = "currency", currency, amount }`, `{ type = "item", item, count }`, `{ type = "entitlement", entitlement }`, `{ type = "custom", handler, data? }` (integers > 0; data maps labels to strings, numbers or booleans) |
| `display` | `{ nameKey, descriptionKey?, iconKey? }`: localisation and icon keys, never text |
| `enabled`, `ownershipVerified` | booleans; `ownershipVerified` is the owner's check that the id belongs to this game |
| `adReward?` | developer products only; fixed currency, item or entitlement grants (rewarded-ad rules: no random outcome) |
| `tags?`, `order?` | label list, integer |

Rules: no price-like key anywhere (`price`, `PriceInRobux`, `robux...`, `cost`): prices change per region and under Managed Pricing, so they are runtime reads (`GetProductInfoAsync` in CommerceRoblox), never data. Setup mode keeps every product disabled. Game mode needs real ids, and an enabled product needs `ownershipVerified = true`. Nothing here prompts or grants; prompts stay behind the guard hooks. The UI shows prices only from a price provider passed in: `provider:price(product) -> { state = "ok" | "pending" | "unavailable", text?, robux? }` (G1 implements it, G4 consumes it).

```lua
{ schema = "catalog/1", mode = "setup", products = {
  { key = "currency_pack_a", kind = "devproduct", id = 0, enabled = false, ownershipVerified = false,
    grants = { { type = "currency", currency = "currency_a", amount = 100 } },
    display = { nameKey = "shop.currency_pack_a.name", iconKey = "icon.currency_pack_a" } } } }
```

### 9.4 clips/1 (G6 writes `<asset>_clips.json` next to the clip files; G2 AnimSet and G6 ImportInspector read it)

| Key | Rule |
|---|---|
| `schema` | `"clips/1"` |
| `asset` | label of the rig or asset |
| `rig` | `r15_pose`, `r15_avatar` or `custom` |
| `fps` | integer > 0 (frames per second for every frame number below) |
| `files` | `{ glb = "<asset>_clips.glb", fbx = { [clip] = "<asset>_<clip>.fbx" } }` (names relative to the sidecar) |
| `clips[]` | `{ name, slot?, start, ["end"], loop, root_motion, priority?, weight?, markers }` |

- `name`: `^[a-z][a-z0-9_]{0,47}$`, unique. `slot`: one of the standard slots `idle`, `walk`, `run`, `jump`, `fall`, `climb`, `swim`, `sit`, `land`, `action_1` to `action_8`, or absent for an unslotted clip; several clips may share a slot with `weight > 0` (idle variants).
- `start` and `end` are inclusive integer frames, `end >= start`; duration is `(end - start) / fps` seconds. A loop's last frame repeats its first pose.
- `loop` and `root_motion` are booleans (`root_motion = false` means in place).
- `priority`: an `Enum.AnimationPriority` name (`Core`, `Idle`, `Movement`, `Action`, `Action2`, `Action3`, `Action4`); AnimSet defaults by slot when absent.
- `markers[]`: `{ name (label), frame (start..end), param? (string) }`. Blender's FBX does not carry markers (UNVERIFIED), so they travel here and fire `GetMarkerReachedSignal` names in Studio.

```json
{"schema":"clips/1","asset":"pet_follower","rig":"custom","fps":30,
 "files":{"glb":"pet_follower_clips.glb","fbx":{"idle":"pet_follower_idle.fbx","walk":"pet_follower_walk.fbx"}},
 "clips":[{"name":"idle","slot":"idle","start":0,"end":59,"loop":true,"root_motion":false,"priority":"Idle","markers":[]},
          {"name":"walk","slot":"walk","start":0,"end":29,"loop":true,"root_motion":false,"markers":[{"name":"footstep","frame":7,"param":"left"},{"name":"footstep","frame":22,"param":"right"}]}]}
```

### 9.5 kit/1 (G6 `factory.py kit` writes it; G7 `SceneKit/Kit.resolve` and `Apply.swap` read it; G9b asset fetch adds cc0 pieces)

`{ schema = "kit/1", id (label), pieces = [Piece] }`. Piece keys:

| Key | Rule |
|---|---|
| `key` | label, unique in the kit; placeholders carry it as their `asset` attribute |
| `source` | `procedural` (built by SceneKit, no file), `blender_template:<template>` (bkit template kind), or `cc0:<source>:<id>` (an asset-sources/1 source key and item id) |
| `file` | path of the exported model relative to the kit file, or null for procedural pieces |
| `bounds` | `{ min = [x, y, z], max = [x, y, z] }` in studs, relative to the pivot |
| `pivot` | `base_center` (default: bottom centre of the bounds, the B05 world-origin export rule), `center` or `origin` |
| `materials` | list of `library:<name>` (material-library/1), `builtin:<Enum.Material name>`, `atlas:<image file>` (palette atlas or baked set) or `vertex_color` |
| `provenance` | `local-template` for procedural and bkit pieces, else the asset-sources/1 key the file came from |
| `sockets?` | `[{ name (label), position = [x, y, z] (studs from the pivot), yaw (degrees) }]` |
| `collision?` | `box`, `hull`, `default` or `none` (CanCollide off) |
| `triangles?` | integer, for budgets |

```json
{"schema":"kit/1","id":"greybox_course","pieces":[
 {"key":"checkpoint_gate","source":"blender_template:checkpoint_gate","file":"checkpoint_gate.glb",
  "bounds":{"min":[-6,0,-1],"max":[6,10,1]},"pivot":"base_center","materials":["atlas:checkpoint_gate_atlas.png"],
  "provenance":"local-template","sockets":[{"name":"respawn","position":[0,0,-4],"yaw":180}],"collision":"box","triangles":412},
 {"key":"floor_tile","source":"procedural","file":null,"bounds":{"min":[-4,0,-4],"max":[4,1,4]},"pivot":"base_center",
  "materials":["builtin:SmoothPlastic"],"provenance":"local-template"}]}
```

### 9.6 material-library/1 (G5 owns `assets/material-library.json`; G6 bakes against its names and may write the same format for its own build outputs; SceneKit/Materials reads it)

`{ schema = "material-library/1", materials = [Material] }`. Material keys: `name` (label, unique; kit/1 cites it as `library:<name>`), `base_material` (`Enum.Material` name), `studs_per_tile` (> 0), `pattern` (`Regular` or `Organic`), `maps` (`color`, `normal`, `roughness`, `metalness`, `emissive`: each a reference or null; `color` and `emissive` are sRGB, the rest Non-Color; normals are OpenGL-style), `resolution` (power of two, at most 1024 unless `justify` explains 2048), `justify?`, `override_base` (boolean: use as the `SetBaseMaterialOverride` for its base material), `provenance` (asset-sources/1 key or `local`), `roblox` (`{ color, normal, roughness, metalness }` uploaded ids, `0` until the owner uploads in a game repo). A map reference is `<asset-sources key>#<file or channel>` (fetched into `build/asset-cache`) or `build:<path>` (a factory bake output).

```json
{"schema":"material-library/1","materials":[{"name":"concrete_a","base_material":"Concrete","studs_per_tile":8,"pattern":"Regular",
 "maps":{"color":"ambientcg/<AssetId>/1K-PNG#Color","normal":"ambientcg/<AssetId>/1K-PNG#NormalGL","roughness":"ambientcg/<AssetId>/1K-PNG#Roughness","metalness":null,"emissive":null},
 "resolution":1024,"override_base":false,"provenance":"ambientcg/<AssetId>/1K-PNG","roblox":{"color":0,"normal":0,"roughness":0,"metalness":0}}]}
```

### 9.7 perf/1 stats (G9b `Diagnostics/PerfProbe` writes; G5 `SceneKit/Budgets.check(stats, class)` reads; G5 owns the budgets half)

`{ schema = "perf/1", kind = "stats", device_class, frame_ms = { p50, p95, p99 }, memory_mb = { total, [category] = mb }, counts = { instances, parts, triangles, shadowed_lights, particle_rate, playing_sounds, highlights }, texture_mb_estimate, source = { place, scene_hash?, studio_version? } }`. Budgets are `{ schema = "perf/1", kind = "budgets", classes = { [device_class] = { <same counter names, frame_ms_p95, texture_mb_estimate> } } }` with documented and convention limits marked apart. Device classes (convention): `phone_low`, `phone`, `tablet`, `desktop`, `console`. A missing counter is absent, never 0.

### 9.8 Formats owned by one group

| Format | Owner | Where |
|---|---|---|
| fsm/1 string | Stage 0 | `Fsm:serialize()` |
| kit-event-report/1 | G1 | `tools/analytics_report.py` (offline report over kit-event/1 lines) |
| se/1 | G2 | `GameKit/StatusEffects` serialisation |
| dialogue/1, dialogue-session/1 | G3 | `GameKit/Dialogue` |
| wallet/1, inventory/1, progression/1, objectives/1, streaks/1, unlocks/1, season/1, generators/1, crafting/1, outfit/1, onboarding/1, economy-sim/1 | G3 | save snapshots and reports of the matching `GameKit` modules ([gamekit-economy](gamekit-economy.md)) |
| cinematics/1, cinematics-bake/1 | G4 | `packages/Cinematics`, [uikit](uikit.md) |
| inputmap/1, inputmap-overrides/1 | G4 | `GameKit/InputMap` |
| uikit-tokens/1, uikit-stylesheet/1, ui-audit/1 | G4 | `UIKit/Tokens`, `UIKit/Style`, `UIKit/Audit` |
| vfx/1 | G5 | `packages/AVKit` |
| audio-graph/1 | G5 | `packages/AVKit` (buses match settings/1 `volume.*`) |
| gltf-validate/1 | G6 | `tools/gltf_validate.py` |
| course/1 | G7 | `ProcGen/Course` manifests, checked by `ProcGen/CourseValidate` |
| placement/1 | G7 | `GameKit/PlacementGrid` |
| genre-taxonomy/1 | G7 | `.agents/skills/roblox-genre-systems/references/taxonomy.json` |
| starter/2, starter-deps/1 | G8 | the game repo's `starter.json`, `deps.json` |
| game-brief/1, production-pipeline/1 | G8 | the starter's `production/brief.json`, `production/pipeline.json` |
| release-check/1, release-meta/1, release-owner/1 | G8 | the starter's `release/` folder (`release/owner-*.json` is owner-written; the guards refuse agent writes) |
| boot-report/1 | G8 | the starter's boot skeleton (release item S07) |
| asset-sources/1, asset-cache/1 | G9b | `assets/sources.json`; the CC0 cache lives in `build/asset-cache` (never committed) |
| engine-report/1 | G9b | `reports/engine/<probe>.json` from `tools/studio_run.py` |
| kit-tiers/1 | G9b | `reports/kit-tiers.json` from `tools/kit_tiers.py` (gate step `kit-tiers`) |
| capture-manifest/1, capture-staleness/1 | G9b | `Pipeline/CaptureSet`, `tools/capture_staleness.py` |
| luau-defs-lock/1, luau-lsp-baseline/1 | G9b | `luau-defs.lock.json`, `tests/golden/luau-lsp-baseline.json` |
| pc-doctor/1, factory-skill-stamp/1 | G9b | `tools/pc_doctor.py`, `tools/user_skills.py` |

## 10. Interfaces passed in by callers

Across groups, depend on these shapes, not on each other's modules. The coordinator wires the real implementations after merge.

| Interface | Shape | Implemented by | Used by |
|---|---|---|---|
| Events sink | `sink:emit(event) -> (accepted, reason?)` | Stage 0 recorder/null, G1 Telemetry | every producer (G2, G3, G4, G7) |
| Key store | `store:get(key) -> any`, `store:set(key, value)`; values are plain data (`serialize()` output) | in-memory table in specs; G1 adapts a PlayerData session | G3 Inventory, Wallet, Onboarding; G1 SettingsStore |
| Policy predicate | `policyAllows(feature) -> boolean`, fail closed; features `paidRandomItems`, `trading`, `ads`, `externalLinks`, `socialLinks`, `voice` | G1 PolicyGate | G3 OddsTable (paid rolls), Trade; G4 links |
| Price provider | `provider:price(product) -> PriceInfo` (section 9.3) | G1 CommerceRoblox | G4 ShopCard |
| Effective settings | the `Settings.effective` table | Stage 0 | G4, G5, G2 camera |
| Input actions | action name strings (`gameplay.primary`, `ui.back`) | G4 InputMap | G2, G5, G4 |
| Clips and kits | clips/1 and kit/1 tables decoded from JSON | G6 | G2 AnimSet, G7 Kit |
| Animator-like | `animator:LoadAnimation(animation) -> track` with `Play`, `Stop`, `AdjustSpeed`, `GetMarkerReachedSignal`, `Length` | Roblox; G2 FakeAnimator | G2 AnimSet, G5 Feel HitStop and Cues |

## 11. Module ownership list

Names are `Package/Module`; all of them exist since the merge. `playbook_lint` (G7) and the starter (G8) cite only names from this list.

| Owner | Modules |
|---|---|
| Stage 0 | `GameKit/Check`, `GameKit/Json`, `GameKit/Env`, `GameKit/EnvRoblox`, `GameKit/Signal`, `GameKit/Scope`, `GameKit/Fsm`, `GameKit/Retry`, `GameKit/Events`, `GameKit/Settings`, `GameKit/Catalog`, `GameKit/Probe` |
| G1 platform services | `GameKit/RateLimit`, `GameKit/Schema`, `GameKit/RemoteGuard`, `GameKit/RemoteGuardRoblox`, `GameKit/PlayerData`, `GameKit/PlayerDataRoblox` (real ProfileStore sessions T4), `GameKit/Telemetry`, `GameKit/TelemetryRoblox`, `GameKit/Config`, `GameKit/ConfigRoblox` (T4), `GameKit/PolicyGate`, `GameKit/PolicyGateRoblox`, `GameKit/TextFilter`, `GameKit/TextFilterRoblox` (T4), `GameKit/SettingsStore`, `GameKit/Commerce`, `GameKit/CommerceRoblox` (T4), `GameKit/Moderation`, `GameKit/ModerationRoblox` (T4), `GameKit/Queue`, `GameKit/MemoryQueueRoblox` (T4), `GameKit/TeleportRoblox` (T4), `GameKit/PartyRoblox` (T3, probe `platform_party_simulator`) |
| G2 action | `GameKit/RoundLoop`, `GameKit/RoundLoopRoblox`, `GameKit/Vitals`, `GameKit/Cooldowns`, `GameKit/Hitbox`, `GameKit/HitboxRoblox`, `GameKit/Projectile`, `GameKit/Zones`, `GameKit/ZonesRoblox`, `GameKit/Abilities`, `GameKit/Vehicles`, `GameKit/VehicleRigRoblox`, `GameKit/Interact`, `GameKit/InteractRoblox`, `GameKit/AnimSet`, `GameKit/AnimSetRoblox`, `GameKit/Movement`, `GameKit/MovementRoblox`, `GameKit/StatusEffects`, `GameKit/Knockback`, `GameKit/AuthorityRoblox` (shared Server Authority plumbing, probe `authority_simulation_bind`) |
| G3 economy | `GameKit/Wallet`, `GameKit/EconomySim`, `GameKit/ItemDefs`, `GameKit/Inventory`, `GameKit/Progression`, `GameKit/Objectives`, `GameKit/Streaks`, `GameKit/OddsTable`, `GameKit/Followers`, `GameKit/FollowersRoblox`, `GameKit/Trade`, `GameKit/Plots`, `GameKit/Generators`, `GameKit/Crafting`, `GameKit/LiveOps`, `GameKit/Outfits`, `GameKit/OutfitsRoblox`, `GameKit/Dialogue`, `GameKit/Onboarding`, `GameKit/UnlockGraph`, `GameKit/SeasonTrack`, `GameKit/VotingRound` |
| G4 UI kit and cinematics | `GameKit/InputMap`, `GameKit/InputMapRoblox`, `UIKit/UIKit`, `UIKit/Tokens`, `UIKit/Style`, `UIKit/StyleRoblox`, `UIKit/Build`, `UIKit/Breakpoints`, `UIKit/State`, `UIKit/Ease`, `UIKit/Transitions`, `UIKit/Nav`, `UIKit/Localize`, `UIKit/Audit`, `UIKit/AuditRoblox`, `UIKit/Components/Button`, `UIKit/Components/IconButton`, `UIKit/Components/Toggle`, `UIKit/Components/Slider`, `UIKit/Components/Tabs`, `UIKit/Components/VirtualList`, `UIKit/Components/Grid`, `UIKit/Components/Modal`, `UIKit/Components/ConfirmDialog`, `UIKit/Components/Toast`, `UIKit/Components/Tooltip`, `UIKit/Components/ProgressBar`, `UIKit/Components/RollingCounter`, `UIKit/Components/Badge`, `UIKit/Components/Card`, `UIKit/Components/ShopCard`, `UIKit/Components/DialogueBox`, `UIKit/Components/SettingsPanel`, `UIKit/Components/LoadingScreen`, `UIKit/Components/TeleportTransition`, `UIKit/Components/StatBar`, `UIKit/Components/Timer`, `UIKit/Components/Countdown`, `UIKit/Components/LeaderboardPanel`, `UIKit/Components/KeybindPrompt`, `UIKit/Components/InventoryGrid`, `UIKit/Components/TouchActionButton`, `UIKit/Gallery/Stories`, `UIKit/Gallery/Browser`, `Cinematics/Cinematics`, `Cinematics/Spline`, `Cinematics/CinematicsRoblox` |
| G5 look, sound and feel | `GameKit/WorldCycle`, `AVKit/Vfx`, `AVKit/VfxLibrary`, `AVKit/Pool`, `AVKit/VfxPoolRoblox`, `AVKit/AudioMixer`, `AVKit/AudioDirector`, `AVKit/AudioGraph`, `AVKit/AudioGraphRoblox`, `AVKit/AudioCues`, `AVKit/Music`, `Feel/Spring`, `Feel/Shake`, `Feel/HitStop`, `Feel/Popups`, `Feel/Screen`, `Feel/Haptics`, `Feel/Cues`, `Feel/FeelRoblox` |
| G7 level, AI and playbooks | `GameKit/Checkpoints`, `GameKit/WaveDirector`, `GameKit/NavAgent`, `GameKit/NavAgentRoblox`, `GameKit/Perception`, `GameKit/BehaviorTree`, `GameKit/PlacementGrid`, `GameKit/Leaderboard`, `GameKit/LeaderboardRoblox` (T4), `GameKit/LiveBoard`, `GameKit/LiveBoardRoblox` (T4), `GameKit/TeamBalance` |
| G9b harness | `GameKit/DebugCommands` |

Non-kit modules the groups also own (cited by skills, not by kits): G5 `SceneKit/Lighting`, `SceneKit/Budgets`, `SceneKit/Materials`, `SceneKit/Validate`; G6 `Pipeline/ImportInspector`; G7 `SceneKit/Kit`, `SceneKit/Apply`, `SceneKit/Measure`, `ProcGen/Course`, `ProcGen/CourseValidate`, `ProcGen/CourseScene`; G9b `Pipeline/KitSmoke`, `Pipeline/CaptureSet`, `Diagnostics/PerfProbe`, `Diagnostics/PerfProbeRoblox`. A group may add a module its group file does not list only by reporting it to the coordinator; folder layout inside a group's own package (for example `UIKit/Components/`) is the group's choice, flat file names excepted.

## 12. Determinism and goldens

- Randomness comes from `ProcGen/Rng` (through `env.rng(seed)`); same seed, same output. Rng stays byte-stable so every recorded hash keeps meaning; its xorshift32 core gives adjacent numeric seeds (1, 2, 3) near-identical first draws, so derive per-entity or per-round seeds from strings (`Rng.new("round:" .. n)`) or from forks of a string-seeded parent, not from consecutive integers. Digests use canonical JSON (`GameKit/Json`) and FNV-1a (`Golden.digest`, the `Manifest.hash` family).
- [tests/lib/Golden.luau](../tests/lib/Golden.luau): `Golden.assert(name, value)` compares with `tests/golden/<name>.json` and names the first differing path. It rewrites only when `FACTORY_UPDATE_GOLDEN` is `1` or a comma list naming the golden. The names `fixture-hashes` and `studio-smoke` are reserved for the gate and raise in a spec. Name spec goldens after your area (`gamekit_fsm`, `uikit_layout`) so groups never share one. Cross-kit behaviour is pinned by [tests/slices_integration.spec.luau](../tests/slices_integration.spec.luau) (golden `slices-integration`): seeded race, stalker-AI, projectile-arena, session-persistence and UI-onboarding slices, each composing three or more groups' modules with invariants, not only a digest.
- `python3 tools/check.py --update-golden=<name>[,<name>]` rewrites only those: `fixture-hashes` (G7 only, adding entries), `studio-smoke` (G9b), or spec goldens (passed to the specs as `FACTORY_UPDATE_GOLDEN`). Bare `--update-golden` rewrites everything and is the coordinator's. The `golden-update` step lists what was added or rewritten and FAILs when a named spec golden was not written by any spec (a typo cannot pass). `--tier fast` with the flag FAILs, because the fast tier runs no golden step. Without the flag the gate clears `FACTORY_UPDATE_GOLDEN` for every step, so a stray shell variable cannot rewrite a golden. Each group writes only the goldens its group file lists.

## 13. Research behind these rules

[gameplay-libraries](research/gameplay-libraries-2026-10.md) (GameKit design, Server Authority), [ui-cinematics-feel](research/ui-cinematics-feel-2026-10.md) (UIKit, Cinematics, Feel), [release-monetization-analytics](research/release-monetization-analytics-2026-10.md) (Telemetry, catalog, policy), [blender-animation-pipeline](research/blender-animation-pipeline-2026-10.md) (clips, kits), [visual-audio-assets](research/visual-audio-assets-2026-10.md) (vfx/1, audio graph, material library), [genre-coverage](research/genre-coverage-2026-10.md) (system list, tiers), [pipeline-audit](research/pipeline-audit-2026-10.md) (integration decisions).
