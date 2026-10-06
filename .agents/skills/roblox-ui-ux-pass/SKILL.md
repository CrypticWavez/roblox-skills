---
name: roblox-ui-ux-pass
description: Build, audit and polish Roblox UI and front-end flow with UIKit (neutral tokens, function-named components, interruptible transitions and springs, screen stack with gamepad focus, localisation keys, automated audits), the Input Action System input map (reserved ui.back/ui.confirm/cinematic.skip, rebinding, device glyphs) and data-driven cutscenes (cinematics/1, letterbox, skip). Use for "UI looks cheap", broken or overlapping panels, HUD/menu/shop/settings/inventory/dialogue screens, loading and teleport covers, mobile or controller usability, text that does not fit, keybind prompts, cutscenes and camera shots.
---

# UI / UX pass (UIKit, InputMap, Cinematics)

## Purpose
Every screen works on every target input and size, with one source of truth per screen state, before any visual polish; motion is smooth, interruptible and respects reduced motion; cutscenes are data that sample the same at any frame rate. Build with `packages/UIKit`, `GameKit/InputMap` and `packages/Cinematics`, never one-off Instance scripts. **Gate:** production skill. Designing a game's screens, look or story acts on a game repository only after an explicit game-build request (AGENTS.md, Boundary); in this factory repo work only on neutral kit components, the gallery and fixtures.

## Triggers
"UI looks cheap", broken or overlapping panels, HUD, menus, shop, settings, inventory, dialogue, leaderboard, loading or teleport screens; mobile, console or keyboard navigation problems; focus traps; text that does not fit after localisation; keybind prompts and rebinding; camera shots, cutscenes, letterboxing and skip.

## Inputs
The screens and their states (open, closed, loading, empty, error, disabled), target devices and inputs, the game's token overrides (hue slots, fonts), localisation tables, the input actions it needs, and for cutscenes the shot list as cinematics/1 data.

## Required context
- `docs/uikit.md`: styling decision, tokens, components, transitions, navigation, input map, localisation, audit rules, gallery, loading and teleports, cinematics, verification.
- `packages/UIKit/UIKit.luau` (facade and typical start) and the header of each component you use (props, tree names).
- `packages/GameKit/InputMap.luau` (contexts, reserved actions, bindings), `docs/runtime-kits.md` (Env, tiers, probes, settings/1, catalog/1).
- `references/cinematics.md` for cutscene authoring; `references/legacy-*.md` are the first-pass checklists (title/lobby, mobile/controller, polish), still useful as review prompts.
- Specs as examples: `tests/uikit_components.spec.luau`, `tests/uikit_nav.spec.luau`, `tests/uikit_audit.spec.luau`, `tests/gamekit_inputmap.spec.luau`, `tests/cinematics.spec.luau`.

## Tools
- Lune: `lune run tests/run.luau uikit`, `... gamekit_inputmap`, `... cinematics`; FakeEnv, `tests/fakes/FakeUIEvents.luau` and `Audit.staticMeasure` for headless checks.
- Studio MCP (coordinator only): `execute_luau` to mount the gallery or run `AuditRoblox.audit`, `screen_capture` with the device emulator, `user_keyboard_input`/`user_mouse_input` for navigation traces, `get_console_output` for `UIKIT_AUDIT` and `ENGINE_CHECK` lines.
- Gallery fixture: `fixtures/kits/client/ui_Gallery.client.luau` with Workspace attribute `SETUP_ONLY_KitFixture = "ui-gallery"` on the unpublished kits diagnostic place (`fixtures/kits.project.json`).
- visual-qa for before/after captures.

## Procedure
1. **Inventory.** List screens and states; find dead buttons, overlapping panels, stale state, duplicated logic and literal strings.
2. **Tokens.** Start from `Tokens.resolve(theme, overrides)`; set only the hue slots and fonts a game decides; run `Tokens.validate` (every text-on-surface pair meets WCAG 4.5:1, UI parts 3:1). Never set colours or the legacy `Font` enum per Instance; components read tokens and use FontFace.
3. **Build screens from components.** `local ctx = UIKit.context({ env, class = Breakpoints.classify(...), theme, motion = { reducedMotion }, text = Localize.new(...):fn(), inputMap })`, `ctx.runner:attach(env)`, then `Component.mount(props, ctx, parent)`. Props take localisation keys. Put each layer in `Build.screenGui(ctx, name, layer)` (CoreUISafeInsets by default). Shops render catalog/1 products with ShopCard and call the game's own guarded purchase flow from `onSelect`; settings use SettingsPanel bound to settings/1.
4. **Navigation and input.** One `Nav` stack per client: `push`, `modal`, `replace`, `back()` wired to the `ui.back` InputAction; let Nav restore focus. Bind actions through `InputMapRoblox.build(map, env, { parent })`; on-screen touch actions are `TouchActionButton`s (their `InputMapKey` binds them as IAS UIButtons); prompts are `KeybindPrompt` (glyph per device). Never read `UserInputService.InputBegan` for game actions.
5. **Motion.** Use `Build.play` with Transitions presets (`fade`, `slide`, `scalePop`, `wipe`, `iris`; `sequence`, `parallel`, `stagger`) and token durations, eases and springs. Re-triggering a transition interrupts from the current value; reduced motion collapses to short fades automatically.
6. **Cutscenes.** Author cinematics/1 data (references/cinematics.md), `Cinematics.validate` it, check timing with `Cinematics.sample`/`bake`, and play with `CinematicsRoblox.play(cin, { camera, env, skipAction, skipContext, parent, onEvent })`. Skip input is the `cinematic.skip` action; subtitles are keys.
7. **Audit.** In Lune: `Audit.fromInstances(root, { measure = Audit.staticMeasure(class.viewport, class.safe) })` and `Audit.run` with the layout-free rules (`contrast`, `text_size`, `legacy_font`, `text_scaled`, `text_fit`, `canvas_group_size`). In Studio: `AuditRoblox.audit(root, env)` for the layout rules (`touch_target`, `safe_area`, `overlap`, `gamepad_reachable`) and the pseudo-localisation text-fit pass. Fix every error; justify every remaining warning.
8. **Check devices.** Phone portrait and landscape, tablet, desktop and console in the device emulator (the gallery's Phone/Desktop/Console and Pseudo-loc switches cover the components); walk each flow with touch, mouse and keyboard, and gamepad.
9. **Capture** before/after per device size (visual-qa) and record what was not checked on physical devices.

## Outputs
Screen/state inventory with issues; the fixes as UIKit, InputMap and Cinematics code and data; a Lune spec for new logic (at least one failure case); `ui-audit/1` reports (Lune and, when run, Studio) with zero errors; before/after captures per device size; probe output when engine behaviour was claimed.

## Acceptance
- `lune run tests/run.luau` green, including any new component or screen spec.
- Audit reports have no errors; contrast, text size, legacy fonts and text fit are clean in Lune; touch target, safe area, overlap and gamepad reachability are clean in Studio (or listed as not yet checked).
- Every primary flow completes with touch, mouse and keyboard, and gamepad; back closes modals; focus returns where it was.
- Reduced motion and pseudo-localisation leave every screen usable.
- Cutscenes validate, their events fire once, skip works through the input action and the camera is restored.
- Engine facts are claimed only from probe output (`ui_ease_parity`, `ui_nav_keyboard`, `ui_gallery_audit`, `ui_style_sheet`, `inputmap_contexts`, `cin_play_sample`); otherwise they stay PENDING.

## Failure
- Emulator-only evidence: record physical-device checks as still needed.
- A visual fix breaks a state: revert to the structural fix first, then restyle.
- An audit rule looks wrong: add a seeded case to `tests/uikit_audit.spec.luau` showing it, then fix the rule; never disable it to get green.
- StyleSheet rules do not apply in Studio: keep the Style resolver values (they are the source of truth) and report the probe result.
- A rebind leaves an action unusable: InputMap refuses it; read the returned problems instead of editing the map by hand.
- A cutscene looks different at another frame rate: it should not; check that nothing reads wall-clock time and that events use `eventsBetween`.

## Related
visual-qa, roblox-studio-testing, roblox-luau-testing, luau-quality, roblox-release-pass, roblox-level-design-review.
