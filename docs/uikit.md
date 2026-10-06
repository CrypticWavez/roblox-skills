# UIKit, input map and cinematics

The factory's neutral UI layer (`packages/UIKit`), its Input Action System map (`packages/GameKit/InputMap*.luau`) and data-driven cutscenes (`packages/Cinematics`). Owner: G4. Contracts shared with other kits (Env, tiers, probes, settings/1, catalog/1) are in [runtime-kits.md](runtime-kits.md); research behind the choices is in [research/ui-cinematics-feel-2026-10.md](research/ui-cinematics-feel-2026-10.md).

Boundary (SETUP_ONLY): nothing here is game UI. Tokens are greyscale with placeholder hue slots, components are named by function (Button, ShopCard, DialogueBox), text is localisation keys with neutral kit defaults, and the shop card has no purchase call. A game fills the hue slots, its strings and its screens in its own repository.

## Contents

1. [Styling decision](#styling-decision)
2. [Tokens and Style](#tokens-and-style)
3. [Breakpoints and safe area](#breakpoints-and-safe-area)
4. [State](#state)
5. [Components](#components)
6. [Transitions and easing](#transitions-and-easing)
7. [Navigation and focus](#navigation-and-focus)
8. [Input map](#input-map)
9. [Localisation](#localisation)
10. [Audits](#audits)
11. [Gallery](#gallery)
12. [Loading screens and teleports](#loading-screens-and-teleports)
13. [Cinematics](#cinematics)
14. [Inherited modules](#inherited-modules)
15. [Verification](#verification)

## Styling decision

**Decision: a pure token resolver is the source of truth; native Styling is emitted from it, not the other way round.**

Roblox UI Styling (StyleSheet, StyleRule, StyleLink, StyleQuery, token attributes) gives live theming, Hover/Press/NonInteractable states and device queries with no framework. But Lune cannot evaluate a StyleSheet: `@lune/roblox` has no `StyleRule:SetProperties` and no selector engine, so a kit styled only through StyleSheets could not be checked in CI, and its audits (contrast, text size) would have no values to read.

So:

- `UIKit/Style` resolves tokens to exact property values (`Color3`, `FontFace`, `UDim`, padding, strokes). Components set those at build time, Lune specs see exact values, and transitions tween them.
- `Style.sheet(tokens)` describes the same tokens as a StyleSheet plan (token attributes such as `ColorText` and `SpaceMd`, one rule per tag and GuiState, one StyleQuery per breakpoint). `UIKit/StyleRoblox` turns the plan into instances (`apply`), links it to a ScreenGui (`link`) and swaps themes without repainting components (`retheme`).
- `StyleRoblox.instructions(plan)` is pure and Lune-tested. Whether the engine applies the rules (selectors, query conditions, precedence over properties set at build) is UNVERIFIED until probe `ui_style_sheet` runs in Studio.

Transitions do not use Styling transitions: the UIKit runner owns motion so every animation is interruptible and testable.

## Tokens and Style

`Tokens.resolve(theme?, overrides?, options?)` returns frozen tokens; themes `dark` (default) and `light`.

| Group | Contents |
|---|---|
| `space` | `none`, `xxs` 2 … `xxxl` 48 (px) |
| `radius`, `stroke` | corner radii (`none` … `pill`), stroke widths (`hairline`, `thin`, `thick`, `focus`) |
| `size` | `touchMin` 44 (convention), control heights 36/44/56, icons, `actionButton` 72 and `actionButtonSmall` 56 (convention), `panelMax` 560 and `contentMax` 1200 (convention) |
| `font`, `text` | built-in families (Builder Sans, Roboto Mono; no upload); text roles `caption`, `label`, `body`, `button`, `title`, `heading`, `display`, `numeric` with size, weight and line height; `textMin` 12 (convention) |
| `color` | greyscale palette mapped to slots: `background`, `surface`, `surfaceRaised`, `surfaceSunken`, `scrim`, `border`, `borderStrong`, `text`, `textMuted`, `textDisabled`, `textInverse`, `focus`, `track`, `fill`; hue slots `accent`, `danger`, `success`, `warning`, `info` (each with a `*Text` pair) are placeholders a game sets (`Tokens.TBD`) |
| `layer` | DisplayOrder z-layers: world 0, hud 10, panel 20, overlay 30, modal 40, toast 50, tooltip 60, cinematic 80, transition 90, debug 100 |
| `motion` | durations (`fast` 0.12 s … `emphasis` 0.6 s), named eases (`enter` Quint.Out, `exit` Quad.In, `move` Cubic.InOut, `emphasis` Back.Out), springs (`gentle`, `snappy`, `bouncy` as damping ratio and frequency), `reducedFade` 0.15 s |
| `alpha`, `contrast` | transparency steps; WCAG thresholds (4.5 body, 3 large text and UI parts) |

- Colours are `{ r, g, b }` triples, so tokens are pure data; `Style.color` makes the Color3 through `env.roblox`.
- `options.colorblindMode` (settings/1 `accessibility.colorblindMode`) applies a game's per-mode slot overrides.
- `Tokens.contrast(a, b)` is the WCAG ratio; `Tokens.validate` checks every slot and every text-on-surface pair; `Tokens.digest` hashes a token set.
- Text always uses `FontFace` (`Font.new` on a built-in `rbxasset://fonts/families/*.json` family), never the legacy `Font` enum.

## Breakpoints and safe area

`Breakpoints.classify({ viewport, input?, tenFoot?, vr?, insets?, uiScale? })` returns a class: `device` (`phone`, `tablet`, `desktop`, `console`, `vr`), `input` (PreferredInput name), `orientation`, `touch`, `viewport`, `safe` rectangle, `columns`, `margin`, `gutter`, `scale` and `minTouch`. The thresholds are conventions in `Breakpoints.CONVENTION`; a game can override them. `Breakpoints.queries()` emits the matching StyleQuery definitions (including `PreferredTextSize`), so engine queries and Lune rules agree.

ScreenGuis made by `Build.screenGui` use `ScreenInsets.CoreUISafeInsets`; full-bleed covers (scrims, letterbox, loading) pass `fullscreen = true`.

## State

`State.value(x)`, `State.computed(deps, fn)`, `:observe(fn)` and `State.batch(fn)`. Propagation is glitch-free (each dependent recomputes once, in depth order, before observers run), equal values do not propagate, observers are bounded and an erroring observer is reported without stopping the others. Passing a Stage 0 `Scope` ties a node's lifetime to it.

## Components

Every component is `Build.component(spec)`:

```luau
local ctx = UIKit.context({ env = env, class = class })   -- tokens, class, motion, text, events, scope, runner
ctx.runner:attach(env)                                     -- motion and timers on RunService.PreRender
local handle = UIKit.Components.Button.mount({ textKey = "uikit.confirm", onActivated = fn }, ctx, parent)
handle:update({ disabled = true })
handle:destroy()                                           -- every Instance and connection it made
```

- `build(props, ctx) -> (root, parts)` creates Instances only (it runs in Lune on `@lune/roblox`); `mount` also wires behaviour through `ctx.on(instance, event, fn)` and `ctx.onChanged(instance, property, fn)`. Lune specs pass a fake event hub (`tests/fakes/FakeUIEvents.luau`).
- Props are validated against a schema; errors read `Component: field must be …` and `Component: unknown prop X (allowed: …)`.
- Instance names are stable and documented in each module header (specs check them).
- Text comes from keys through `ctx.text`; `text` props are for dynamic values.
- Mount children with the parent handle's `handle.ctx`, not the parent's own `ctx`: children mounted on the outer `ctx` survive the parent's `destroy` and keep their connections (the onboarding slice in `tests/slices_integration.spec.luau` counts them).

| Component | Function |
|---|---|
| Button, IconButton, Toggle, Slider, Tabs | controls with press feedback, focus ring and gamepad selection |
| VirtualList, Grid | long lists with pooled rows; responsive grids |
| Modal, ConfirmDialog, Toast, Tooltip | dialogs over a scrim (SelectionGroup with Stop edges), queued toasts (max visible, dedupe), tooltips placed inside the safe area |
| ProgressBar, RollingCounter, Badge, Card, StatBar, Timer, Countdown | progress and value displays; counters roll on the runner |
| ShopCard | one catalog/1 product by key; price comes from a runtime price provider; no purchase call (the spec scans the file); setup-mode watermark |
| DialogueBox | speaker, typewriter reveal (MaxVisibleGraphemes), choices |
| SettingsPanel | generated from the settings/1 schema (Stage 0 `GameKit/Settings`); every change goes through `Settings.set`; never saves |
| LoadingScreen, TeleportTransition | require-free covers for ReplicatedFirst (see below) |
| LeaderboardPanel, InventoryGrid | ranked rows; slot grid with selection |
| KeybindPrompt | "[E] Interact" with the glyph for the current device from InputMap |
| TouchActionButton | on-screen action button for touch; `InputMapKey` attribute lets InputMapRoblox bind it as an IAS UIButton |

## Transitions and easing

- `UIKit/Ease` mirrors `Enum.EasingStyle` and `Enum.EasingDirection` by name and value. Constants (Back 1.70158, Elastic period 0.3 and 0.45, Bounce 7.5625/2.75) are the common Penner ones; parity with `TweenService:GetValue` is probe `ui_ease_parity`. The sample table is golden `tests/golden/uikit-ease.json`.
- `Ease.spring({ dampingRatio, frequency })` is a closed-form damped spring (time-based, so frame-rate independent) with the same parameters as `Feel/Spring`.
- A plan is data: tracks `{ node, property, from?, to, delay, duration, ease | spring }`. Presets `fade`, `slide`, `scalePop`, `wipe`, `iris`; composition `sequence`, `parallel`, `stagger`.
- The runner is steppable and never yields. Starting a track on a target and property that is already animating interrupts it from its current value; springs inherit velocity. So open/close spam never jumps.
- `Transitions.reduce(plan)` is the reduced-motion form: opacity becomes a short linear fade (at most `motion.reducedFade`), everything else jumps to its end. `Build.play` applies it when `ctx.motion.reducedMotion` is set (settings/1 `effective().reducedMotion`, which folds in `GuiService.ReducedMotionEnabled`).

## Navigation and focus

`Nav.new({ selection, preferredInput }, env)` is a screen stack: `push`, `pop`, `replace`, `modal`, `back`.

- `back()` answers the reserved `ui.back` action: a dismissable modal closes, a screen with `onBack` decides, a deeper screen pops, the root is left to the game. A modal always consumes back.
- Focus restore: the selection when a screen is covered comes back when it is uncovered (the NativeUI pattern), falling back to the screen's focus target for gamepads. Keyboard and mouse get no forced selection.
- Screen roots become SelectionGroups; modals stop selection at their edges.
- Refusals (duplicate ids, a modal already open, a stack too deep, invalid screens) return a reason instead of raising.
- `Nav.guiSelection(GuiService)` adapts `SelectedObject`; probe `ui_nav_keyboard` checks it in Studio.

## Input map

`GameKit/InputMap` (inputmap/1) holds contexts and actions as data for the Input Action System; `GameKit/InputMapRoblox` builds the instances.

- Contexts: `gameplay` (priority 100), `ui` (200), `cinematic` (300, Sink, off until a cutscene plays).
- Every action has at least one binding for each device: KeyboardAndMouse, Gamepad, Touch. Bindings are KeyCode names, `Mod+Key` chords, directional tables, `ui:<key>` (an on-screen GuiButton, e.g. TouchActionButton) or `system:<key>` (controls the default PlayerScripts already provide).
- Reserved actions `ui.back`, `ui.confirm` and `cinematic.skip` can never be left without a binding on any device: `unbind` refuses the last one, `applyOverrides` keeps their defaults, and a seeded run of 600 random edits never leaves one unbound (spec).
- Keys the Roblox client uses (Escape, Tab, F9, ButtonStart, ButtonSelect) are refused as defaults and rebinds. `ui.back` uses Backspace and ButtonB for that reason.
- `rebind(map, action, device, index, binding, { swap })` refuses same-context conflicts unless `swap` gives the other action the old key; cross-context overlaps are allowed and listed by `overlaps(map)`.
- Rebinds are saved as `inputmap-overrides/1` data (`overrides(base, current)`) and re-applied with `applyOverrides(base, data)`. All overrides apply together, so a saved swap comes back; conflicts are reverted one at a time with a note.
- `glyph(map, action, device, style?)` gives the prompt text (key caps, Xbox or PlayStation names, or a touch marker). Device images come from `UserInputService:GetImageForKeyCode` through `ctx.glyphImage` in the adapter.
- `InputMapRoblox.build(map, env, { parent, buttons })` makes one InputContext per context, one InputAction per action (attribute `Action` = full name) and one InputBinding per binding (KeyCode, PrimaryModifier, Up/Down/Left/Right, or UIButton). Buttons that appear later attach with `bindButton`. Where an InputContext must live is not documented; probe `inputmap_contexts` checks construction in Studio. Whether a Sink context can take over the client's system keys is UNVERIFIED (they are refused instead).

## Localisation

`Localize.new({ locale?, fallback?, tables?, provider?, pseudo?, maxMissing? })` returns a localiser (`get`, `plural`, `has`, `setLocale`, `missing`, `fn`):

- Lookup order: locale (`pt-br`), its language (`pt`), the fallback (`en-us`), then the kit defaults `Localize.KIT`; a missing key shows `[key]` and is recorded in `missing()`.
- Parameters use the `Translator:FormatByKey` forms `{name}` and `{1}`. Plurals pick `key.<category>` with CLDR-style categories for a built-in set of languages.
- Pseudo-locale (`pseudo = true` or `Localize.pseudo(text)`) accents and pads text by about 40 percent, keeping `{params}` and rich-text tags, so audits catch overflow before translation.
- Adapters: `toEntries()` gives `LocalizationTable:SetEntries` data; `translatorProvider(translator)` wraps `FormatByKey` in a pcall.
- Every gallery story resolves without a missing key, and every InputMap default action has an `input.<action>` key (spec).

## Audits

`Audit.run(nodes, options)` returns a `ui-audit/1` report with stable rule ids:

| Rule | Flags |
|---|---|
| `touch_target` | interactive node under 44 px (convention) on touch devices |
| `contrast` | text below WCAG 4.5:1 (3:1 large); disabled text and text that is not drawn (TextTransparency 1) are exempt; partly transparent text is blended first |
| `text_size` | TextSize under 12 (convention; the Roblox docs floor is 9) |
| `safe_area` | interactive node (error) or text (warning) outside the safe rectangle |
| `overlap` | visible interactive siblings overlapping |
| `gamepad_reachable` | a Selectable node the gamepad cannot reach from the entry (explicit NextSelection links, else a nearest-in-direction heuristic honouring SelectionGroup and Stop) |
| `legacy_font` | a legacy font family (LegacyArial, Arial, GothamSSm; an unset FontFace reads LegacyArial) |
| `text_scaled` | TextScaled (it bypasses the player's PreferredTextSize) |
| `text_fit` | TextFits false, or pseudo-localised text likely to overflow |
| `shadow_budget` | more than 100 UIShadows |
| `canvas_group_size` | a CanvasGroup with AutomaticSize |

- Snapshots come from `Audit.fromInstances(root, { measure, textFits? })`. Paths are unique: duplicate sibling names get `#2`, `#3`.
- In Lune, `Audit.staticMeasure(viewport, safe)` folds scale, offset, anchor, padding and ScreenGui insets but ignores layouts, constraints and AutomaticSize, so `touch_target`, `overlap`, `safe_area` and `gamepad_reachable` need Studio truth.
- `AuditRoblox.audit(root, env, options)` (T3, yields) uses the engine's AbsolutePosition/AbsoluteSize and TextFits, a CoreUISafeInsets probe ScreenGui for the safe area, a pseudo-localisation pass (each text shows `Localize.pseudo` for a frame, TextFits is read, the text restored) and a legacy `Font` enum check. Lune cannot read `Font`, so only the FontFace rule runs there.

## Gallery

- `UIKit/Gallery/Stories.list(ctx)` returns one story per component, `{ name, build }`, where `build(target) -> cleanup` is the UI Labs function-story signature. Content is neutral: kit keys, placeholder names, a setup-mode catalog with a disabled placeholder product.
- `UIKit/Gallery/Browser.mount(target, { chrome, context, onSelected?, initial? })` is the story browser: a sidebar of stories, a stage, and toolbar switches for light theme, reduced motion, pseudo-loc and phone/desktop/console previews (the stage takes the device viewport and a UIScale fits it to the area).
- Fixture `fixtures/kits/client/ui_Gallery.client.luau` mounts the browser in PlayerGui only when the Workspace attribute `SETUP_ONLY_KitFixture` is `ui-gallery` on the unpublished kits diagnostic place, and prints one `UIKIT_AUDIT` line per story it shows. Use it with the visual-qa skill for screenshots; the pass/fail record is probe `ui_gallery_audit`.

## Loading screens and teleports

- `LoadingScreen` requires nothing (ReplicatedStorage may not have replicated yet), so it is safe in ReplicatedFirst; its look is a frozen copy of the dark tokens. The ReplicatedFirst script calls `RemoveDefaultLoadingScreen()`, drives `step(dt)` from PreRender, reports progress (smoothed, never backwards) and calls `finish()`.
- `TeleportTransition` is the same kind of require-free cover with a state machine `idle -> covering -> covered -> revealing -> done`. Continuity across a teleport:
  1. The source place builds the gui, plays `cover()`, and once covered calls `TeleportService:SetTeleportGui(gui)` and teleports.
  2. The destination's ReplicatedFirst script gets the gui from `TeleportService:GetArrivingTeleportGui()`, parents it, adopts it with `TeleportTransition.adopt(gui, env)` (state `covered`) and calls `reveal()` when its own loading is done.
  3. A failed teleport (`TeleportInitFailed`) calls `fail(text)`: the message shows and the cover reveals the place the player is still in.
- The real teleport is T4 (it needs published places) and is never claimed as verified here.

## Cinematics

### cinematics/1

```luau
{ schema = "cinematics/1", id = "label", duration = 8, space = "world" | "anchor",
  camera = { interpolation = "catmull_rom" | "linear" | "hold", timing = "keys" | "constant_speed",
             keys = { { t, position = { x, y, z }, lookAt = { x, y, z } | orientation = { pitch, yaw, roll },
                        roll?, fov, ease? } } },
  letterbox = { { t, v, ease? } },          -- bar height as a fraction of the screen, 0-0.25
  fades = { { t, v, ease? } },              -- black overlay opacity 0-1
  subtitles = { { t, duration, key } },     -- localisation keys, never text
  events = { { t, name, payload?, onSkip = "fire" | "drop" } },
  skip = { allowed, after, hold } }         -- default 0.75 s, 0.5 s hold (convention)
```

- `validate` returns every problem with its path (keys must be strictly increasing, inside 0..duration, FOV 1-120, roll within ±180, letterbox at most 0.25, bounded list sizes); `define` validates, copies and freezes.
- An `ease` on a key shapes the segment leaving it (`"Style.Direction"`, UIKit/Ease names; default linear). `catmull_rom` is centripetal Catmull-Rom (`Cinematics/Spline`, no cusps or self-intersections on uneven spacing); `constant_speed` re-times the path by arc length.
- With `space = "anchor"` positions are relative to a CFrame passed to `play`.

### Sampling, events and skip

- `sample(cin, t)` is a pure function of time: exact at keys, identical at any frame rate.
- `eventsBetween(cin, t0, t1)` returns events with `t0 < t <= t1`, so stepping frame by frame fires each event exactly once, on the frame that reaches it; the first frame uses `t0 = -huge`, so `t = 0` events fire on it. The player flushes the rest when it ends.
- `Cinematics.player(cin)` is the pure playback state machine: `step(dt, skipHeld)` returns the sample, the events crossed and the skip progress. Holding skip for `skip.hold` seconds once `skip.after` has passed skips to the end, firing only `onSkip = "fire"` events after the current time. `skip()` skips at once; `stop()` ends without events.
- `reduce(cin)` (reduced motion) turns camera moves into cuts between keys.
- `bake(cin, hz)` samples at a fixed rate (rounded to 1e-6) and `digest(cin, hz)` is an FNV-1a hash of its canonical JSON. The neutral orbit fixture `fixtures/kits/shared/cin_setup_only_orbit.luau` is golden `tests/golden/cinematics-orbit.json` (digest at 30 Hz `c7b46e8b`, at 60 Hz `d6332fbc`).

### CinematicsRoblox (T3)

`CinematicsRoblox.play(cin, { camera, env, parent?, anchor?, skipAction?, skipContext?, reducedMotion?, text?, subtitles?, onEvent?, onFinished? })`:

- sets the camera Scriptable for the run and restores CameraType, CFrame, Focus and FieldOfView when it finishes, is skipped or stopped; the camera being destroyed stops it;
- steps on `RunService.PreRender` and applies each sample (a look-at frame built with `CFrame.fromMatrix`, then roll; looking straight up or down uses +X as right, convention);
- shows an overlay ScreenGui (DisplayOrder 80, ScreenInsets None) with letterbox bars, a fade, subtitles and a hold-to-skip hint;
- takes skip input only through the IAS: `skipAction` is the `cinematic.skip` InputAction and `skipContext` its context, enabled for the run.

`keyFromCamera(camera, t, distance)` turns the current Studio view into a key for authoring. Probe `cin_play_sample` proves the camera, events, skip and restore on a real Camera.

## Inherited modules

- `Runtime/NativeUI` keeps its API (`panel(parent, options)` with `setState`, `setCards`, `setTheme`, `activate`, `focus`, `inspect`, `destroy`) for `fixtures/runtime/Diagnostic.client.luau`. Text uses FontFace; themes are RGB data (`NativeUI.color(theme, slot)`); env, events and measure are injectable, so it loads and runs in Lune (`tests/uikit_inherited.spec.luau`).
- `Creator/UI` uses string requires, cleans up through a Stage 0 Scope, waits for layout on PreRender, uses FontFace, and reads shop entries as catalog/1 products (`entry.id`, normalised kinds, placeholders never quoted).
- New UI work uses UIKit. The research audit recommends retiring both once games use UIKit.

## Verification

| What | How | Status |
|---|---|---|
| Tokens, style plan, breakpoints, state | `lune run tests/run.luau uikit_tokens` | Lune |
| Ease, transitions, runner, reduced motion | `uikit_transitions` (golden `uikit-ease`) | Lune |
| Navigation and focus | `uikit_nav` | Lune |
| Components, stories | `uikit_components` (real `@lune/roblox` Instances, FakeUIEvents) | Lune |
| Audits | `uikit_audit` (seeded bad trees, exact rule ids and paths) | Lune |
| Localisation | `uikit_localize` | Lune |
| Gallery browser | `uikit_gallery` | Lune |
| Probe registries with fakes | `uikit_probes` | Lune (not engine proof) |
| Input map | `gamekit_inputmap` | Lune |
| Cinematics | `cinematics` (golden `cinematics-orbit`) | Lune |
| Inherited NativeUI, Creator/UI | `uikit_inherited`, `lune run tests/creator/ui.luau` | Lune |
| Engine facts | probes `ui_ease_parity`, `ui_nav_keyboard`, `ui_gallery_audit`, `ui_style_sheet`, `inputmap_contexts`, `cin_play_sample` (`tests/engine/<probe>.luau`) | PENDING until run in Studio |

Lune limits found while building this (they are why the probes exist): `@lune/roblox` Instances have no events; reading `AbsolutePosition`/`AbsoluteSize` and `TextLabel.Font` fails; `StyleRule:SetProperties` is missing; `UIScale.Scale` is stored as float32; Lune 0.10's `CFrame.lookAt` mirrors targets on the Z axis (the cinematics adapter builds its frame with `fromMatrix`); a module's first `require` yields, so specs preload kit modules before running probes on FakeEnv threads.

Conventions (not Roblox numbers) are labelled "convention" in code: 44 px touch target, 12 px minimum text, breakpoint widths, action button sizes, toast duration, typewriter speed, skip timing, preview device sizes.
