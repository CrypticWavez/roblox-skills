# UIKit

Neutral UI kit: tokens, styles, breakpoints, state, transitions and easing, navigation and focus, localisation, audits and 27 function-named components, with a gallery. Plain Instances, no framework; pure plans run in Lune and `*Roblox.luau` adapters touch the engine. No production UI is designed here: the palette is greyscale with placeholder hue slots and every string is a localisation key.

Guide: [docs/uikit.md](../../docs/uikit.md). Owner: G4. Contract and tiers: [docs/runtime-kits.md](../../docs/runtime-kits.md).

| Module | Tier | What |
|---|---|---|
| `UIKit.luau` | T1 | facade: one require for the kit |
| `Tokens`, `Style` | T0/T1 | design tokens; resolution to Instance properties (FontFace only) and a StyleSheet plan |
| `StyleRoblox` | T3 | native StyleSheet from the plan (probe `ui_style_sheet`) |
| `Breakpoints`, `State` | T0 | device classes and safe area; small reactive state |
| `Ease`, `Transitions` | T0/T1 | EasingStyle mirror and springs (probe `ui_ease_parity`); interruptible transition plans and runner |
| `Nav` | T1 | screen stack, ui.back, focus restore (probe `ui_nav_keyboard`) |
| `Localize` | T0 | keys, fallback, plurals, pseudo-locale |
| `Audit`, `AuditRoblox` | T1/T3 | rule-based UI audits; live audit with pseudo-loc and legacy fonts (probe `ui_gallery_audit`) |
| `Build` | T1 | component contract, context, Instance factory |
| `Components/*` | T1 | Button … TouchActionButton (see docs/uikit.md) |
| `Gallery/Stories`, `Gallery/Browser` | T1 | one story per component (UI Labs `(target) -> cleanup`); the story browser |

Specs: `lune run tests/run.luau uikit`. Gallery fixture: `fixtures/kits/client/ui_Gallery.client.luau` (Workspace attribute `SETUP_ONLY_KitFixture = "ui-gallery"` on the unpublished kits diagnostic place).
