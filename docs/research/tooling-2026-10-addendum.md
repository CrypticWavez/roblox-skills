# Tooling research addendum (verified 2026-10-06)

This addendum extends `tooling-2026-10.md` (sections 1-9) with the topics that file does not cover. Back-filled price, update and maintenance data for the existing candidates is in that file's section 10.

**Method.** All sources were fetched on 2026-10-06; the list is at the end.
- Primary sources only: create.roblox.com (including `/docs/llms.txt` and the `.md` page variants), docs.github.com, code.claude.com, learn.chatgpt.com, and GitHub repo, README and release pages.
- Package registries: the npm registry search API, the crates.io API, PyPI project pages and the Wally API.
- Some sources were unavailable. The GitHub API returned 403. GitHub Atom feeds, commit pages, the PyPI JSON API and the Go module proxy were blocked by robots.txt.
- Dates from GitHub release pages are shown as the page shows them ("dd Mon"), and their year is recorded as unknown.
- A dagger (†) marks a date with a year that a GitHub page reported but that no registry confirmed.
- Pages were read through a summarising fetcher, so short quotes are given where wording matters.
- Nothing was installed, bought or signed up for.

**Decision rule.**
- SELECT means use now, or keep using, inside SETUP_ONLY.
- REJECT means do not adopt. This applies to anything that publishes, uploads, spends, writes production data or picks game content, whatever its merit.
- REVISIT means the facts are recorded but the decision waits for a stated trigger, usually a future game repository, a measured need or a prototype.
- "Not yet implemented" means the decision is made but nothing in the repo uses it yet.

**Table layout.** Each topic has two tables:
- Facts: name, official source, publisher, version, last update, maintenance, licence, price.
- Assessment: purpose/capabilities, security, overlap, automation (Claude/Codex access), benefit, decision.

**Guard coverage (affects every new MCP server).** The repo's PreToolUse guards match only `Bash`, `Edit|Write|MultiEdit`, and the `Roblox_Studio`/`blender` MCP servers (`.claude/settings.json`). Any newly added MCP server's tools would therefore be unguarded until the owner adds a matcher. Agents cannot edit settings.

---

## A. UI (frameworks and Studio UI tooling)

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Native UI + UI styling (StyleSheet, StyleRule, StyleLink, Style Editor) | create.roblox.com/docs/ui ; /docs/ui/styling | Roblox | ships with Studio (741 live, week of 2026-09-28) | tracks Studio | active | Roblox terms | free |
| React Lua | github.com/jsdotlua/react-lua | jsdotlua (community fork of Roblox's read-only `roblox/react-lua` mirror) | v17.2.1 | "04 Dec", year unknown | community; 570 stars; not archived | MIT | free |
| Fusion | github.com/dphfox/Fusion ; Wally `elttob/fusion` | dphfox | v0.3 (Wally 0.3.0), labelled beta | "30 Aug", year unknown | single maintainer; 797 stars | MIT | free |
| Flipbook (storybook plugin) | github.com/flipbook-labs/flipbook | flipbook-labs | v2.5.0 | "10 Apr", year unknown | active; 123 stars | MIT | free (Creator Store plugin or GitHub release) |
| UI Labs (storybook plugin) | github.com/PepeElToro41/ui-labs | PepeElToro41 | v1.6.0 | 2026-01-25 † | active; 173 stars | GPL-3.0 | free (Creator Store plugin) |

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| Native + styling | ScreenGui/SurfaceGui/BillboardGui, list/flex/grid layouts, UIStroke/UIGradient. Styling is "a Roblox solution to stylesheets, similar to CSS", with tokens (StyleSheet attributes) and swappable themes, and can be authored from Luau | none beyond Studio | `packages/Runtime/NativeUI.luau`, `packages/Creator/UI.luau` already target it | `execute_luau` builds and inspects; `screen_capture` plus Device Simulator check it; Lune tests pure helpers | zero dependencies; this is what the engine renders | **SELECT**; neutral fixture UI may use StyleSheet tokens |
| React Lua | React 17 translation: components, hooks, reconciler | third-party runtime code in a game; Wally supply chain | Fusion, Vide, native helpers | runtime tests need Roblox (Jest Lua), not Lune | state management for large UIs | **REVISIT** in a game repo: choosing a UI framework is game production |
| Fusion | reactive state (scopes, computeds), declarative instances. Vide (centau/vide 0.4.1, 2026-07-11 †, MIT) is a similar, smaller alternative | as React Lua | React Lua, Vide | as React Lua | concise reactive UI | **REVISIT** (same reason) |
| Flipbook | Storybook-style plugin that renders UI component "stories" in Studio without Play. Supports Roact, Roact 17 and Fusion | Studio plugin with full access to the open place; v2.4.0 added "Anonymized usage metrics" with an opt-out | visual-qa `screen_capture` of fixture UI | GUI only; no MCP/API surface | fast visual iteration on components | **REVISIT** once a component library exists; the owner would install it |
| UI Labs | Storybook-like plugin, "visualize stories in real-time without needing to run your code" | Studio plugin, same as Flipbook | Flipbook | GUI only | same as Flipbook | **REVISIT**; if one storybook is needed, prefer MIT Flipbook unless UI Labs supports the chosen framework better |

## B. Animation (editor, rig/export paths, libraries)

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Studio Animation Editor | create.roblox.com/docs/animation/editor | Roblox | ships with Studio | tracks Studio | active | Roblox terms | free |
| 3D Importer, animation data (.fbx/.gltf) | create.roblox.com/docs/studio/importer | Roblox | ships with Studio | tracks Studio | active | Roblox terms | free |
| Animation Capture (face via webcam, body via video) | create.roblox.com/docs/animation/capture | Roblox | beta features | unknown | beta | Roblox terms | free |
| Roblox Blender plugin | github.com/Roblox/roblox-blender-plugin | Roblox | unknown (not shown) | unknown | not archived; 244 stars | MIT | free |
| Moon Animator 2 | Creator Store listing (see `knowledge/records/tools-options.json`) | xsixx | unknown | unknown | unknown | Creator Store terms | USD 19.99 sale price seen 2026-10-05 |

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| Animation Editor | keyframes, easing styles, priorities (Core to Action4), looping, curve and face editors. Saves a KeyframeSequence locally in ServerStorage, and "Publish to Roblox" creates an asset | Publishing is an upload, so ask or deny | Blender `ops.keyframe_clip` path in `tools/blender/bkit` | authoring is GUI only; saved KeyframeSequences can be inspected with `execute_luau` | engine-native timing review | **SELECT**: local save only, never publish from this repo |
| 3D Importer | imports meshes, rigs, skinning and "animation data" from .fbx/.gltf. When "Upload to Roblox" is on, it "adds the model to your Toolbox and Asset Manager inventory" | Keep "Upload to Roblox" off. Whether an import with it off still transfers data is not documented (UNVERIFIED; also noted in `knowledge/records/production-tools.json`) | `blender-roblox-roundtrip` skill | GUI only; Studio MCP has no file-import tool | the only documented Blender-to-Studio rig route | **SELECT**, ask first, as in the round-trip rules |
| Animation Capture | generates keyframes from webcam (face, up to 60 s) or video (body, under 15 s; R15) | Footage must follow Community Rules. Where processing happens is not stated (UNVERIFIED). Needs beta opt-in | Animation Editor | GUI only | quick reference motion | **REJECT**: beta, footage of people, and the output is content rather than tooling |
| Roblox Blender plugin | "upload selected assets in Blender to Roblox using Roblox's Open Cloud API" with OAuth to the account or groups; Blender 3.2+ | publishes assets under the account | factory export plus Importer | Blender GUI | one-click upload | **REJECT**: an upload path |
| Moon Animator 2 | third-party animation workspace plugin | purchase; plugin access to the place | native editor plus Blender | GUI only | unproven | **REJECT**: paid, and the free route covers the need |

No external runtime animation library was found worth adding. Inspection is covered in-repo by `packages/Creator/AnimationInspector.luau` and the `tests/creator/animation.luau` suite. A community Blender rig exporter/animation importer (DevForum thread 34729, by Den_S) exists. It is distributed only through the forum and its licence is unknown, so it is **REJECT**.

## C. VFX (particles, beams, trails)

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Native ParticleEmitter / Beam / Trail with Properties editors | create.roblox.com/docs/effects/particle-emitters ; /docs/effects/beams | Roblox | engine | tracks Studio | active | Roblox terms | free |
| vfx-editor (Studio plugin) | github.com/VirtualButFake/vfx-editor | VirtualButFake | unknown (not shown) | unknown | 21 stars; not archived | MIT | free (Creator Store or GitHub `.rbxm`) |
| Lumina (custom particle system with graph editor) | github.com/Mqxsyy/Lumina | Mqxsyy | 0.2.1 | 2024-06-19 † | work in progress | MIT | free |

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| Native | Particles: flipbooks (2x2/4x4/8x8, up to 30 fps), Color/NumberSequence editors, Lifetime "internally capped at 20". Beams: render between two Attachments, cubic Bezier via CurveSize0/1. Performance notes: fill rate and overdraw cost GPU, and flipbooks switch off on low-memory clients | none | `packages/Creator/EffectsPool.luau`, `Effects.luau`, `packages/Runtime/NativeEffects.luau` | fully scriptable via `execute_luau`; `screen_capture` gives stills only, and stills do not prove motion | engine-native, no dependency | **SELECT** |
| vfx-editor | sequence editors with easing and Bezier curves, texture store with flipbooks, undo/redo, light/dark themes | Studio plugin with full place access; source available | Properties panel editors | GUI only | faster manual tuning | **REVISIT**: human-side convenience; the owner would install it |
| Lumina | custom particle renderer and node graph | adds runtime cost | native particles | Luau API | effects beyond native emitters | **REJECT**: the author says "I do not recommend using this in production" |

## D. Terrain (APIs, heightmap import)

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Terrain class API | create.roblox.com/docs/reference/engine/classes/Terrain | Roblox | engine | tracks engine | active | Roblox terms | free |
| Terrain Editor: Generate, Import heightmap/colormap, Sculpt/Paint/Sea Level | create.roblox.com/docs/parts/terrain | Roblox | ships with Studio | tracks Studio | active | Roblox terms | free |
| Gaea (external heightmap generator) | quadspinner.com/Order | QuadSpinner | 2.x (exact version not shown) | unknown | commercial | proprietary, perpetual licence | Community free for non-commercial use, capped at 1024x1024. Indie USD 99, Professional 199, Enterprise 299 |

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| Terrain API | FillBlock/Ball/Cylinder/Wedge/Region; ReadVoxels/WriteVoxels (material and occupancy arrays); Read/WriteVoxelChannels; ReplaceMaterial; CopyRegion/PasteRegion; Get/SetMaterialColor; WorldToCell helpers | local edits only | SceneKit `Apply.terrain` uses FillBlock/FillBall today | `execute_luau` | WriteVoxels could apply a `Terrain.heightmap` plan region by region (region size limits not checked), and ReadVoxels could read it back to validate the result (relevant to gap-matrix S05) | **SELECT** (WriteVoxels/ReadVoxels path not yet implemented) |
| Terrain Editor | Import takes ".jpg or .png", "maximum of 4096x4096 pixels", where "1 pixel in a heightmap represents 4 studs". A colormap maps colours to materials. The file is chosen from local disk | Whether Studio uploads the image as an asset is not stated (UNVERIFIED), so ask first | SceneKit `Terrain.heightmap` (deterministic, seeded) | GUI only; no import API found | hand-made heightmaps | **REVISIT**: manual path only; seeded SceneKit plans stay the default |
| Gaea | erosion and terrain simulation; exports heightmaps | desktop app; licence terms | SceneKit heightmaps; Blender displacement or Geometry Nodes (existing toolchain) | none for agents | high-end erosion looks | **REJECT**: commercial use needs a purchase, and existing tools cover the setup need |

## E. Context, memory and code index (Claude and Codex on Luau)

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| luau-lsp as Claude Code LSP server (plugin `lspServers` / `.lsp.json`) and as the `luau-lsp analyze` CLI | code.claude.com/docs/en/plugins-reference ; github.com/JohnnyMorganz/luau-lsp | JohnnyMorganz | 1.69.0 (repo pins 1.68.1) | 2026-07-18 | active (1,944 commits) | MIT | free |
| Serena (symbol-level MCP) | github.com/oraios/serena ; PyPI `serena-agent` | Oraios AI | 1.7.0 | 2026-08-09 (PyPI) | active | Repo LICENSE: GPL-3.0-or-later for the app, MIT for SolidLSP, so a combined distribution is GPL. The PyPI page shows "MIT", which conflicts | free (the JetBrains plugin is paid) |
| Roblox docs for agents: `llms.txt` plus `.md` page variants | create.roblox.com/docs/llms.txt | Roblox | n/a | file header "Last updated: 2026-10-02T21:49:02Z" | active | content CC-BY-4.0 per the creator-docs repo (UNVERIFIED that this covers the served pages) | free |
| Roblox/creator-docs (offline clone) | github.com/Roblox/creator-docs | Roblox | n/a (2,075 commits) | unknown (commit page blocked) | active; 785 stars | prose CC-BY-4.0, code samples MIT | free |
| Native memory: Claude CLAUDE.md, `.claude/rules/` and auto memory; Codex AGENTS.md and Memories | code.claude.com/docs/en/memory ; learn.chatgpt.com/docs/config-file/config-reference | Anthropic / OpenAI | Claude Code 2.1.290; Codex CLI 0.157.1 (npm) | 2026-10-05 / 2026-09-26 | active | proprietary / Apache-2.0 | part of existing plans (pricing not fetched) |

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| luau-lsp | Diagnostics, definitions, references and hover, with Rojo sourcemap resolution. `luau-lsp analyze` gives "type and lint warnings in CI, with full Rojo resolution and API types support" | local process; Roblox type definitions are downloaded at setup | Selene lints, but luau-lsp adds type checking | Claude: plugin `lspServers` entry (`command`, `extensionToLanguage` required; `diagnostics` defaults to true, pushing errors after edits). Codex: no documented LSP hook (UNVERIFIED), but both can run the CLI | catches type errors at edit time; symbol lookups instead of whole-file reads | **SELECT** (already pinned). Not yet implemented: count a baseline with `luau-lsp analyze`, then add it as a gate step; optionally ship a project plugin with `.lsp.json` |
| Serena | symbol-level retrieval, editing and refactoring through language servers for 40+ languages, Luau included; agent memories | Ships `execute_shell_command` and file-edit tools. The README says these are typically disabled in Claude Code/Codex contexts; if enabled, they are unguarded (see guard coverage). GPL app | luau-lsp, `rg`, native Read/Edit | MCP for Claude and Codex | faster navigation in large codebases | **REJECT** now; **REVISIT** if the repo outgrows `rg` plus LSP |
| llms.txt + `.md` pages | index of about 2,290 pages. "Add `.md` to any documentation URL to read it as Markdown." It advises against `llms-full.txt` ("tens of megabytes") | read-only HTTPS | none | Claude WebFetch; Codex web tools. Whether Studio MCP `http_get` accepts `.md` URLs is UNVERIFIED | primary-source docs at low context cost (used throughout this pass) | **SELECT**: cite in the `roblox-research` skill |
| creator-docs clone | guides plus a read-only engine API reference in YAML (`content/en-us/reference/`) | data only | llms.txt route | `rg` for both agents | offline API lookups, e.g. to build guard or lint lists | **REVISIT**: needs a refresh step; size unknown |
| Native memory | CLAUDE.md levels; `.claude/rules/` with path scoping; imports up to "four hops". Auto memory is "on by default in local sessions": one directory per repo, shared across worktrees, first 200 lines or 25 KB loaded; turn it off with `autoMemoryEnabled: false` or `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`. Claude Code 2.1.277+ reads AGENTS.md directly only when no CLAUDE.md exists. Codex: AGENTS.md, and `features.memories` "off by default" | auto memory is unreviewed text outside the repo and can go stale | `knowledge/records/`, `docs/research/` | built in | durable shared context lives in versioned files | **SELECT** the repo-file approach (CLAUDE.md imports AGENTS.md, skills, records). Treat auto memory as non-authoritative and leave Codex Memories off |

## F. Visual QA, browser, screenshot and video

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Studio MCP `screen_capture` | create.roblox.com/docs/studio/mcp | Roblox | Studio 741 | tool list re-read 2026-10-06, unchanged | active | Roblox terms | free |
| FFmpeg window capture (`gdigrab`) | ffmpeg.org | FFmpeg project | 9.0.2 "Lei" | 2026-09-18 | active | LGPL-2.1+, or GPL when built with GPL parts | free |
| pixelmatch (image diff) | github.com/mapbox/pixelmatch ; npm `pixelmatch` | Mapbox | 7.2.0 | 2026-04-29 (npm) | active | ISC | free |

Playwright MCP and Chrome DevTools MCP are assessed in section J.

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| `screen_capture` | "Captures the current Studio viewport and returns the image data. Optionally accepts a custom camera position and look-at target." | read-only; images may show private place content | Blender `render-manifest` previews | MCP, Claude and Codex | the only engine-truth image path | **SELECT** (in use) |
| FFmpeg | `gdigrab` captures a region or a window by `title=` on Windows; gives motion evidence | Can capture any window, so restrict it to the owned window. The inherited `docs/window-recording.md` workflow checks ownership | none for video | CLI on the PC for both agents | motion evidence that stills cannot give | **SELECT** (existing, PC only; Studio recording not yet exercised). No Studio-native recording API was found (UNVERIFIED) |
| pixelmatch | per-pixel comparison of two same-size images | library only | `Scene.compare` structural manifest diff | Node (already required for hooks) | pixel regression for Blender previews | **REVISIT**: there is no pixel baseline yet, and Cycles CPU previews are only bit-stable within one bpy version (UNVERIFIED), so tolerance and per-version baselines would come first |

## G. Performance

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| MicroProfiler | create.roblox.com/docs/performance-optimization/microprofiler | Roblox | engine/Studio | tracks Studio | active | Roblox terms | free |
| Script Profiler + `ScriptProfilerService` | create.roblox.com/docs/studio/optimization/scriptprofiler ; /docs/reference/engine/classes/ScriptProfilerService | Roblox | engine/Studio | tracks Studio | active | Roblox terms | free |
| Developer Console Memory + Luau Heap | create.roblox.com/docs/studio/developer-console ; /docs/studio/optimization/memory-usage | Roblox | engine/Studio | tracks Studio | active | Roblox terms | free |

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| MicroProfiler | Frame timeline, opened with Ctrl+F6 (Cmd+F6 on Mac). The Dump menu saves HTML to `%LOCALAPPDATA%\Roblox\logs` (Windows) or `~/Library/Logs/Roblox` (macOS). Mobile devices serve a LAN web UI (the docs example uses port 1338). `debug.profilebegin/profileend` add custom labels. Server dumps come from the Developer Console (up to 60 frames, up to 4 s delay) | the mobile web UI exposes profiling on the LAN, so use trusted networks only | Script Profiler | Labels come from Luau; no script API to trigger a dump was found (UNVERIFIED), so dumps are human-triggered. Dump files are HTML | ground truth for frame cost | **SELECT** (named in `roblox-performance-pass`) |
| Script Profiler | CPU time per function at 1 kHz (default) or 10 kHz, client or server, JSON export. `ScriptProfilerService` (Plugin security) offers ClientStart/Stop, ServerStart/Stop, ServerRequestData, OnNewData and DeserializeJSON | none beyond plugin context | MicroProfiler | `execute_luau` runs in plugin context, so an agent should be able to start and stop profiling and save the JSON (UNVERIFIED until exercised in a play session) | the most automatable perf measurement; supports before/after numbers | **SELECT** for human use now. The `execute_luau` capture into `reports/` is not yet implemented |
| Memory + Luau Heap | Memory categories (PlaceMemory: Instances, LuauHeap, Graphics, TerrainVoxels and more). Heap snapshots with graph, object-tag, `debug.setmemorycategory` and unparented-instance views | none | Stats service counters (not verified this pass) | snapshots are GUI only | finds leaks and growth | **SELECT** (human in the loop) |

## H. Security

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Selene std overlay with `deprecated` entries + `deprecated` lint | kampfkarren.github.io/selene/usage/std.html ; /lints/deprecated.html | Kampfkarren | 0.31.0 | 2026-05-21 (crates.io) | active | MPL-2.0 | free |
| t (runtime type checker) | github.com/osyrisrblx/t | osyrisrblx | unknown (not shown) | unknown | 325 stars; not archived | MIT | free |
| Zap (networking IDL compiler) | github.com/red-blox/zap | red-blox | v0.6.29 | "23 Jun", year unknown | 0.6.x maintained by the community; a major rewrite is on a separate branch | MIT | free |
| gitleaks | github.com/gitleaks/gitleaks | Gitleaks project | v8.30.1 | "21 Mar", year unknown | active; 29.7k stars | MIT | CLI free. `gitleaks-action` needs a free licence key, which requires sign-up, for organisation-owned repos |
| GitHub secret scanning + push protection | docs.github.com (about secret scanning; push protection for users) | GitHub | service | n/a | active | GitHub terms | free on public repos |

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| Selene overlay | A std file (`base: roblox`) can mark members with `deprecated: { message }`, and `deprecated = "deny"` turns uses into lint errors. The overlay is combined via `std = "roblox+<overlay>"`. Intended use: flag publish, spend and DataStore-write APIs in `packages/` | Static guard to complement the runtime guards. Coverage is UNVERIFIED: Selene resolves std-defined globals and fields, but methods on instances obtained at runtime (e.g. `store:SetAsync`) are probably not typed, so it may miss the main cases | guard hooks (runtime); a simpler alternative is a gate step that greps `packages/` with the guard_mcp patterns | already runs in the gate (`selene packages`; CI strict, local SKIPPED) | catches publishing or spending code before it reaches Studio | **REVISIT**: prototype on a known-bad file first. `roblox.yml` is generated and gitignored, so an overlay must be its own committed file |
| t | runtime type checks for remote arguments | strengthens server validation | hand-written validators; `roblox-multiplayer-integrity` procedure | Lune can test pure use | less boilerplate | **REVISIT** in a game repo (networking architecture is a per-game choice) |
| Zap | IDL compiles to buffer-packed remotes; "validates all data received". Blink (1Axen/blink: v0.18.8, and v1.0.0-pre.6; MIT) is the Luau-written equivalent. Blink's "security through obscurity" claim is not a security property | generated validation lowers hand-written mistakes | t, hand validators | CLI | bandwidth plus validated decoding | **REVISIT** in a game repo |
| gitleaks | regex secret scanning of git history (`git`), directories (`dir`) and stdin; `.gitleaks.toml` | detection only | `tools/check.py` secret-scan with `tools/hooks/secret-patterns.json` (shared with the edit hook; 17 self-test samples); GitHub push protection | CLI for both agents | broader rule set and full-history scan | **REVISIT**: borrow rules into `secret-patterns.json` if a miss is found. Adopting the CLI is a new install; avoid the Action because it needs sign-up |
| GitHub secret scanning | "Secret scanning runs automatically for free" on public repos; "Push protection for users is on by default for public repositories" | blocks pushes containing detected secrets | repo secret-scan | server side | defence in depth for a public repo | **SELECT** (no action needed; this repo's settings were not inspected, so it is UNVERIFIED that the feature is on) |

Supply-chain note: a web search for Roblox UI libraries on 2026-10-06 returned SEO-style repositories, some of them exploit "script hubs". Take dependencies only from registries (Wally, pesde, crates.io, npm) or from repos linked by official docs or DevForum announcements. Never run exploit tooling, even for "testing".

## I. CI/CD

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Current: GitHub Actions + Rokit install script + `rokit install` | `.github/workflows/factory.yml` ; github.com/rojo-rbx/rokit | rojo-rbx | Rokit 1.2.0 | 2025-09-30 (crates.io) | active org; no Rokit release in 12 months | MIT | free (Actions pricing for public repos not fetched) |
| setup-rokit action | github.com/CompeyDev/setup-rokit (fork: roblox-ts/setup-rokit v0.1.2) | CompeyDev | v0.2.1 | 2026-05-06 † | small (17 stars) | MIT | free |
| Lune + Rojo build in CI | crates.io `lune`, `rojo` | lune-org / rojo-rbx | 0.10.5 / 7.7.1 | 2026-07-02 / 2026-10-02 | active | MPL-2.0 | free |
| Open Cloud Place Publishing + Luau Execution | create.roblox.com/docs/cloud/guides/usage-place-publishing ; /docs/cloud/reference/features/luau-execution | Roblox | publishing v1; luau-execution v2 | unknown | active | Roblox terms | free with an API key or OAuth |

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| Current install | pinned tool versions in `rokit.toml`; gate runs in `--strict` | The installer is piped from the Rokit `main` branch, and `rokit install --no-trust-check` skips the trust prompt. Versions are pinned, but the installer script and artifact checksums are not | setup-rokit | CI | already green-capable | **SELECT** (keep). Not yet implemented: pin the installer URL to a release tag or commit |
| setup-rokit | wraps the install with `version`, `path`, `cache` and `token` inputs | third-party action, so pin by commit SHA | current script | CI | caching | **REJECT**: small single-maintainer action; a pinned script gives the same result |
| Lune + Rojo | `rojo build` of creator/diagnostic/factory; Lune specs and fixture hashes | none | none | CI and local | reproducible gate | **SELECT** (in use) |
| Open Cloud | Publishing POSTs .rbxl/.rbxlx to `.../versions?versionType=Published` (needs `universe-places` write). Luau Execution needs an existing universe/place; tasks run up to 5 min, 10 concurrent per place, 450 KB logs; scripts "can also invoke engine APIs that read and/or modify data stored in the cloud, such as those for DataStores" | Publishes, can touch production data, and needs API-key secrets. Guard hooks already deny Open Cloud writes and `rbxcloud` except get/list/help | Studio MCP for local runs | none in this repo | headless in-engine tests | **REJECT** in this factory; supersedes the SELECT in `tooling-2026-10.md` sections 3 and 6. Revisit only in a game repo after explicit authorization. Deploy CLIs (`rbxcloud`, Mantle, `rojo upload`) stay denied and were not re-researched |

## J. Section 11 MCP additions (least privilege)

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Playwright MCP | github.com/microsoft/playwright-mcp ; npm `@playwright/mcp` | Microsoft | 0.0.83 | 2026-09-28 (npm) | active, frequent releases | Apache-2.0 | free |
| Chrome DevTools MCP | github.com/ChromeDevTools/chrome-devtools-mcp ; npm `chrome-devtools-mcp` | Google LLC | 1.10.1 | 2026-09-23 (npm) | active | Apache-2.0 | free |
| Filesystem MCP | github.com/modelcontextprotocol/servers (`src/filesystem`) ; npm `@modelcontextprotocol/server-filesystem` | MCP project (LF Projects) | 2026.8.31 | 2026-08-31 (npm) | active | MIT (README); npm field "SEE LICENSE IN LICENSE" | free |
| Fetch MCP | PyPI `mcp-server-fetch` (modelcontextprotocol/servers) | Anthropic, PBC | 2026.8.18 | 2026-08-18 (PyPI page) | active | MIT | free |
| Context7 (docs search) | github.com/upstash/context7 ; npm `@upstash/context7-mcp` | Upstash | 4.1.1 | 2026-09-14 (npm) | active | MIT | free tier; API key from a sign-up for higher rate limits |

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| Playwright MCP | Browser automation through accessibility snapshots ("No vision models needed"). Tools include `browser_navigate`, `browser_snapshot`, `browser_take_screenshot`, `browser_evaluate`, `browser_file_upload`, `browser_network_requests`, `browser_pdf_save`, `browser_start_video` and `browser_start_tracing` | "Playwright MCP is **not** a security boundary." Options: `--isolated`, `--headless`, `--allowed-origins`, `--blocked-origins`, `--caps`; file access is restricted unless `--allow-unrestricted-file-access`. Unguarded unless a matcher is added | WebFetch for docs; it cannot see Studio | `claude mcp add playwright npx @playwright/mcp@latest`; Codex `[mcp_servers.playwright]` | Only for web artifacts, such as a MicroProfiler HTML dump or an HTML report; no current gate produces one | **REVISIT**. If adopted: pin `@playwright/mcp@0.0.83` (not `@latest`); use `--isolated --headless` with `--allowed-origins` limited to what is needed; deny `browser_file_upload` and `browser_evaluate` by default (Claude permission deny rules, Codex `disabled_tools`); add a guard matcher; never use a logged-in profile or roblox.com account pages, where a browser can publish or spend |
| Chrome DevTools MCP | screenshots, performance traces, network and console with source-mapped stacks; `--slim`, `--headless`, `--isolated` | "exposes content of the browser instance to the MCP clients". Usage statistics are "enabled by default" (off with `--no-usage-statistics`, `CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS`, or when `CI` is set). Performance tools may send trace URLs to the Google CrUX API (`--no-performance-crux`) | Playwright MCP | MCP | web performance debugging, which is not a Roblox need | **REJECT** |
| Filesystem MCP | read/write/edit/move/search tools limited to allowed directories (args or MCP Roots) | Its writes bypass both the FAST_ON_EDIT edit hook and the guards (see guard coverage) | native Read/Write/Edit in Claude and Codex | MCP | none | **REJECT**: redundant and widens the write path |
| Fetch MCP | URL to Markdown. "This server can access local/internal IP addresses and may represent a security risk" | Reaches loopback and LAN HTTP services, such as the local bridge on :3002 listed in `docs/mcp.md`; unguarded | Claude WebFetch; Codex web tools | MCP | none | **REJECT** |
| Context7 | remote server (`mcp.context7.com`); tools `resolve-library-id` and `query-docs`. Projects are community-contributed: "cannot guarantee the accuracy, completeness, or security" | remote, third-party content; key needs a sign-up | Roblox `llms.txt` plus `.md` pages (primary source) | MCP | Whether Roblox docs are indexed is unknown (not checked) | **REJECT**: secondary source; the primary docs are already agent-friendly |

GitHub MCP server (github.com/github/github-mcp-server, GitHub; v1.11.0, release page "25 Aug", year unknown; licence not shown on the fetched pages). `docs/mcp.md` lists a "Claude GitHub integration" for PRs/CI. Whether that integration is this server is not confirmed.
- It can run remote or local. `--read-only` skips write tools. `--toolsets`/`GITHUB_TOOLSETS` defaults to "context, repos, issues, pull_requests, users", and `--tools` narrows further. OAuth login keeps the token "in memory only".
- **SELECT** as the way to talk to GitHub if a GitHub MCP is configured, with least privilege: read-only with only the `repos,pull_requests,actions` toolsets for the `qa-reviewer` and `researcher` roles, and a fine-grained token scoped to this repository where a PAT is used.

General MCP least-privilege rules (both clients):
- stdio or loopback only; nothing public.
- Pin versions; no `@latest`.
- Restrict tools with Claude `permissions.deny` on `mcp__<server>__<tool>` or Codex `enabled_tools`/`disabled_tools`.
- Add a PreToolUse matcher for every new server (an owner change to `.claude/settings.json`).
- No secrets in arguments.
- Turn telemetry off where it exists.
- One writer per Studio/Blender session (`docs/mcp.md`).

---

## Summary

**Selected now.**
- No install needed, or already in use: native UI and styling; Studio Animation Editor (local save only); 3D Importer with Upload off (ask first); native ParticleEmitter/Beam/Trail; Terrain API; Studio MCP `screen_capture`; FFmpeg window capture (PC); MicroProfiler; Script Profiler; Memory/Luau Heap; Roblox `llms.txt` and `.md` docs; the repo-file memory approach; GitHub secret scanning; Lune and Rojo in CI; the current Rokit install; GitHub MCP with read-only toolsets.
- Selected but not yet implemented:
  - `luau-lsp analyze` gate step, plus an optional Claude `.lsp.json`.
  - `ScriptProfilerService` capture via `execute_luau` into `reports/`.
  - WriteVoxels/ReadVoxels terrain apply and read-back.
  - Pinning the Rokit installer.

**Rejected.** Animation Capture; Roblox Blender plugin (uploads); Moon Animator 2 (paid); Den_S rig exporter; Lumina; Gaea; Serena (for now); setup-rokit action; Open Cloud Place Publishing and Luau Execution (and the Assets API, per `tooling-2026-10.md` section 10); Chrome DevTools MCP; Filesystem MCP; Fetch MCP; Context7.

**Revisit (trigger).**
- React Lua, Fusion/Vide, t, Zap/Blink: a game repository chooses its UI and networking stack.
- Flipbook / UI Labs: a reusable UI component library exists.
- vfx-editor: the owner wants manual VFX tuning.
- Terrain Editor import: a hand-made heightmap is required.
- Selene `deprecated` overlay: a prototype catches a known-bad publish/spend call; otherwise use a grep gate step with the guard patterns.
- creator-docs clone: offline API lookups are needed by a gate.
- pixelmatch: stable per-version preview baselines exist.
- gitleaks: the repo scanner misses a real secret.
- Playwright MCP: a web artifact needs automated inspection.
- Serena: `rg` plus LSP proves insufficient.

## Sources (all fetched 2026-10-06)
- Roblox: https://create.roblox.com/docs/ui , https://create.roblox.com/docs/ui/styling , https://create.roblox.com/docs/animation/editor , https://create.roblox.com/docs/en-us/animation/capture.md , https://create.roblox.com/docs/en-us/studio/importer.md , https://create.roblox.com/docs/art/blender , https://create.roblox.com/docs/effects/particle-emitters , https://create.roblox.com/docs/effects/beams , https://create.roblox.com/docs/parts/terrain , https://create.roblox.com/docs/en-us/parts/terrain.md , https://create.roblox.com/docs/reference/engine/classes/Terrain , https://create.roblox.com/docs/performance-optimization/microprofiler , https://create.roblox.com/docs/studio/optimization/scriptprofiler , https://create.roblox.com/docs/reference/engine/classes/ScriptProfilerService , https://create.roblox.com/docs/studio/developer-console , https://create.roblox.com/docs/en-us/studio/optimization/memory-usage.md , https://create.roblox.com/docs/scripting/security/security-tactics , https://create.roblox.com/docs/cloud/guides/usage-place-publishing.md , https://create.roblox.com/docs/cloud/reference/features/luau-execution.md , https://create.roblox.com/docs/en-us/studio/mcp.md , https://create.roblox.com/docs/llms.txt , https://create.roblox.com/docs/updates/2026-09-28 , https://create.roblox.com/docs/updates/2026-09-21
- Roblox GitHub: https://github.com/Roblox/creator-docs , https://github.com/Roblox/roblox-blender-plugin
- UI: https://github.com/jsdotlua/react-lua , https://github.com/jsdotlua/react-lua/releases , https://github.com/dphfox/Fusion , https://github.com/dphfox/Fusion/releases , https://github.com/dphfox/Fusion/releases/tag/v0.3-beta , https://api.wally.run/v1/package-metadata/elttob/fusion , https://github.com/centau/vide , https://github.com/centau/vide/releases , https://github.com/flipbook-labs/flipbook , https://github.com/flipbook-labs/flipbook/releases , https://github.com/PepeElToro41/ui-labs
- Animation/VFX leads: https://devforum.roblox.com/t/blender-rig-exporteranimation-importer/34729 (lead only), https://github.com/VirtualButFake/vfx-editor , https://github.com/Mqxsyy/Lumina
- Terrain: https://quadspinner.com/Order , https://help.quadspinner.com/article/29-can-i-use-gaea-for-free
- Context: https://code.claude.com/docs/en/plugins-reference , https://code.claude.com/docs/en/memory , https://learn.chatgpt.com/docs/config-file/config-reference , https://github.com/JohnnyMorganz/luau-lsp , https://github.com/JohnnyMorganz/luau-lsp/releases , https://github.com/oraios/serena , https://github.com/oraios/serena/releases , https://raw.githubusercontent.com/oraios/serena/main/README.md , https://raw.githubusercontent.com/oraios/serena/main/LICENSE , https://pypi.org/project/serena-agent/
- Visual QA: https://ffmpeg.org/download.html , https://ffmpeg.org/legal.html , https://ffmpeg.org/ffmpeg-devices.html , https://registry.npmjs.org/-/v1/search?text=pixelmatch
- Security: https://kampfkarren.github.io/selene/usage/configuration.html , https://kampfkarren.github.io/selene/usage/std.html , https://kampfkarren.github.io/selene/lints/deprecated.html , https://github.com/osyrisrblx/t , https://github.com/red-blox/zap , https://github.com/red-blox/zap/releases , https://github.com/1Axen/blink , https://github.com/1Axen/blink/releases , https://github.com/gitleaks/gitleaks , https://github.com/gitleaks/gitleaks/releases , https://raw.githubusercontent.com/gitleaks/gitleaks-action/master/README.md , https://docs.github.com/en/code-security/secret-scanning/introduction/about-secret-scanning , https://docs.github.com/en/code-security/secret-scanning/working-with-secret-scanning-and-push-protection/push-protection-for-users
- CI/CD: https://github.com/CompeyDev/setup-rokit , https://github.com/roblox-ts/setup-rokit , https://crates.io/api/v1/crates/rokit , https://crates.io/api/v1/crates/lune , https://crates.io/api/v1/crates/rojo
- MCP: https://registry.npmjs.org/-/v1/search?text=%40playwright%2Fmcp , https://raw.githubusercontent.com/microsoft/playwright-mcp/main/README.md , https://registry.npmjs.org/-/v1/search?text=chrome-devtools-mcp , https://raw.githubusercontent.com/ChromeDevTools/chrome-devtools-mcp/main/README.md , https://registry.npmjs.org/@modelcontextprotocol/server-filesystem , https://raw.githubusercontent.com/modelcontextprotocol/servers/main/src/filesystem/README.md , https://pypi.org/project/mcp-server-fetch/ , https://registry.npmjs.org/-/v1/search?text=%40upstash%2Fcontext7-mcp , https://raw.githubusercontent.com/upstash/context7/master/README.md , https://github.com/github/github-mcp-server/releases , https://raw.githubusercontent.com/github/github-mcp-server/main/README.md
