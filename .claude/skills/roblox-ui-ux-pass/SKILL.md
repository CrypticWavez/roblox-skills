---
name: roblox-ui-ux-pass
description: Audit and polish Roblox UI and front-end flow - HUD, menus, title/lobby, inventory/shop/settings, transitions, readability, safe areas, touch and controller navigation, localization fit - using NativeUI tooling and device-emulated captures. Use for "UI looks cheap", broken panels, title screen/lobby polish, mobile or controller usability.
---

# UI / UX pass

## Purpose
Every screen works on every target input and size, with one source of truth per screen state, before any visual polish. **Gate:** production skill. It acts on a game repository only after an explicit game-build request (AGENTS.md, Boundary); in this factory repo run it only against fixtures.

## Triggers
"UI looks cheap", broken or overlapping panels, title screen or lobby polish, mobile or controller usability, text that does not fit after localization.

## Inputs
The screens and their states, target devices and input types, the game's style profile, localization targets.

## Required context
`packages/Runtime/NativeUI.luau`, `packages/Creator/UI.luau` (inherited UI helpers: string/item/settings validation, localization, shop display), `packages/Runtime/Motion.luau` (transitions, reduced motion); `references/legacy-ui-polish.md` (its original top was truncated), `references/legacy-title-lobby.md`, `references/legacy-mobile-controller.md`.

## Tools
Studio device emulator; Studio MCP `screen_capture`, `user_mouse_input`, `user_keyboard_input`, `execute_luau`, `get_console_output`; visual-qa for before/after captures.

## Procedure
1. Inventory screens and states (open, closed, loading, empty, error); find dead buttons, overlapping panels, stale state and duplicated logic.
2. Check layout at phone portrait/landscape, tablet, desktop and console in the device emulator: GuiInset and notch safe areas, touch targets of about 44 px or more, text scaling.
3. Input: every action reachable by touch, mouse/keyboard and gamepad; `GuiService.SelectedObject` focus paths; no focus traps.
4. Fix structure first (one source of truth per screen state), then visuals (hierarchy, spacing, contrast, motion via `Motion.transition`).
5. Capture before/after per device size (visual-qa).

## Outputs
Screen/state inventory with issues, the fixes, and before/after captures per device size.

## Acceptance
All primary flows complete with each input type; captures at every target size show no clipping or overlap.

## Failure
- Emulator-only evidence: record physical-device checks as still needed.
- A visual fix breaks a state: revert to the structural fix first, then restyle.

## Related
visual-qa, roblox-release-pass, roblox-studio-testing.
