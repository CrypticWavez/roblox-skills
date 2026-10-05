---
name: roblox-ui-ux-pass
description: Audit and polish Roblox UI and front-end flow - HUD, menus, title/lobby, inventory/shop/settings, transitions, readability, safe areas, touch and controller navigation, localization fit - using NativeUI tooling and device-emulated captures. Use for "UI looks cheap", broken panels, title screen/lobby polish, mobile or controller usability.
---

# UI / UX pass

**Gate.** Production skill: it acts on a game repository only after an explicit game-build request (see `FUTURE_GAME_BUILD_PROMPT.md` in the workbench). In this factory repo, run it only against fixtures. Never publish, spend Robux, create live products or touch production data without fresh approval.

**Required context.** `packages/Runtime/NativeUI.luau`, `packages/Creator/UI.luau` (inherited UI helpers), the game's style profile.

## Procedure
1. Inventory screens and states (open/closed/loading/empty/error); find dead buttons, overlapping panels, stale state, duplicated logic.
2. Check layout at phone portrait/landscape, tablet, desktop and console safe areas in the device emulator; GuiInset and notch safe areas; minimum touch target ~44px; text scaling.
3. Input: every action reachable by touch, mouse/keyboard and gamepad; `GuiService.SelectedObject` focus paths; no focus traps.
4. Fix structure first (one source of truth per screen state), then visuals (hierarchy, spacing, contrast, motion via `Runtime/Motion.luau`).
5. Capture before/after per device (visual-qa).

**Acceptance.** All primary flows complete on each input type; captures at every target size show no clipping/overlap.

**References.** `references/legacy-ui-polish.md` (original was truncated at the top), `legacy-title-lobby.md`, `legacy-mobile-controller.md`.

**Related.** visual-qa, roblox-release-pass.
