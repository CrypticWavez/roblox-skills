# UI, transitions, cutscenes and game feel: research (verified 2026-10-06)

This pass extends [tooling-2026-10-addendum.md](tooling-2026-10-addendum.md), sections A (UI) and B (animation).

That pass recorded React Lua, Fusion, Vide, Flipbook and UI Labs as REVISIT, because "choosing a UI framework is game production". This pass makes the framework choice only for the factory's genre-neutral kits: a UI kit, a cutscene/camera package and a feedback ("juice") module. These are reusable systems for every genre, not game content. A game repository can still put a framework on top later. Nothing here picks a genre, theme, world, characters or economy.

**Method.**
- All sources were fetched on 2026-10-06; the full list is in section 8.
- Roblox docs were read through the `.md` page variants indexed by `https://create.roblox.com/docs/llms.txt`.
- Other sources: DevForum announcement threads, GitHub repo, release and raw README pages, the Wally API (`https://api.wally.run/v1/package-metadata/<scope>/<name>`), the npm registry, luau.org, the lune-org docs and W3C WCAG.
- Pages were read through a summarising fetcher, so short quotes are given where wording matters. When a summary disagreed with a registry or a README, the registry or README wins and the conflict is noted.
- GitHub commit pages are blocked by robots.txt, so "last update" means the last release unless stated otherwise.
- Nothing was installed, bought or signed up for. No Roblox asset ids are recorded.

**Decision rule** (same as the addendum):
- **SELECT**: use in the factory now, as a built-in API, in-repo code or a documented reference.
- **REJECT**: do not adopt.
- **REVISIT**: the facts are recorded, but the decision waits for the stated trigger.

---

## 1. Decisions in brief

1. **UI approach: plain Instances plus native UI Styling** (StyleSheet tokens and themes, state selectors, StyleQuery), wrapped by a small in-repo `UIKit` package. No third-party UI framework in the factory. Reasons are in section 5.
2. **Input: the Input Action System** (full release 2026-06-11), `UserInputService.PreferredInput` and native gamepad selection. New kit code does not use ContextActionService.
3. **Motion: `TweenService`** (`Create`, `GetValue`, `SmoothDamp`) for engine tweens, plus two in-repo pieces so Lune and Studio agree: a closed-form spring, and an easing table that mirrors `Enum.EasingStyle`. No motion-library dependency.
4. **Cutscenes: data-driven camera tracks.** Keys hold eye, target, roll and FOV, plus scalar channels and events. They live in a ModuleScript, are sampled by pure Luau, and play on a Scriptable camera bound at `RenderPriority.Camera`. Camera-rig AnimationClips and VideoFrame are not the default: the first needs an animation upload for live play, the second costs Robux per video.
5. **Feel: an in-repo `Feel` package.** It covers springs, trauma shake, hit-stop, number popups, screen pulses with a flash limiter, haptics, and a cue registry bound to animation markers. It reuses `EffectsPool` and `AudioDirector`.
6. **PC installs for this topic: none required.** Studio already ships everything selected. Storybook plugins (Flipbook, UI Labs) stay REVISIT until the kit has a gallery.

## 2. What the repo has today (judged 2026-10-06)

| Module | Reusable | Problems found | Verdict |
|---|---|---|---|
| `packages/Runtime/NativeUI.luau` | One owned ScreenGui with `ScreenInsets = CoreUISafeInsets`; a `SelectionGroup` panel; focus capture and restore (`previousFocus`); an explicit state machine (loading, ready, empty, error, disabled); a bounded card count; `inspect()` with bounds and `TextFits`; a reduced-motion flag | Fonts are `Enum.Font.Gotham`/`GothamBold`. The Font enum page says Gotham "has been removed. Using it will map to the `Montserrat` font family", and the enum is legacy (use `FontFace`). Layout is hard-coded offsets (16, 68, 142, -218) with a hand-written column calculation instead of flex or StyleQuery. Colours are set per instance, so a theme change needs a manual repaint (`setTheme`). No `PreferredInput`, `PreferredTextSize` or `PreferredTransparency`; no transitions | **Extract** the state machine, focus restore and inspect. **Replace** styling and layout |
| `packages/Creator/UI.luau` | `validateStrings`; `localize` (provider injection, bounded, honest fallback); `validateItems`; `guard` (re-entrancy, once-only cleanup); an audit walk with scroll clipping. Nine Lune cases in `tests/creator/ui.luau` | `UI.new` is a single ~570-line fixture. It waits on `RunService.RenderStepped`, which the RunService page says "has been superseded by PreRender". Gotham fonts. Slider input is hand-rolled on `UserInputService`. Back is Escape only (no gamepad B). `shopDisplay` couples commerce, which `docs/starter.md` treats as a game decision | **Extract** the validators, guard and audit into UIKit. **Keep** `shopDisplay` out of the kit |
| `packages/Runtime/Motion.luau` | `curve` (smoothstep; reduced motion makes it instant), `transition` (number with a generation counter), `validateMarkers`, `contactDrift` | One easing curve, numbers only, no springs, no parity with `Enum.EasingStyle` | **Keep and extend** (easing table, springs), or supersede with `UIKit.Ease` plus `Feel.Spring` |
| `packages/Creator/Effects.luau` + `EffectsPool.luau` | Pooled Beam/Trail/ParticleEmitter recipes (telegraph, impact, reward), capacity, priority admission, reduced effects, no asset ids | The header excludes camera control and sounds; nothing is wired to animation markers or audio | **Reuse** as the VFX backend of `Feel.Cues` |
| `packages/Creator/AudioDirector.luau` | Event routing with an explicit backend, a bounded trace and music states | none for this purpose | **Reuse** as the sound backend of `Feel.Cues` |
| `packages/Creator/Observation.luau` (camera snapshot near line 140, restore near line 582) | Snapshot and restore of CameraType, CFrame, Focus, FieldOfView and CameraSubject | Diagnostic API only | **Lift** into a `Cinematics` camera lease |
| `packages/SceneKit/Camera.luau` | `frame` (fits bounds into the FOV from a named angle), `captureSet` | Static shots only | **Reuse** for auto-framed cutscene keys |
| `packages/SceneKit/Lighting.luau` | Lighting and Atmosphere profiles as data | No post-processing effects | Persistent grading (a ColorCorrection, Bloom or ColorGrading baseline) belongs here. Transient pulses belong in `Feel.Screen` |
| `.agents/skills/roblox-ui-ux-pass` | A sound procedure: inventory the states, check device sizes and input reachability, fix structure before visuals | Names no kit; does not mention StyleQuery, IAS or the accessibility settings. Its references are legacy checklists. Nothing covers cutscenes or feel | **Update** once UIKit exists, and add a cinematics/feel skill |

Net: the inherited UI is a sound diagnostic base (states, focus, bounded inputs, audits). It is not a production UI kit, and it has no cutscene or feel layer.

## 3. Engine facts (Roblox, built into Studio; free; Roblox terms; tracks Studio)

Every row was fetched 2026-10-06. "Docs" means `https://create.roblox.com/docs/en-us/<path>.md`.

### 3a. Layout, appearance and styling

| Feature | Fact | Source |
|---|---|---|
| Flex layout | `UIListLayout` has `Wraps`, `HorizontalFlex`/`VerticalFlex` (Fill, SpaceAround, SpaceBetween, SpaceEvenly) and `ItemLineAlignment`. `UIFlexItem` has `FlexMode` (Grow, Shrink, Fill, Custom) with `GrowRatio`/`ShrinkRatio` (Custom only) and a per-item `ItemLineAlignment`. No beta note | docs `ui/list-flex-layouts`, `reference/engine/classes/UIFlexItem` |
| UIStroke | Adds `StrokeSizingMode` (pixels or scaled), `BorderOffset`, `BorderStrokePosition` (Center, Inner, Outer) and `ZIndex`. The docs warn: "Avoid tweening the `Thickness` property of a `UIStroke` instance applied to **text** objects" | docs `reference/engine/classes/UIStroke`, `ui/appearance-modifiers` |
| UICorner per-corner + UIShadow | Full release 2026-05-14. Adds `TopLeftRadius`, `TopRightRadius`, `BottomLeftRadius` and `BottomRightRadius` (`CornerRadius` aliases all four). `UIShadow` has `BlurRadius` (up to 1000), `Color`, `Transparency`, `Offset`, `Spread` and `ZIndex` (negative only). "UIShadows are consistently faster than 9-sliced ImageLabels"; "don't draw more than 100 UIShadows on-screen". It shadows the element's rectangle, not text glyphs, and does not work with Path2D or UIGradient | https://devforum.roblox.com/t/full-release-new-ui-capabilities-shadows-individual-corners/4636263 ; docs `reference/engine/classes/UIShadow` |
| UIGradient | `Type` (Linear, Radial, Conical), `Scale`, `TileMode`, `Offset` and `Rotation`. Offset and rotation animate for shimmer. Radial suits a vignette and conical a hold or progress ring, with no image asset | docs `reference/engine/classes/UIGradient`, `ui/appearance-modifiers` |
| CanvasGroup | `GroupTransparency`/`GroupColor3` act on the flattened group. It uses extra texture memory limited by the client QualityLevel; past the cap it "renders as a blank texture". "Recommended to use CanvasGroup with static sizes". Flattening needs `ZIndexBehavior = Sibling` | docs `reference/engine/classes/CanvasGroup`, `ui/animation` |
| Size modifiers | `UIScale` (for zoom and hover pops); `AutomaticSize` makes `Size` the minimum; `UISizeConstraint` "override[s] layout structures"; `UITextSizeConstraint`: "Do not use MinTextSize property values lower than 9"; `UIAspectRatioConstraint` | docs `ui/size-modifiers` |
| Path2D | A stroked 2D cubic spline under any GuiObject. Stroke only, no fill; at most 100 control points; `GetPositionOnCurveArcLength`, `GetLength`; no beta note. Usable for vector icons (close, back, chevron, check) with no image upload | docs `reference/engine/classes/Path2D` |
| Fonts | The `Font` enum is legacy. `Font.fromName` and built-in families at `rbxasset://fonts/families/<Name>.json` (42 listed) need no upload. Gotham variants map to Montserrat. BuilderSans entries reference a "Builder Font License" | docs `reference/engine/datatypes/Font`, `reference/engine/enums/Font` |
| UI Styling | `StyleSheet`, `StyleRule`, `StyleLink` and `StyleDerive`. Selectors cover class, tag (`.Tag`), name, instance modifiers (`::UICorner`), GuiState states and queries (`@Name`). Tokens are StyleSheet attributes referenced as `$Token`. Themes are swappable token sets. Fully authorable from Luau (`SetAttribute`, `SetProperties`, `SetProperty`). Full release **2026-01-20**. Animations and transitions are not supported; Roblox is "exploring" them | docs `ui/styling` ; https://devforum.roblox.com/t/full-release-ui-styling-is-officially-released/4275082 |
| GuiState | Idle, Hover, Press, NonInteractable; set by the engine, not scripts | docs `reference/engine/enums/GuiState` |
| StyleQuery | Conditions: `MinSize`, `MaxSize`, `AspectRatioRange` (parent container), `PreferredInput`, `PreferredTextSize`, `ViewportDisplaySize` and `ReducedMotionEnabled`. When true, the matching `@Name` rules apply. Full release update 2026-05-11. Caveats: styling Size inside a size query "may result in flickering", and "be mindful of having too many StyleQueries under one instance" | docs `reference/engine/classes/StyleQuery` ; https://devforum.roblox.com/t/full-release-stylequery-more-styling-features/4566519 |
| Styling coverage | Styleable classes include GuiObject, TextLabel, TextButton, ImageLabel, ImageButton, TextBox, ScrollingFrame, ViewportFrame, Path2D, CanvasGroup, InputActionLabel, UICorner, UIGradient, UIPadding, UIShadow, UIStroke, the list/grid/page layouts, UIFlexItem and the size constraints. "Additional support may be added over time" | docs `ui/styling/compatibility` |

### 3b. Safe areas, input and navigation

| Feature | Fact | Source |
|---|---|---|
| ScreenGui insets | `ScreenInsets` values: `None` ("non-interactive content" only), `DeviceSafeInsets`, `CoreUISafeInsets` (the default, "recommended for interactive UI") and `TopbarSafeInsets` ("dynamic space within the top bar"). `SafeAreaCompatibility` is FullscreenExtension or Ignore. `ClipToDeviceSafeArea` defaults to true. `IgnoreGuiInset` is a legacy alias that switches to DeviceSafeInsets | docs `reference/engine/classes/ScreenGui`, `reference/engine/enums/ScreenInsets` |
| GuiService | `SelectedObject`, `AutoSelectGuiEnabled`, `GuiNavigationEnabled`, `TopbarInset` (Rect), `GetGuiInset`, `GetInsetArea(screenInsets)`, `ViewportDisplaySize`, `Select(parent)`, `AddSelectionParent`, `IsTenFootInterface`, `MenuOpened`/`MenuClosed`. Accessibility properties are listed in 3c | docs `reference/engine/classes/GuiService` |
| Selection | GuiBase2d has `SelectionGroup`, `SelectionBehaviorUp/Down/Left/Right` (`Stop` keeps selection inside the group) and `SelectionChanged`, which bubbles. GuiObject has `Selectable`, `SelectionOrder`, `SelectionImageObject`, `NextSelectionUp/Down/Left/Right` and `Interactable` (false sets GuiState to NonInteractable). `TweenPosition`/`TweenSize` are deprecated in favour of TweenService | docs `reference/engine/classes/GuiBase2d`, `reference/engine/classes/GuiObject` |
| Input Action System | **Full release 2026-06-11.** `InputContext` (`Enabled`, `Priority`, `Sink`; "Nested InputContext instances will have no effect"). `InputAction` (`Type` Bool, Direction1D, Direction2D, Direction3D or ViewportPosition; `PreferredBinding`; `Pressed`, `Released`, `StateChanged`). `InputBinding` (`KeyCode`, `UIButton`, `UIModifier`, `PrimaryModifier`/`SecondaryModifier`, directional keys, `Scale`, `ResponseCurve`, `PressedThreshold` 0.5, `ReleasedThreshold` 0.2, `DisplayName`, `DisplayImage`). `InputActionLabel` and the Input Action Manager are **beta**. Known gap: four UI buttons cannot be mapped to one Direction2D. ContextActionService has no deprecation notice. Default PlayerScripts move to IAS: opt-in now, default-on early 2027, old scripts removed mid 2027 | docs `input/input-action-system`, `reference/engine/classes/InputBinding`, `reference/engine/classes/InputContext` ; https://devforum.roblox.com/t/full-release-input-action-system-ias-newly-converted-player-scripts/4678416 |
| Input type | `UserInputService.PreferredInput` is Touch, Gamepad or KeyboardAndMouse; listen with `GetPropertyChangedSignal("PreferredInput")`. The docs recommend it over the `*Enabled` flags for UI adaptation. `GetImageForKeyCode` returns gamepad glyphs ("limited to Xbox, PlayStation, and Windows"); `GetStringForKeyCode` respects keyboard layout | docs `reference/engine/classes/UserInputService`, `input/gamepad` |

### 3c. Text, accessibility and localization

| Feature | Fact | Source |
|---|---|---|
| Text sizing | `TextScaled`: the docs recommend `AutomaticSize` instead and advise against combining the two. `TextFits` is read-only. `MaxVisibleGraphemes` gives typewriter reveals. `ContentText` strips rich-text tags | docs `reference/engine/classes/TextLabel` |
| Player text size | `GuiService.PreferredTextSize`: Medium, Large, Larger, Largest. `UITextSizeConstraint` bounds apply regardless of the setting, and "`TextScaled` elements bypass the preference entirely" | docs `production/publishing/accessibility` |
| Reduced motion | Respect `GuiService.ReducedMotionEnabled`: set `TweenInfo.Time` to 0, or replace motion tweens with fades | same |
| Background transparency | `GuiService.PreferredTransparency` (0 to 1, default 1): multiply `BackgroundTransparency` by it | same |
| Sound and colour | Do not convey critical events only through sound; provide separate volume groups; do not rely on colour alone ("over 5% of people ... have some form of color blindness") | same |
| Localization | `LocalizationService:GetTranslatorForPlayerAsync` ("may occasionally fail", so pcall it), `GetTranslatorForLocaleAsync`, `Translator:FormatByKey` (parameter tables), `Translator:Translate`, and the translator's `LocaleId` change signal. `AutoLocalize` and `RootLocalizationTable` are on GuiBase2d | docs `production/localization/localize-with-scripting`, `reference/engine/classes/GuiBase2d` |
| Photosensitivity (external) | WCAG 2.3.1 (Level A): nothing "flashes more than three times in any one second period", unless below the general and red flash thresholds | https://www.w3.org/WAI/WCAG22/Understanding/three-flashes-or-below-threshold.html |

### 3d. Motion, timing, camera and animation

| Feature | Fact | Source |
|---|---|---|
| TweenService | `Create`, `GetValue(alpha, style, direction)`, and `SmoothDamp(current, target, velocity, smoothTime, maxSpeed?, dt?)`, which uses "a critically damped spring" and returns `(value, velocity)`. Tweenable types: number, boolean, CFrame, Rect, Color3, UDim, UDim2, Vector2, Vector2int16, Vector3, EnumItem. Two tweens on one property: the newer "overwrites" the older. UI sequences chain on `Completed`; group fades tween `CanvasGroup.GroupTransparency` | docs `reference/engine/classes/TweenService`, `ui/animation` |
| EasingStyle | 11 styles: Linear, Sine, Back, Quad, Quart, Quint, Bounce, Elastic, Exponential, Circular, Cubic | docs `reference/engine/enums/EasingStyle` |
| RunService | `BindToRenderStep(name, priority, fn)` and `UnbindFromRenderStep`. `RenderPriority`: Input 100, Camera 200. `PreRender` supersedes `RenderStepped`; `PreSimulation` supersedes `Stepped`; `Heartbeat` carries no deprecation text | docs `reference/engine/classes/RunService` |
| Camera | With `CameraType.Scriptable` the default scripts stop updating the camera. `Focus` is not updated automatically, so update it every frame via `BindToRenderStep` at `RenderPriority.Camera`. `FieldOfView` is 1 to 120 (default 70). `Interpolate` is deprecated ("use TweenService"); `CoordinateFrame` is superseded by `CFrame`. `ViewportSize` excludes notches. `WorldToViewportPoint` ignores the GUI inset; `ScreenPointToRay` accounts for it. `VRTiltAndRollEnabled` is off by default (motion sickness) | docs `reference/engine/classes/Camera`, `workspace/camera` |
| Animation markers | Animation Editor event markers carry an optional parameter string; read them with `AnimationTrack:GetMarkerReachedSignal(name)`. `AdjustSpeed(0)` pauses a track (usable for hit-stop); `TimePosition` seeks. `KeyframeReached` and `DidLoop` exist | docs `animation/events`, `reference/engine/classes/AnimationTrack` |
| Curve animations | `CurveAnimation` is an AnimationClip of per-channel curves in Folders that mirror the rig (`Vector3Curve` "Position", `RotationCurve`/`EulerRotationCurve` "Rotation", `FloatCurve`). It animates Motor6Ds or Bones. `MarkerCurve` stores chronological string markers (up to 64 characters) with `InsertMarkerAtTime` and `GetMarkers` | docs `reference/engine/classes/CurveAnimation`, `reference/engine/classes/MarkerCurve` |
| Animation assets | `KeyframeSequenceProvider:RegisterKeyframeSequence` and `RegisterActiveKeyframeSequence` return temporary ids that "cannot be used outside of Studio". Live games must upload. Non-humanoid rigs play through an `AnimationController` with a child `Animator` | docs `reference/engine/classes/KeyframeSequenceProvider`, `animation/using` |
| Camera authoring docs | The `llms.txt` index lists only `workspace/camera` and `workspace/camera/free-camera` for cameras. No official camera-animation or cutscene authoring page was found | `https://create.roblox.com/docs/llms.txt` |

### 3e. Screen effects, haptics, popups and video

| Feature | Fact | Source |
|---|---|---|
| Post-processing | `BloomEffect`, `BlurEffect`, `ColorCorrectionEffect` (`Brightness`, `Contrast`, `Saturation`, `TintColor`), `DepthOfFieldEffect`, `SunRaysEffect` and `ColorGradingEffect` (`TonemapperPreset`, Default or Retro). The guide says the parent is Lighting or Camera, and some effects need a higher quality level to show in Studio | docs `environment/post-processing-effects` |
| BlurEffect | Blurs the 3D world only, not UI. Renders differently on low-end devices | docs `reference/engine/classes/BlurEffect` |
| ColorGradingEffect | The class page says it must be parented to Lighting (elsewhere is ignored) and "only the most recently parented instance to Lighting will be applied". This conflicts with the guide's "Lighting or Camera" | docs `reference/engine/classes/ColorGradingEffect` |
| HapticEffect | `Type` (including `GameplayExplosion`, `GameplayCollision`, `UIClick` and `Custom`), `Looped`, `Radius`, `Position`; `Play`, `Stop`, `SetWaveformKeys` (FloatCurveKeys: time in ms, intensity 0 to 1); an `Ended` event. Must be parented before playing. Platforms: haptic-capable Android and iOS phones, PlayStation and Xbox gamepads, Quest Touch | docs `reference/engine/classes/HapticEffect`, `input/gamepad` |
| BillboardGui (popups) | The scale part of `Size` is in studs. Also `AlwaysOnTop`, `MaxDistance` (0 or inf means no limit), `StudsOffset`/`StudsOffsetWorldSpace` and `LightInfluence`. `DistanceLowerLimit`/`DistanceUpperLimit` are deprecated | docs `reference/engine/classes/BillboardGui` |
| VideoFrame | Uploads need a 13+ ID-verified user and "Each video upload costs 2,000 Robux"; at most 20 a day and 5 minutes each; "A maximum of two videos can play simultaneously" | docs `ui/video-frames` |

## 4. Third-party candidates

### 4a. UI frameworks and UI libraries

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Plain Instances + native UI Styling (with StyleQuery) | https://create.roblox.com/docs/ui/styling | Roblox | ships with Studio | Styling full release 2026-01-20; StyleQuery 2026-05-11; UIShadow 2026-05-14 | active (Roblox) | Roblox terms | free |
| Fusion | https://github.com/dphfox/Fusion ; Wally `elttob/fusion` | dphfox | 0.3 (tag `v0.3-beta`, marked pre-release; Wally 0.3.0) | 2024-08-30 (release page); "29 commits to main since this release" | No release in about 25 months; 797 stars | MIT (README, Wally) | free |
| React Lua | https://github.com/jsdotlua/react-lua ; npm `@jsdotlua/react`, Wally `jsdotlua/react` | jsdotlua (community fork; Roblox's `roblox/react-lua` is "a read-only mirror") | 17.2.1 | 2024-12-04 (npm) | No release in about 22 months; 570 stars; not archived | MIT (npm, Wally; 17.0.1 to 17.0.4 were "MIT + Apache 2.0") | free |
| Vide | https://github.com/centau/vide ; Wally `centau/vide` | centau | 0.4.1 (pre-release) | 2026-07-11 (release page) | Active, pre-1.0; 320 stars; Wally and pesde manifests | MIT (Wally) | free |
| Roact | https://github.com/Roblox/roact | Roblox | 1.4.4 | 2022-08-16 | **Archived 2023-12-13**: "deprecated and no longer maintained" | Apache-2.0 | free |
| Iris (debug UI) | https://github.com/SirMallard/Iris ; Wally `sirmallard/iris` | SirMallard, Michael-48 | 2.5.1 | 2025-03-27 (release page) | No release in about 18 months; 354 stars | MIT | free |
| TopbarPlus | https://github.com/1ForeverHD/TopbarPlus ; Wally `1foreverhd/topbarplus` | 1ForeverHD | 3.4.0 | 2024-09-17 (release page) | No release in about 2 years; 236 stars, 15 open PRs | MPL-2.0 (Wally) | free |

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| Plain Instances + Styling | Tokens, themes, Hover/Press/NonInteractable states and responsive, input, text-size and reduced-motion queries, all as Instances. No transitions yet | none beyond Studio | NativeUI, Creator/UI | Agents write plain engine API. `inspect_instance`/`execute_luau` read the real tree, StyleSheets included. Pure plans are Lune-testable | Zero dependencies; packages copy byte for byte into game repos (`tools/new_project.py`); theming and device adaptation come from the engine | **SELECT** (section 5) |
| Fusion | Reactive scopes, computeds, declarative instances | third-party runtime code; Wally supply chain | Vide, React Lua, native styling | runtime needs Roblox; no Lune evidence | concise reactive UI | **REVISIT** in a game repo that wants reactive state. A beta with no release in 25 months is a weak factory base |
| React Lua | React 17 components and hooks | as Fusion | as Fusion | Jest Lua runs in Roblox only (main research section 3) | large-team UI architecture | **REVISIT** in a game repo |
| Vide | Solid-style reactive UI, fully typecheckable | as Fusion | as Fusion | as Fusion | small and active | **REVISIT**; pre-1.0 |
| Roact | legacy React-like library | unmaintained code | React Lua | none | none | **REJECT**: archived |
| Iris | Immediate-mode (Dear ImGui style) "debug, visualisation and content-creation tool UI" | dev-only if kept out of shipped builds | in-repo tuning panels built on UIKit | Lua API | quick live-tuning knobs | **REVISIT** in a game repo that needs a tuning overlay; stale releases |
| TopbarPlus | Topbar icons, dropdowns and themes; 3.2.5+ handles `TopbarInset` | third-party runtime | native `ScreenInsets = TopbarSafeInsets` + `GuiService.TopbarInset` | Lua API | prebuilt topbar menus | **REJECT**: native insets now cover placement; no release in two years |

### 4b. Motion and camera-shake libraries

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| spr | https://github.com/Fraktality/spr | Fraktality | no tagged release seen; "single-module library" pasted into a ModuleScript | unknown (commit pages blocked) | 144 stars | MIT | free |
| Ripple | https://github.com/littensy/ripple ; npm `@rbxts/ripple`, Wally `littensy/ripple` | littensy | 0.10.2 | 2026-02-26 (npm) | active; 128 stars | MIT (README, npm) | free |
| Flipper | https://github.com/Reselim/flipper ; npm `@rbxts/flipper` | Reselim | 2.0.1 | 2021-08-28 (npm) | stale (npm modified 2022-04-06) | MIT | free |
| RbxCameraShaker | https://github.com/Sleitnick/RbxCameraShaker | Sleitnick | none shown; distributed as a Roblox library model | unknown; 9 commits | 123 stars | MIT | free |

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| spr | `spr.target(obj, dampingRatio, undampedFrequency, props)`; types from boolean to Vector3, including ColorSequence. "Damping ratio < 1 overshoots"; `= 1` "without overshooting" | paste-install, so no registry pinning | `TweenService:SmoothDamp` (critically damped only); in-repo spring | Lua API | proven parameterisation | **REJECT** as a dependency. Mirror its parameters (damping ratio, frequency) in an in-repo closed-form spring; copy no code |
| Ripple | Springs, tweens and "motion" over numbers, vectors, Color3, UDim2, CFrame, Rect and maps; the README shows plain Luau (`createSpring(0, { tension = 170, friction = 26, start = true })`). (The GitHub page summary said "roblox-ts only"; the README and Wally "shared" realm say otherwise) | Wally supply chain | in-repo spring | Lua API | maintained if a game wants a library | **REVISIT** in a game repo |
| Flipper | motors and springs | unmaintained | Ripple, in-repo | Lua API | none | **REJECT**: last release 2021 |
| RbxCameraShaker | Perlin-noise shake presets (`ShakeOnce`, `StartShake`) | library-model distribution | in-repo trauma shake | Lua API | presets | **REJECT**: no registry release. A seeded trauma shake is ~60 lines and testable in Lune |

### 4c. Storybooks and agent skills (updates to the addendum)

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Flipbook | https://github.com/flipbook-labs/flipbook | flipbook-labs | v2.5.0 | 2025-04-10 (release page) | PR #639 ("Connect Flipbook to agent controls"; #646 was seen only in search results) adds agent controls; merge status not confirmed | MIT | free |
| UI Labs | https://github.com/PepeElToro41/ui-labs | PepeElToro41 | v1.6.x | conflicting years on the release page (UNVERIFIED) | unknown | GPL-3.0 (addendum) | free |
| roblox-agent-skills | https://github.com/afrxo/roblox-agent-skills | afrxo | none | unknown; 6 commits | 1 star | MIT | free |

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| Flipbook | Storybook plugin. Storyteller renders "React, Roact, Fusion, Iris, and any generic Roblox Gui". v2.4.0 added "anonymized usage metrics" with an opt-out | Studio plugin with full place access; telemetry | UIKit gallery via `execute_luau` | GUI only (agent controls not released) | component review without Play | **REVISIT** once `UIKit/Gallery` has stories. Confirm its generic-story signature first |
| UI Labs | Function stories `function story(target: Frame) ... return function() --[[cleanup]] end end`; also React/Roact, Fusion, Vide, Iris and Generic stories | as Flipbook | as Flipbook | GUI only | same | **REVISIT**. The kit gallery adopts this `(target) -> cleanup` signature so either plugin can load it |
| roblox-agent-skills | Four Claude skills; `roblox-ui` assumes Fusion 0.3 and recommends `IgnoreGuiInset = true` (now a legacy alias of `ScreenInsets`) | third-party prompt content | repo skills `roblox-ui-ux-pass` and others | Claude plugin | none over the repo's own skills | **REJECT**: tiny, Fusion-specific and partly outdated |

### 4d. Cutscene authoring routes

| Route | Facts | Decision |
|---|---|---|
| Moon Animator 2 | Already researched: paid (USD 19.99 sale price seen 2026-10-05), see `knowledge/records/tools-options.json` and addendum section B. A community tutorial (2021-04-22, lead only) describes exporting camera keyframes as a Folder of per-frame CFrame values. Not confirmed from a primary source | **REJECT** (unchanged): paid; the data route below covers the need |
| Camera rig + AnimationController | A community tutorial (2024-02-21, lead only) animates a camera part in Blender, imports the rig with a forum-only exporter, plays it with an AnimationController, and sets `Camera.CFrame = Part.CFrame` each frame. Live play needs an uploaded animation; Studio previews can use `RegisterKeyframeSequence` temporary ids | **REJECT as the factory default** (upload for live play; forum-only exporter, as in the addendum). Allowed in a game repo after explicit upload authorization |
| Data tracks in a ModuleScript (this design) | Camera keys are plain data; sampling is pure Luau; playback uses only `Camera`, `RunService` and `TweenService`; nothing is uploaded | **SELECT** (section 6.2) |
| VideoFrame cutscenes | 2,000 Robux per upload, ID-verified uploader, two videos at once | **REJECT**: spending and upload |

## 5. Why plain Instances and native styling, not a framework

1. **The engine now does what frameworks were used for in theming and adaptation.** Styling (full release 2026-01-20) gives tokens, swappable themes and state styles. StyleQuery (2026-05-11) adds container-size, aspect-ratio, `PreferredInput`, `PreferredTextSize`, `ViewportDisplaySize` and `ReducedMotionEnabled` conditions. None of the framework pages read in this pass advertise equivalent device or accessibility conditions, so a framework-based kit would have to re-derive them from the same engine properties.
2. **The framework candidates have weak maintenance evidence for a factory default.**
   - Fusion's current release is a 2024-08-30 beta.
   - React Lua's last release was 2024-12-04, and the community fork exists because Roblox's repo is read-only.
   - Vide is active but pre-1.0.
   - Roact is archived.
3. **Factory packages ship byte for byte into game repos.** `tools/new_project.py` copies `packages/`, and the repo has no Wally or pesde dependency today. A framework would add the first registry dependency and its supply chain to every game. The addendum notes SEO and exploit "script hub" repos in UI-library search results.
4. **Testability matches the repo's rule that "plans are data".** UIKit computes pure plans (tokens, rules, breakpoints, transitions, focus graphs) that Lune specs check. Studio applies them. Framework runtimes need Roblox to test (Jest Lua), and the in-engine CI route is rejected (D03).
5. **Agents and tools see the real tree.** Claude and Codex write the documented engine API directly. Studio MCP `inspect_instance`, `execute_luau` and `screen_capture` observe the same instances the player sees.
6. **This choice does not lock a game in.** Styling targets tags and classes, so a game repo can add Fusion, Vide or React Lua later, keep the StyleSheet and tokens, and replace only the component layer.

**Known cost.** There is no reactive state library, so UIKit needs a minimal `State` (value, changed signal, derived) and keyed list diffing. Both are small and testable in Lune. Styling has no transitions yet, so motion stays in `UIKit.Transitions`.

## 6. Factory design (input to the implementation plan)

All three packages are genre-neutral, use neutral SETUP_ONLY fixtures, need no asset ids or uploads, and follow the repo patterns:
- Plans are pure data.
- Studio and Lune share code through an `env` option, as `SceneKit.Model` does with `require("@lune/roblox")`.
- Connections are scoped with `Runtime/Lifetime`.

### 6.1 `packages/UIKit`

| Module | API (sketch) | Lune-testable part |
|---|---|---|
| `Tokens` | `Tokens.theme(name) -> tokens`. Colour roles: surface, raised, text, muted, accent, danger, success, focus. Also a spacing scale, radii, TextSize per `PreferredTextSize` step, FontFace family names (built-in families only), motion durations and z-layers. Migrates NativeUI's two neutral themes | every role defined in every theme; contrast ratio per text/background pair (WCAG contrast formula; its text was not fetched in this pass); deterministic hash |
| `Style` | `Style.plan(tokens) -> { tokens, themes, queries, rules = { { selector, properties } } }`; `Style.apply(plan, { env, parent }) -> StyleSheet` | every `$Token` reference resolves; selectors limited to tags (`.Button`), modifiers (`::UICorner`), states (`:Hover`) and queries (`@Compact`); components never set colours directly |
| `Breakpoints` | StyleQuery definitions: `Compact`, `Regular` and `Wide` (MinSize/MaxSize); `Portrait` (AspectRatioRange); `Gamepad` and `Touch` (PreferredInput); `ReducedMotion`; `TextLarge` (PreferredTextSize). `Breakpoints.match(state)` mirrors them in pure Luau. Threshold values are tokens, starting as heuristics, not sourced facts | match table for phone, tablet, desktop and console sizes |
| `Components/*` | Text, Button (variants by tag), IconButton (Path2D icons), Toggle, Slider, ProgressBar, HoldRing (conical UIGradient), Panel, Modal, Tabs, List (keyed diff, virtualised past ~50 rows), Grid (flex wrap), Toast queue, Tooltip, ActionHint, Counter (rolling number), Bar, ScreenFade. ActionHint shows the glyph from `InputAction.PreferredBinding`, using `DisplayName`/`DisplayImage`, or `GetStringForKeyCode`/`GetImageForKeyCode`. Contract: `new(parent, props) -> { root, update(props), destroy(), inspect() }`. Disabled means `Interactable = false`, so the NonInteractable state styles apply; text comes from localization keys | instance-tree structure via `@lune/roblox` if its reflection DB has the classes (UNVERIFIED); list key diff; toast queue bounds |
| `State` | `State.value(x)`, `:get`, `:set`, `:changed(fn)`, `State.derive(sources, fn)`; bounded listeners; no yielding in derive | ordering, glitch-free derive, cleanup |
| `Nav` | Focus stack with `push(modal)`/`pop()`. A modal gets `SelectionGroup = true` and `SelectionBehavior*` = Stop. When `PreferredInput` is Gamepad, call `GuiService:Select(root)`; otherwise clear selection. `pop` restores the previous focus (the NativeUI pattern). A `UI` InputContext holds a Back action bound to Escape, ButtonB and an on-screen button, with `Sink` only while a modal is open | `Nav.check(graph)`: every interactable is reachable through explicit `NextSelection*` links; no trap without a Back route |
| `Transitions` + `Ease` | Presets as data: fade (`CanvasGroup.GroupTransparency`), slide, pop (`UIScale`, spring or Back), wipe (`UIGradient.Offset`), count. `plan(name, { reducedMotion }) -> steps`: under reduced motion, a fade of at most 0.15 s or instant (per the accessibility page). `play(instance, steps, env)` runs on TweenService or `Feel.Spring` on `PreRender` and is interrupt-safe (generation counter, as in `Motion.transition`). `Ease.get("Quad.Out", t)` covers all 11 styles × In/Out/InOut | endpoints exact, monotonic for non-overshoot styles, InOut symmetry, reduced variants |
| `Localize` | Lifts `validateStrings`, `localize` and `guard` from `Creator/UI.luau`. Adds a `Translator:FormatByKey` provider adapter and a pseudo-locale (expanded and accented strings) for text-fit audits | existing 9 cases plus pseudo-locale determinism |
| `Audit` | `Audit.run(root) -> report JSON`. Checks: `TextFits`; text size ≥ 9 (docs); touch targets ≥ 44 px (skill heuristic); overlapping interactables; outside `GetInsetArea(CoreUISafeInsets)`; focus reachability; missing keys; CanvasGroup with dynamic size; UIStroke Thickness tweened on text; more than 100 UIShadows; legacy `Enum.Font` | pure checks on synthetic bounds; the Studio run produces the report |
| `Gallery/*.story.luau` | `function(target: Frame) -> cleanup` (UI Labs function-story signature): every component in every state, neutral strings. Rojo fixture `fixtures/ui.project.json` | the Rojo build in the container |

### 6.2 `packages/Cinematics` (camera and cutscene), data format `cinematics/1`

```lua
return {
	format = "cinematics/1",
	id = "setup_only_orbit", -- ^[a-z][a-z0-9_]*$
	duration = 6, -- seconds, 0 < duration <= 300
	space = "anchor", -- "world" | "anchor" (keys relative to a CFrame given to play())
	camera = {
		interpolation = "catmull_rom", -- "linear" | "catmull_rom" (centripetal) | "hold"
		timing = "keys", -- "keys" | "constant_speed" (arc-length reparameterised)
		keys = { -- eye/target in studs; ease applies to the segment leaving the key
			{ t = 0, eye = { 0, 12, -30 }, target = { 0, 4, 0 }, roll = 0, fov = 70, ease = "Sine.InOut" },
			{ t = 3, eye = { 22, 10, -18 }, target = { 0, 4, 0 }, fov = 60 },
			{ t = 6, eye = { 30, 8, 0 }, target = { 0, 5, 0 }, fov = 50 },
		},
	},
	channels = { -- scalar tracks { t, v, ease? }
		letterbox = { { t = 0, v = 0 }, { t = 0.6, v = 0.12, ease = "Quad.Out" } }, -- bar height, 0..0.25 of screen
		fade = { { t = 5.4, v = 0 }, { t = 6, v = 1 } }, -- black overlay opacity 0..1
		blur = { { t = 0, v = 0 } }, -- BlurEffect.Size
	},
	shakes = { { t = 2.1, preset = "impact", trauma = 0.5 } }, -- Feel.Shake; dropped under reduced motion
	events = {
		{ t = 1, name = "caption", key = "setup_only_caption_1", onSkip = "drop" },
		{ t = 6, name = "done", onSkip = "fire" },
	},
	skip = { allowed = true, after = 0.75, hold = 0.5 }, -- earliest skip time; hold-to-skip seconds
}
```

The camera is stored as eye, target, roll and FOV rather than CFrames or quaternions. That form is readable by people and agents, framed by `SceneKit.Camera.frame`, and sampled with plain vectors (`SceneKit/Vec`) in Lune. It becomes `CFrame.lookAt(eye, target) * CFrame.Angles(0, 0, roll)` only at apply time.

| Function | Behaviour | Test (container) |
|---|---|---|
| `validate(spec) -> {string}` | finite values; per-track times strictly increasing within `[0, duration]`; camera keys at 0 and at `duration`; `fov` within [1, 120] (Camera docs); eye ≠ target; reject near-vertical look without roll; known ease names; channel ranges; `onSkip` present; key and event caps | a negative case per rule |
| `sample(spec, t)` | `{ eye, target, roll, fov, channels }`; exact at keys; C1-continuous with Catmull–Rom; `constant_speed` uses an arc-length table | endpoint exactness; speed variance bound; continuity |
| `eventsBetween(spec, t0, t1, skipping)` | ordered events in `(t0, t1]`; a skip fires only `onSkip = "fire"` events, then the final state | no double-fire across frame boundaries; skip ordering |
| `bake(spec, hz)` / `digest(spec, hz)` | deterministic sample table and hash | golden hash, like `tests/golden/fixture-hashes.json` |
| `play(spec, options) -> handle` (Studio) | camera lease (Observation's snapshot and restore); `BindToRenderStep(name, Enum.RenderPriority.Camera.Value + 1, step)`; `Focus` set every frame; an overlay ScreenGui (`ScreenInsets = None`, high `DisplayOrder`) for letterbox, fade and captions; an owned `BlurEffect`; a skip `InputContext` (high `Priority`, `Sink`) with a Skip action on keyboard, gamepad and a touch `UIButton`; HoldRing progress; `handle:skip()`, `handle:stop()`, `handle.finished`; stop and restore on character removal or `Destroying` | Studio only (section 6.5) |
| `keyFromCamera(camera, t)` (Studio) | turns the current view into a key, so a person or agent can frame shots with `execute_luau` | — |
| Blender export (`tools/blender`) | exports a camera's animation to the same JSON (Z-up to Y-up, metres to studs using the round-trip scale convention, roll extracted) | headless bpy export of a neutral path, then a Lune spec validates and samples it |

Multiplayer sync (start time from the server, clients sample `now - start`) is left to the game repo. It needs a server clock API that was not verified in this pass.

### 6.3 `packages/Feel` (feedback and juice)

```lua
return { -- cue table: plain data, validated
	impact_small = {
		sound = "impact_small", -- AudioDirector event key; the backend owns the asset
		vfx = { recipe = "impact", radius = 1 }, -- Creator/Effects recipe
		shake = { trauma = 0.2 }, -- scaled to 0 under reduced motion
		hitStop = 0.04, -- seconds; overlapping stops merge to the max
		haptic = { type = "GameplayCollision" }, -- HapticEffect.Type
		flash = nil, -- Feel.Screen pulse, rate-limited
		popup = nil, -- Feel.Popups template key
		priority = 3,
	},
}
```

| Module | Behaviour | Test (container) |
|---|---|---|
| `Spring` | `Spring.new(x, { dampingRatio, frequency })`, `:setTarget`, `:step(dt) -> value, velocity, settled`. Closed-form damped oscillator (under, critical and over damped), so the result does not depend on dt. Numbers, plus vectors componentwise | ζ = 1 never overshoots; ζ < 1 overshoot matches the closed form; 60 × 1/60 equals 30 × 1/30 within 1e-9 |
| `Shake` | trauma 0 to 1 with decay; amplitude ∝ trauma²; per-axis Luau `math.noise` ("Returns 3D Perlin noise ... in [-1, 1]"); seeded; presets; a reduced-motion scale | determinism per seed; decays to 0; bounded amplitude |
| `HitStop` | `request(duration, now)` merges to the max; `scale(now)` returns 0 or 1. The Studio adapter calls `AnimationTrack:AdjustSpeed(0)` and restores the previous speed | merge and expiry |
| `Popups` | `aggregate(events, window)` merges same-key values; `layout(active)` stacks without overlap. The Studio adapter pools BillboardGuis (`AlwaysOnTop`, `MaxDistance`, `StudsOffsetWorldSpace`) with a UIScale pop and a fade | aggregation, layout, pool cap |
| `Screen` | Owned `ColorCorrectionEffect`/`BlurEffect` pulses (springs); a vignette from a radial `UIGradient` (no image asset); a flash limiter of at most 3 per rolling second (WCAG 2.3.1); reduced motion drops shake and zoom punches and keeps fades | limiter boundary cases |
| `Haptics` | `HapticEffect` wrapper (parent before `Play`, `Ended` cleanup); no-op on unsupported devices | Studio/device only |
| `Cues` | `validate(cues, recipes, audioEvents)`: a cue with sound must also have a visual channel (accessibility page), values in range, known recipes, a per-frame budget. `bindMarkers(track, { Hit = "impact_small" })` uses `GetMarkerReachedSignal`; marker coverage is checked with `Motion.validateMarkers` | validator negatives; binding with a fake track |

### 6.4 Changes to existing files (proposed, not made here)

- `NativeUI.luau` and `Creator/UI.luau`: replace `Enum.Font.Gotham*` with token `FontFace` and `RenderStepped:Wait()` with `PreRender`. Then move the reusable parts into UIKit, keeping thin compatibility shims so the inherited specs still pass.
- `Motion.luau`: keep `validateMarkers` and `contactDrift`. Point `curve` and `transition` at `UIKit.Ease`, or keep them as is with a note.
- `SceneKit/Lighting.luau`: optional persistent post-processing baseline in profiles. ColorGradingEffect goes under Lighting only, per the class page.
- Skills: update `roblox-ui-ux-pass` (UIKit, StyleQuery, IAS, PreferredInput, the three accessibility settings, `UIKit.Audit`). Add a `roblox-cinematics-feel` skill (cutscene spec, cue tables, reduced-motion and flash rules, motion evidence via recording). Then run `python3 tools/sync_skills.py`.
- `tools/new_project.py` and `docs/starter.md`: ship UIKit, Cinematics and Feel by default, since they are genre-neutral, unlike Runtime/Creator commerce.

### 6.5 Verification (what proves it)

- **Container (Linux, no Studio):**
  - Lune specs for every pure part above.
  - Golden digests for the cutscene fixture.
  - `@lune/roblox` instance-structure specs for components, if the classes exist in Lune's reflection DB.
  - Rojo build of `fixtures/ui.project.json`.
  - StyLua and Selene.
  - Headless Blender export of a neutral camera path, then a Lune round trip.
- **Studio (PC, unpublished diagnostic place):**
  - Apply the StyleSheet and mount the gallery with `execute_luau`.
  - Run `UIKit.Audit` at the Device Simulator sizes; take `screen_capture` per size.
  - Drive Back and focus with `user_keyboard_input`.
  - Check `Ease` parity against `TweenService:GetValue` at 101 samples per style and direction.
  - Play the fixture cutscene and compare per-frame camera CFrames with `Cinematics.sample` within a tolerance.
  - Fire a Feel cue on a rig from a local KeyframeSequence registered with `RegisterKeyframeSequence` (a Studio-only temporary id; nothing uploaded).
- **Motion evidence:** stills do not prove motion. Use the existing FFmpeg owned-window recording on the PC (addendum section F).
- **Physical devices** (haptics, notches, console ten-foot UI): owner-run, and recorded as still needed until done.

### 6.6 Proposed gap-matrix rows (for `reports/gap-matrix.json`; not edited here)

The proposed rows are: UI kit (MISSING), UI transitions and easing parity (PARTIAL: `Motion.luau` only), input-agnostic navigation on IAS (MISSING), cutscene/camera package (MISSING), feel/juice package (PARTIAL: Effects and AudioDirector exist, no shake, hit-stop, popups or cues), UI audit with pseudo-localization (PARTIAL: `Creator/UI` audit), cinematics/feel skill (MISSING), and the inherited UI deprecations (WEAK).

## 7. UNVERIFIED

- Whether Lune 0.10.5's rbx-dom reflection database (0.728, per the Lune release notes) includes `StyleSheet`, `StyleRule`, `StyleQuery`, `UIShadow`, `UIFlexItem` and the IAS classes. StyleRule methods (`SetProperties`) are probably not implemented in Lune, so UIKit specs should test plans, not applied styles.
- The exact composed selector syntax (for example a tag plus a state plus a query in one selector) and how rule priority resolves between them. The docs confirm each selector kind separately.
- Whether Roblox's Back, Elastic and Bounce easing constants match common formulas. A Studio parity spec will settle this.
- Whether Studio's Device Simulator or Player Emulator can emulate `PreferredTextSize`, `PreferredTransparency` and `ReducedMotionEnabled`.
- Where ColorGradingEffect may be parented: the guide says "Lighting or Camera", the class page says Lighting only.
- The full `HapticEffectType` list.
- The terms of the "Builder Font License".
- Where an `InputContext` must be parented: the docs do not say.
- Whether automatic translation or text capture works in an unpublished place.
- Flipbook's generic-story signature, and whether its agent-control PRs (#639 fetched; #646 seen only in search results) are merged.
- UI Labs release years: the page shows conflicting years.
- The `roblox/react-lua` mirror's latest release date (the summary said 2026-01-18, which conflicts with the fork's history).
- Commit activity after the last release for Fusion, TopbarPlus, Iris and spr (commit pages are blocked).
- Both community camera techniques (the Moon Animator CFrame-folder export and the Blender rig with AnimationController) are leads, not verified behaviour.
- The 44 px touch-target and breakpoint thresholds are heuristics (the first is from the existing skill), not Roblox-sourced numbers.
- The WCAG contrast-ratio formula proposed for the token spec was not fetched in this pass.

## 8. Sources (all fetched 2026-10-06)

- Roblox docs (`.md` variants): `https://create.roblox.com/docs/en-us/<path>.md` for:
  - layout and appearance: `ui/list-flex-layouts`, `ui/appearance-modifiers`, `ui/size-modifiers`, `ui/position-and-size`, `ui/styling`, `ui/styling/compatibility`, `ui/animation`, `ui/video-frames`
  - input and accessibility: `input/input-action-system`, `input/gamepad`, `production/publishing/accessibility`, `production/localization/localize-with-scripting`
  - camera and animation: `workspace/camera`, `animation/events`, `animation/using`, `environment/post-processing-effects`
  - classes: `reference/engine/classes/` `UIFlexItem`, `UIStroke`, `UIShadow`, `UIGradient`, `CanvasGroup`, `Path2D`, `StyleQuery`, `ScreenGui`, `GuiService`, `GuiBase2d`, `GuiObject`, `UserInputService`, `TextLabel`, `InputBinding`, `InputContext`, `TweenService`, `RunService`, `Camera`, `AnimationTrack`, `CurveAnimation`, `MarkerCurve`, `KeyframeSequenceProvider`, `BlurEffect`, `ColorGradingEffect`, `HapticEffect`, `BillboardGui`
  - enums and datatypes: `reference/engine/enums/` `ScreenInsets`, `GuiState`, `EasingStyle`, `Font`; `reference/engine/datatypes/Font`
- Roblox index: https://create.roblox.com/docs/llms.txt
- DevForum announcements: https://devforum.roblox.com/t/full-release-ui-styling-is-officially-released/4275082 , https://devforum.roblox.com/t/full-release-stylequery-more-styling-features/4566519 , https://devforum.roblox.com/t/full-release-new-ui-capabilities-shadows-individual-corners/4636263 , https://devforum.roblox.com/t/full-release-input-action-system-ias-newly-converted-player-scripts/4678416
- DevForum community leads (not evidence): https://devforum.roblox.com/t/camera-animations-for-cutscenes-and-gameplay/1181691 , https://devforum.roblox.com/t/blender-roblox-camera-cutscene/2847027
- UI frameworks: https://github.com/dphfox/Fusion , https://github.com/dphfox/Fusion/releases , https://github.com/dphfox/Fusion/releases/tag/v0.3-beta , https://raw.githubusercontent.com/dphfox/Fusion/main/README.md , https://api.wally.run/v1/package-metadata/elttob/fusion , https://github.com/jsdotlua/react-lua , https://github.com/jsdotlua/react-lua/releases , https://registry.npmjs.org/@jsdotlua/react , https://api.wally.run/v1/package-metadata/jsdotlua/react , https://github.com/Roblox/react-lua , https://github.com/Roblox/react-lua/releases , https://github.com/centau/vide , https://github.com/centau/vide/releases , https://api.wally.run/v1/package-metadata/centau/vide , https://github.com/Roblox/roact , https://github.com/SirMallard/Iris , https://github.com/SirMallard/Iris/releases , https://api.wally.run/v1/package-metadata/sirmallard/iris , https://github.com/1ForeverHD/TopbarPlus , https://github.com/1ForeverHD/TopbarPlus/releases , https://api.wally.run/v1/package-metadata/1foreverhd/topbarplus
- Motion libraries: https://github.com/Fraktality/spr , https://raw.githubusercontent.com/Fraktality/spr/master/README.md , https://github.com/littensy/ripple , https://raw.githubusercontent.com/littensy/ripple/main/README.md , https://registry.npmjs.org/@rbxts/ripple , https://api.wally.run/v1/package-metadata/littensy/ripple , https://github.com/Reselim/flipper , https://github.com/Reselim/flipper/releases , https://registry.npmjs.org/@rbxts/flipper , https://github.com/Sleitnick/RbxCameraShaker
- Storybooks and skills: https://github.com/flipbook-labs/flipbook/releases , https://github.com/flipbook-labs/flipbook/pull/639 , https://flipbook-labs.github.io/flipbook/docs/intro/ , https://flipbook-labs.github.io/flipbook/docs/writing-stories/ , https://raw.githubusercontent.com/flipbook-labs/storyteller/main/README.md , https://raw.githubusercontent.com/PepeElToro41/ui-labs/main/README.md , http://ui-labs.luau.page/docs/storybooks , https://ui-labs.luau.page/docs/stories/function , https://github.com/PepeElToro41/ui-labs/releases , https://github.com/afrxo/roblox-agent-skills , https://raw.githubusercontent.com/afrxo/roblox-agent-skills/main/skills/roblox-ui/SKILL.md
- Luau and Lune: https://luau.org/library , https://lune-org.github.io/docs/roblox/4-api-status/ , https://github.com/lune-org/lune/releases (the page showed 0.10.5 as "July 2, 2024"; crates.io gives 2026-07-02, see `tooling-2026-10.md` section 10)
- Accessibility: https://www.w3.org/WAI/WCAG22/Understanding/three-flashes-or-below-threshold.html
