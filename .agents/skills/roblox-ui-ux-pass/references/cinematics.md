# Cutscenes with cinematics/1

Authoring guide for `packages/Cinematics`. Format and API: docs/uikit.md, section "Cinematics". Neutral example: `fixtures/kits/shared/cin_setup_only_orbit.luau` (golden `tests/golden/cinematics-orbit.json`).

## Shape of a cutscene

```luau
local cin = Cinematics.define({
	schema = "cinematics/1", id = "intro_pan", duration = 6, space = "anchor",
	camera = {
		interpolation = "catmull_rom", -- smooth through every key; "linear" or "hold" (cuts)
		timing = "keys",               -- or "constant_speed": even speed along the path
		keys = {
			{ t = 0, position = { 0, 12, -30 }, lookAt = { 0, 4, 0 }, fov = 70, ease = "Sine.Out" },
			{ t = 3, position = { 20, 8, -10 }, lookAt = { 0, 4, 0 }, fov = 60 },
			{ t = 6, position = { 25, 6, 5 }, lookAt = { 0, 4, 0 }, fov = 55 },
		},
	},
	letterbox = { { t = 0, v = 0 }, { t = 0.6, v = 0.12, ease = "Quad.Out" }, { t = 6, v = 0.12 } },
	fades = { { t = 0, v = 1 }, { t = 0.5, v = 0, ease = "Quad.Out" } },
	subtitles = { { t = 1, duration = 2.5, key = "cin.intro.line_1" } },
	events = { { t = 0, name = "started", onSkip = "drop" }, { t = 6, name = "done", onSkip = "fire" } },
	skip = { allowed = true, after = 0.75, hold = 0.5 },
})
```

## Shot craft (conventions)

- **Keys every 1.5-4 s** for a moving shot; closer keys make the spline wobble. Use `constant_speed` when the path has uneven spacing and the speed must look even.
- **Ease into and out of the shot**, not inside it: `Sine.Out` on the first key, `Sine.In` on the last segment's start key; middle keys linear.
- **Look-at targets** are steadier than orientation keys for orbiting and tracking; use `orientation` (pitch, yaw, roll in degrees) for fixed framings.
- **FOV**: 70 is the Roblox default; 50-60 reads as cinematic and flattens; change FOV slowly (under about 10 degrees per second) or it reads as a zoom.
- **Roll** sparingly (a few degrees) and only with motion.
- **Letterbox** 0.1-0.12 of screen height per bar; fade it in over about 0.5 s.
- **Fades** cover cuts between locations: fade to 1, move the anchor, fade back.
- **Subtitles** are localisation keys; keep each on screen 2-4 s.
- **Events** carry names, not code. Mark anything the game must not miss (`done`, state changes) `onSkip = "fire"`; cosmetic beats `drop`.
- **Skip** after about 0.75 s with a 0.5 s hold, so a stray press never skips.

## Checking before Studio

1. `Cinematics.validate(cin)` lists every problem with its path; fix them all.
2. `Cinematics.sample(cin, t)` at a few times; `Cinematics.bake(cin, 10)` to read the whole path.
3. Spec it: events fire once at any frame rate (`Cinematics.player(cin)` stepped at 30, 60, 144 Hz), skip fires only `fire` events, and for a fixture a digest golden (`FACTORY_UPDATE_GOLDEN=<name> lune run tests/run.luau cinematics` when the change is intended).
4. Reduced motion: `Cinematics.reduce(cin)` turns moves into cuts; check the cut framing still reads.

## Playing in Studio

```luau
local built = InputMapRoblox.build(InputMap.defaults(), env, { parent = player.PlayerScripts })
local handle = CinematicsRoblox.play(cin, {
	camera = workspace.CurrentCamera, env = env, anchor = someCFrame,
	parent = player.PlayerGui,
	skipAction = built.actions["cinematic.skip"], skipContext = built.contexts.cinematic,
	reducedMotion = settings.reducedMotion, text = localizer:fn(),
	onEvent = function(name, payload, skipped) end,
	onFinished = function(state) end, -- finished | skipped | stopped
})
```

- Author keys from the Studio view: frame the shot, then `CinematicsRoblox.keyFromCamera(workspace.CurrentCamera, t, distance)`.
- The camera is restored on finish, skip, stop or camera loss; the overlay is removed.
- Probe `cin_play_sample` is the engine proof; until it runs on the unpublished diagnostic place, camera behaviour is PENDING.
