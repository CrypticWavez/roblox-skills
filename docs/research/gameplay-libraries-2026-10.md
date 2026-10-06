# Open-source Luau gameplay libraries and package managers (verified 2026-10-06)

This pass covers community Luau libraries for gameplay systems and the package managers that would deliver them. It extends three earlier passes:
- [tooling-2026-10.md](tooling-2026-10.md): sections 3 and 10 hold the toolchain facts for Wally, pesde, Jest Lua and TestEZ.
- [tooling-2026-10-addendum.md](tooling-2026-10-addendum.md): section H recorded t, Zap and Blink as REVISIT.
- [ui-cinematics-feel-2026-10.md](ui-cinematics-feel-2026-10.md): proposes the in-repo UIKit `State`, `Feel.Spring` and `Feel.Shake`, so this pass does not re-evaluate motion or UI-state libraries.

It answers four questions:
1. Which libraries, if any, the factory and the game starter should vendor or pin.
2. Which systems the factory should write itself as small, Lune-tested modules.
3. How Rojo projects consume Wally and pesde.
4. What licences allow, both in this public repo and in a commercial game.

Nothing here picks a genre, theme, world, characters or economy.

**Method.**
- All sources were fetched on 2026-10-06; the list is in section 11.
- Primary sources:
  - create.roblox.com `.md` pages, found through `https://create.roblox.com/docs/llms.txt`;
  - DevForum announcements, plus the authors' own resource threads for libraries distributed that way;
  - GitHub repo, release, LICENSE, raw README and raw manifest pages;
  - registries: the Wally API (`https://api.wally.run/v1/package-metadata/<scope>/<name>`), the crates.io API, the npm registry search API and pesde.dev package pages;
  - library documentation sites: docs.pesde.dev, lune-org docs, eryn.io/Cmdr, madstudioroblox.github.io/ProfileStore and 1axen.github.io/blink.
- Some sources were unavailable:
  - The GitHub API, the tags pages and directory listings are blocked (robots.txt or 403). "Last update" therefore means the last release or registry publish.
  - The Wally API returns no dates, and it returned HTTP 500 for packages it apparently does not hold.
- GitHub release pages show "dd Mon" without a year for recent releases. A dagger (†) marks a year that only the fetcher's reading of a GitHub page supplied and that no registry confirmed.
- Pages were read through a summarising fetcher, so short quotes are given where wording matters. When a registry and a GitHub page disagree, the conflict is recorded.
- Nothing was installed, bought or signed up for.

**Decision rule** (same as the addendum):
- **SELECT**: worth adding to the factory, as a pinned dependency in the game starter, a documented install, in-repo code or a reference.
- **REJECT**: do not adopt.
- **REVISIT**: the facts are recorded; the decision waits for the stated trigger.

---

## 1. Decisions in brief

1. **The factory stays at zero third-party runtime dependencies.** `packages/` is copied byte for byte into game repos (`tools/new_project.py`) and is tested in Lune. Wally's generated linker modules use `script.Parent` instance requires. Lune documents only path-string requires and does not list a `script` global. A Wally dependency inside `packages/` would therefore break Lune testing (section 4).
2. **A new genre-neutral `packages/GameKit` replaces most of the library list with small, Lune-tested modules:** `Signal`, `Scope`, `Fsm`, `BehaviorTree`, `RateLimit`, `Retry`, `Schema`, `RemoteGuard`, `Projectile`, `Hitbox`, `Zones`, `NavAgent` and `PlayerData`. Each wraps a documented engine primitive (spatial queries, PathfindingService, DataStores, remotes and the `buffer` type) or is pure logic. Each is designed to work under Server Authority (section 3).
3. **Game starter, persistence: SELECT ProfileStore 1.0.3** (Apache-2.0), pinned through Wally as a server dependency and wrapped by `GameKit/PlayerData` through dependency injection. Session locking is the one system where a battle-tested library clearly beats writing our own.
4. **Game starter, networking: SELECT Blink 0.18.9**, a CLI pinned in the starter's `rokit.toml`. It compiles a schema with ranges and size bounds into typed, buffer-packed, validated Luau, so it adds no runtime library. Under Server Authority, remotes carry only discrete messages; the core simulation uses `BindToSimulation`, InputActions and attributes.
5. **Game starter, package manager: SELECT Wally 0.3.2**, opt-in, with a factory allowlist and a committed `wally.lock`. The Wally CLI is stale (last release 2023-06-05), but both Wally-delivered selections (ProfileStore and Jest Lua) are published on its registry. pesde can install Wally packages (`wally#scope/name`), so switching later is cheap. pesde is **REVISIT**.
6. **Testing is unchanged:** Lune specs first, and Jest Lua 3.10.0 (Wally `jsdotlua/jest` and `jsdotlua/jest-globals`) for in-Studio tests in game repos. TestEZ stays REJECT (archived 2024-09-14).
7. **REJECT** these candidates, for the reasons given in section 5:

   | Group | Rejected |
   |---|---|
   | Frameworks and ECS | Knit (archived 2024-07-31), Matter (archived; fork stale) |
   | Persistence and async | ProfileService (superseded), DataStore2 (Roblox calls it legacy), Promise |
   | Signals and cleanup | GoodSignal, LemonSignal, sleitnick/signal, Roblox/signals (as a signal library), Trove, Janitor, Maid |
   | Networking and replication | Zap, ByteNet, Red (archived 2025-12-23), Packet, Warp, RbxUtil Comm/TypedRemote/Net, ReplicaService |
   | Utilities | t, Sift, and RbxUtil (including TableUtil) as a dependency |
   | Gameplay helpers | SimplePath, ZonePlus, FastCast/FastCast2, RaycastHitbox, ShapecastHitbox, MuchachoHitbox, StateQ, BehaviorTrees3, community rate limiters |
8. **REVISIT:**
   - pesde, if Wally's CLI or registry breaks or a needed package is pesde-only.
   - jecs, if a game adopts ECS or simulates thousands of entities.
   - Cmdr, if a game needs a human-operated admin console.
   - Replica, if a game needs per-player state subscriptions beyond attributes and Blink events.
   - wally-package-types, once its current version is confirmed.
9. **New guard gap.** The hooks do not know Wally's publish and login commands or pesde's publish and authentication commands. Adding a package manager to game repos needs a guard update first (section 7.4).

## 2. What the repo has today (judged 2026-10-06)

| Item | State | Relevance |
|---|---|---|
| `packages/*` | No third-party code. Cross-package requires are string requires (`require("../ProcGen/Rng")`), matching both Lune and Roblox require-by-string | Keep it this way |
| [`tools/new_project.py`](../../tools/new_project.py) | Copies the packages, `rokit.toml`, the hooks and the skills. No `wally.toml` or pesde support; default packages are SceneKit, ProcGen and Pipeline | Needs an opt-in dependency step (section 7.3) |
| [`templates/starter/default.project.json`](../../templates/starter/default.project.json) | Maps `packages` to `ReplicatedStorage.Workbench` plus `src/*`; no `Packages` mapping | Same |
| [`rokit.toml`](../../rokit.toml) | rojo, lune, stylua, selene, luau-lsp; no wally or blink | The starter copy gains wally and blink pins |
| [`packages/Runtime/ReceiptLedger.luau`](../../packages/Runtime/ReceiptLedger.luau) + [`RobloxReceiptAdapter.luau`](../../packages/Runtime/RobloxReceiptAdapter.luau) | Grant-once receipts through `UpdateAsync` with an injected store; Lune specs use a fake store (gap row R01) | `PlayerData` reuses this injection pattern. Receipts move into the session-locked profile (section 7.2) |
| [`packages/Runtime/Lifetime.luau`](../../packages/Runtime/Lifetime.luau) | Bounded priority scheduler for VFX lifetimes; not a general cleanup object | `GameKit/Scope` complements it and does not replace it |
| [`packages/Diagnostics/FaultQueue.luau`](../../packages/Diagnostics/FaultQueue.luau) | Simulated loss, duplication and reordering (11 Lune cases) | Reused to test `RemoteGuard` and Blink-style message handling |
| [`roblox-persistence-and-commerce`](../../.agents/skills/roblox-persistence-and-commerce/SKILL.md), [`roblox-multiplayer-integrity`](../../.agents/skills/roblox-multiplayer-integrity/SKILL.md) | Sound procedures that name no library. Neither mentions Server Authority, ProfileStore or schema-generated remotes | Update (section 7.5) |
| [`reports/gap-matrix.json`](../../reports/gap-matrix.json) Q03, Q07 | Q03: no remote-validation helpers (PARTIAL). Q07: no reusable gameplay systems (PARTIAL) | This pass gives the fix for both |

## 3. Engine facts that change the library picture

| Fact | Detail (quoted where wording matters) | Source |
|---|---|---|
| **Server Authority, full release 2026-07-09** | Setting `Workspace.AuthorityMode = Server` forces `NextGenerationReplication`, `PlayerScriptsUseInputActionSystem`, `SignalBehavior = Deferred`, `StreamingEnabled` and `UseFixedSimulation`. "Write your core logic inside functions bound through `RunService:BindToSimulation()` in a ModuleScript that's initialized on both the client and server." "InputActions should be used for all inputs that affect the core simulation." "Only write to attributes on predicted instances from within functions bound through `BindToSimulation()`." "RemoteEvents might not be consistently ordered with property and attribute updates." "Do not use traditional events like `UserInputService.InputBegan` in the core simulation"; use `time()`, not `tick()`, `os.time()` or `os.clock()`. Limits: 64 attributes per instance; 8 active animation tracks per Animator. Roblox is exploring "server side rewind hit detection" | DevForum full-release post; docs `projects/server-authority`, `projects/server-authority/techniques` |
| Server Authority techniques | State machines keep their state in attributes (the grenade `State` example). Instances created in a simulation callback must be parented "before the end of that frame" | docs `projects/server-authority/techniques` |
| SignalBehavior | `Default` is "currently equivalent to `Immediate` but this will eventually change to `Deferred`" | docs `reference/engine/enums/SignalBehavior` |
| Require-by-string | Live since 2025-01-22. Supports `./`, `../`, `@self`, and `@game` (added 2026-01-08). No absolute paths; custom aliases are "Not yet" | https://devforum.roblox.com/t/introducing-require-by-string/3405078 |
| Remote arguments | Functions arrive as `nil`; "all the metatable information is lost"; avoid mixed or `nil`-holed tables; tables are copied. `UnreliableRemoteEvent` drops payloads "larger than 1,000 bytes" and does not queue. "Client-to-server messages are subject to a rate limit that each remote type shares across all of its instances" | docs `scripting/events/remote` |
| `buffer` | Up to 1 GiB. Sending through Roblox APIs delivers a copy | docs `reference/engine/libraries/buffer` |
| DataStore guidance | "Prefer `UpdateAsync()` when a write depends on the current value or when multiple servers might write the same key." Retry with "exponential backoff" and "random jitter". One key per player while under the 4 MB limit. "DataStore2 is a legacy third-party library and you shouldn't use it for new experiences" | docs `cloud-services/data-stores/best-practices` |
| DataStore limits | Per server per minute: read and write each `60 + numPlayers × 40`. Per key: 25 MB/min read, 4 MB/min write. Value up to 4,194,304 characters; key and store names up to 50 characters. Queues hold at most 30 requests; errors 301-306 mean throttled or queue full | docs `cloud-services/data-stores/error-codes-and-limits` |
| Official session-lock pattern | Roblox documents a lock stored in key metadata inside the same `UpdateAsync`, with a per-server GUID and an expiry ("any server is free to take over the lock"). Receipts: "Verify the `PurchaseId` has not already been recorded as handled", recording it in player data | docs `cloud-services/data-stores/player-data-purchasing` |
| Spatial queries | `Raycast` up to 15,000 studs. `Blockcast` (size up to 512) and `Spherecast` (radius up to 256) reach at most 1,024 studs. `Shapecast` is thread-unsafe. None of the three casts detects "BaseParts that **initially** intersect the shape"; `GetPartsInPart` uses exact volume, while `GetPartBoundsInBox`/`GetPartBoundsInRadius` use bounding boxes. All carry Simulation Access | docs `reference/engine/classes/WorldRoot` |
| Pathfinding | `CreatePath` agent parameters `AgentRadius`, `AgentHeight`, `AgentCanJump`, `AgentCanClimb`, `WaypointSpacing` and `Costs`; `PathfindingModifier` labels; `PathfindingLink` labels; on `Path.Blocked`, recompute "only if the blocked waypoint is ahead". Limits: 3,000 studs line of sight, 20,000 nodes | docs `characters/pathfinding` |
| Chat commands | `TextChatCommand` with `PrimaryAlias`, `SecondaryAlias` and `Triggered(originTextSource, unfilteredText)` | docs `reference/engine/classes/TextChatCommand` |

**Consequences for library choice.**
- Engine-native prediction and attribute state now cover what replication and character-networking libraries were used for in competitive games.
- Under Server Authority, Heartbeat-driven projectile and hitbox libraries need to run inside `BindToSimulation` with `time()`. None of the third-party candidates documents that.
- Deferred signals become the default, so a signal library tuned for immediate firing gives no advantage.

## 4. Package managers: Wally vs pesde

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Wally (CLI + registry) | https://github.com/UpliftGames/wally ; registry index https://github.com/UpliftGames/wally-index | Uplift Games | 0.3.2 | 2023-06-05 (crates.io) | No release in over 3 years; not archived; 484 stars, 52 open issues. The registry API answered on 2026-10-06 | MPL-2.0 | free |
| pesde | https://github.com/pesde-pkg/pesde ; docs https://docs.pesde.dev | pesde-pkg | 0.7.4 | 2026-09-09 (crates.io; earlier releases 0.7.3 2026-03-18, 0.7.2 2025-12-26) | active | MIT | free |
| pesde Rojo scripts (`pesde/scripts_rojo`) | https://github.com/pesde-pkg/scripts | pesde-pkg | not shown | unknown | 74 commits; requires pesde `^0.7.0` and Lune `^0.10.2` | MIT | free |
| wally-package-types | https://github.com/JohnnyMorganz/wally-package-types | JohnnyMorganz | not shown | unknown | not archived | MIT | free |

| Candidate | Purpose / capabilities | Security | Overlap | Automation and Lune-testability | Benefit | Decision |
|---|---|---|---|---|---|---|
| Wally | `wally.toml` with `realm` ("server" and "shared"), `[dependencies]`, `[server-dependencies]` and `[dev-dependencies]`, and `private = true`, which prevents publishing. The lockfile "contains the exact versions of each dependency". `wally install` writes `Packages`, `ServerPackages` and `DevPackages`, each with `_Index` and linker modules such as `return require(script.Parent._Index["{scope}_{name}@{version}"]["{name}"])` | `wally login` (with `--token`) logs in "to publish packages to a registry". Neither login nor publishing is **covered by the guard hooks** (section 7.4). Packages come from a GitHub-hosted index | pesde | CLI for both agents. Linker modules use instance requires, so packages cannot load in Lune. Exported types are lost through linkers unless `wally-package-types --sourcemap sourcemap.json Packages/` is run | The Wally-delivered selections (ProfileStore, Jest Lua) and most candidates (jecs, Cmdr, t, ShapecastHitbox) are published there | **SELECT** for game repos, opt-in, with exact pins from a factory allowlist and a committed `wally.lock`. Never in the factory's `packages/` |
| pesde | Targets `roblox`, `roblox_server` (for private registries) and `lune`. `pesde add wally#scope/name` installs Wally packages. Dependencies go into `roblox_packages`, mapped in Rojo as `"roblox_packages": { "$path": "roblox_packages" }`. A `roblox_sync_config_generator` script, usually `pesde/scripts_rojo`, is required; types for Wally dependencies need a `sourcemap_generator` script | Its publish and authentication commands (names not checked in this pass) would also be unguarded | Wally | CLI. Lune-target packages run in Lune | active; one tool for Roblox and Lune packages | **REVISIT** if Wally's CLI or registry fails, or if a needed package is pesde-only. It adds a Lune-script dependency (`scripts_rojo`) to every game repo, which the current needs do not justify |
| wally-package-types | "fixes the issue of wally thunks not including exported types" | local CLI | luau-lsp | CLI | typed autocompletion for ProfileStore and similar | **REVISIT**: version not verified. Add it to the starter pins once a version is confirmed |

**How a Rojo project consumes each (proposal for the starter; Wally's README does not document the mapping):**

```json
{
  "ReplicatedStorage": { "Packages": { "$path": "Packages" }, "Workbench": { "$path": "packages" } },
  "ServerScriptService": { "ServerPackages": { "$path": "ServerPackages" } }
}
```

pesde maps `roblox_packages` instead (docs.pesde.dev Roblox guide). In both cases the installed folders are build outputs: gitignored and restored from the lockfile in CI.

## 5. Candidates

All candidates are free. "Lune" in the assessment column says whether the library could load in the repo's Lune runner unmodified.

### 5a. Persistence

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| ProfileStore | https://github.com/MadStudioRoblox/ProfileStore ; docs https://madstudioroblox.github.io/ProfileStore/ ; Wally `lm-loleris/profilestore` (matches the repo's own `wally.toml`) | loleris (MadStudioRoblox) | 1.0.3 (Wally, repo `wally.toml`) | DevForum announcement 2024-10-11; no GitHub releases; date of 1.0.3 unknown | active repo, not archived; 332 stars | Apache-2.0 (repo LICENSE; the Wally metadata has no licence field) | free |
| ProfileService | https://github.com/MadStudioRoblox/ProfileService | loleris | unknown | unknown | README: "This project is no longer supported", "FOR NEW PROJECTS - USE ProfileStore" | Apache-2.0 | free |
| DataStore2 | (not fetched; Roblox docs only) | community | n/a | n/a | Roblox: "legacy third-party library" | n/a | free |

| Candidate | Purpose / capabilities | Security | Overlap | Automation and Lune-testability | Benefit | Decision |
|---|---|---|---|---|---|---|
| ProfileStore | Session-locked, auto-saving profiles. API: `ProfileStore.New(name, template)`, `:StartSessionAsync(key, {Cancel, Steal})`, `Profile.Data`, `Profile.LastSavedData`, `:Reconcile()`, `:Save()` ("Costs one `UpdateAsync()` call"), `:EndSession()`, `:AddUserId()` (GDPR), `:MessageAsync()` (cross-server messages, e.g. gifting to offline players), `:GetAsync`, `:VersionQuery` (rollback) and `ProfileStore.Mock`. Uses MessagingService to resolve session conflicts; autosave every 300 s (up from 30 s); profiles load ProfileService data with the same keys. "Not designed (and never will be) for in-game leaderboards or any kind of global state" | Server realm (Wally), so it never replicates to clients. `Steal` is for debugging only and risks duplication. DataStore writes are production-data writes (hooks ask or deny) | Roblox's documented lock pattern; `ReceiptLedger` | Needs DataStoreService and MessagingService, so it is Studio-only (`ProfileStore.Mock`). Lune tests the `PlayerData` adapter with a fake ProfileStore-shaped object | removes the most dangerous hand-written system (dupes, lost saves); typed | **SELECT** (game starter allowlist, `[server-dependencies]`, pinned 1.0.3). Wrapped by `GameKit/PlayerData` (section 7.2) |
| ProfileService | predecessor | unsupported | ProfileStore | as above | none | **REJECT**: superseded; its data migrates by key |
| DataStore2 | legacy | n/a | ProfileStore | n/a | none | **REJECT**: Roblox says not to use it for new experiences |

### 5b. Async, signals and cleanup

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Promise | https://github.com/evaera/roblox-lua-promise ; Wally `evaera/promise` | evaera | 4.0.0 | GitHub release "Promise v4.0.0", "March 3" (year not shown) | not archived; 351 stars, 11 open issues | MIT | free |
| GoodSignal | https://github.com/stravant/goodsignal | stravant | v0.2.2 | 2022-06-27 † | dormant; 72 stars | MIT | free |
| LemonSignal | https://github.com/Data-Oriented-House/LemonSignal ; Wally `data-oriented-house/lemonsignal` | Data-Oriented-House | 2.0.0 (Wally) | unknown | 51 stars | MIT (repo; the Wally licence field is null) | free |
| Signal (RbxUtil) | https://github.com/Sleitnick/RbxUtil ; Wally `sleitnick/signal` | Sleitnick | 2.0.3 | unknown (RbxUtil has no GitHub releases) | RbxUtil not archived; 457 stars | MIT | free |
| Roblox/signals | https://github.com/Roblox/signals ; Wally `roblox/signals` | Roblox | 0.9.0 | no releases | 44 stars, 23 commits | MIT | free |
| Trove (RbxUtil) | Wally `sleitnick/trove` | Sleitnick | 1.8.0 | unknown | as RbxUtil | MIT | free |
| Janitor | https://github.com/howmanysmall/Janitor ; Wally `howmanysmall/janitor` | howmanysmall (originally Validark) | 1.18.3 | npm `@rbxts/janitor` 1.18.3-ts.0 2025-05-31 (roblox-ts build by another publisher) | 145 stars, 191 commits | MIT | free |
| Maid (Nevermore) | npm `@quenty/maid` (NevermoreEngine) | Quenty | 3.12.1 | 2026-09-24 (npm) | active (monorepo) | MIT | free |

| Candidate | Purpose / capabilities | Security | Overlap | Automation and Lune-testability | Benefit | Decision |
|---|---|---|---|---|---|---|
| Promise | Promise/A+-like async with cancellation. 4.0.0 made `finally` "mostly transparent" and moved waiting to the `task` library | none | `task`, coroutines | Lune: untested | composable async | **REJECT**: `task` covers the selected systems (ProfileStore, Blink and GameKit need no Promise). Knit's author also moved away from framework-level async (5d) |
| GoodSignal | RBXScriptSignal parity in pure Lua | none | GameKit `Signal` | Lune: plausible (UNVERIFIED) | reference semantics | **REJECT** as a dependency: no release since 2022. Use it as the behavioural reference for `GameKit/Signal` tests |
| LemonSignal | fast pure-Luau signal | none | as above | Lune: UNVERIFIED | speed | **REJECT**: small, and the registry metadata has no licence field |
| Signal (RbxUtil) | Typed `Signal<T...>`; `:Fire` resumes handlers immediately on a reused thread; `:FireDeferred` uses `task.defer` | none | as above | uses the global `task`; Lune: UNVERIFIED | well-known API | **REJECT** as a dependency. `GameKit/Signal` mirrors its names (`Connect`, `Once`, `Wait`, `Fire`, `FireDeferred`, `DisconnectAll`) |
| Roblox/signals | Reactive values (`createSignal`, `createComputed`, `createEffect`), not events | none | UIKit `State` (UI pass) | Lune: UNVERIFIED | official org, but pre-1.0 | **REJECT** for now. It answers a different question; if UIKit `State` grows, compare it there |
| Trove | `--!strict` cleanup object: Add, Connect, Once, Clone, Construct, Extend, AttachToInstance, BindToRenderStep, Clean, Destroy | none | GameKit `Scope` | Loads `RunService` at require time, so it cannot load in Lune unmodified | familiar API | **REJECT** as a dependency. `GameKit/Scope` mirrors the API with an injected environment |
| Janitor | cleanup with Promise and instance linking | none | as above | depends on `howmanysmall/typed-promise` since 1.18.0 | thread-safe | **REJECT**: pulls a Promise dependency |
| Maid | Nevermore's cleanup | none | as above | npm-only in this pass | none over Scope | **REJECT** |

### 5c. Networking and replication

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Blink | https://github.com/1Axen/blink ; docs https://1axen.github.io/blink/ ; Rokit `1Axen/blink` ; pesde `1axen/blink` | 1Axen | **0.18.9** ("Latest" badge); 1.0.0-pre.10 in pre-release | "19 Sep" for both (year not shown; page order implies 2026) | active, frequent 1.0 pre-releases; 181 stars | MIT (LICENSE "2024 Axen") | free |
| Zap | https://github.com/red-blox/zap ; https://zap.redblox.dev | red-blox | v0.6.29 | 2024-06-23 (release page timestamp) | "currently undergoing a rewrite"; 0.6.x "maintained by @sasial-dev"; 188 stars | MIT | free |
| ByteNet | https://github.com/ffrostfall/ByteNet | ffrostfall | release v0.4.3; `wally.toml` on master says 0.5.0 | v0.4.3 2025-03-10 † | single maintainer; 181 stars, 78 commits | MIT | free |
| Red | https://github.com/red-blox/Red | red-blox | unknown | **archived 2025-12-23** | unmaintained | MIT | free |
| Packet | https://devforum.roblox.com/t/packet-networking-library/3573907 (Creator Store asset only) | 5uphi | 1.7 (thread) | thread posted 2025-03-26 | active thread | permissive text "Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted" (ISC/0BSD style; exact name UNVERIFIED) | free |
| Warp | https://github.com/imezx/Warp | imezx | unknown | unknown | 32 stars, 167 commits; Wally and pesde manifests | MIT | free |
| RbxUtil Comm / TypedRemote / Net | https://github.com/Sleitnick/RbxUtil | Sleitnick | 1.0.1 / 0.3.0 / 0.2.0 (README) | unknown | as RbxUtil | MIT | free |
| Replica | https://github.com/MadStudioRoblox/Replica ; https://devforum.roblox.com/t/replica-server-to-client-state-replication-module/3216980 | loleris | no releases; Creator Store asset | thread posted 2024-10-16; 12 commits | "Full documentation is not done yet"; 75 stars; no `wally.toml` | Apache-2.0 | free |
| ReplicaService | https://github.com/MadStudioRoblox/ReplicaService | loleris | unknown | unknown | superseded by Replica | Apache-2.0 (UNVERIFIED in this pass) | free |

| Candidate | Purpose / capabilities | Security | Overlap | Automation and Lune-testability | Benefit | Decision |
|---|---|---|---|---|---|---|
| Blink | An IDL compiler "written in Luau for ROBLOX buffer networking". Types `u8`-`u32`, `i8`-`i32`, `f16`/`f32`/`f64`, `string`, `buffer`, `boolean`, `vector`, `array`, `map`, `set`, `struct`, enums (unit and tagged), `unknown`, `Instance`, `CFrame<i16, f16>`, `BrickColor`, `Color3`, `DateTime` and `DateTimeMillis`. Bounds such as `u8(0..100)`, `string(3..20)`, `buffer(..900)`, `vector(0..1)`, `string[25..50]`. "Data sent by clients will be validated on the receiving side before reaching any critical game code." Studio plugin for editing | **v0.18.9 fixed "NaN scalars and vectors bypassing inexact range validation"**, so pin at least 0.18.9. Its "harder to snoop" claim is not a security property (addendum H). Generated code is the game's own source | Zap, ByteNet, hand-written remotes | The CLI runs in a container through Rokit (whether a Linux binary is published is UNVERIFIED) and on the PC. The compiler is Luau; generated modules need Roblox remotes. Compile and lint are gateable; runtime is Studio Server & Clients | validated, typed, bandwidth-lean remotes with no runtime library | **SELECT**: pin `1Axen/blink@0.18.9` in the starter's `rokit.toml`; a neutral `.blink` fixture plus a compile step in the starter gate. Re-check before moving to 1.0 |
| Zap | IDL to buffer-packed code; "validates all data received" | as Blink | Blink | CLI | similar to Blink | **REJECT**: no release since 2024-06-23 and a rewrite in progress |
| ByteNet | Runtime library that serialises to buffers (namespaces, structs; v0.4.2 fixed broken client-to-server unreliable events) | runtime code in every game | Blink | Lune: UNVERIFIED | no codegen step | **REJECT**: single maintainer; release and manifest versions disagree |
| Red | networking library | unmaintained | Blink | n/a | none | **REJECT**: archived |
| Packet | batching, buffer serialisation, f16/f24 types, "DDoS protection"; v1.7 "Fixed vulnerability" | Creator Store model only: no registry pin, no diffable source in a lockfile | Blink | GUI insert | none over Blink | **REJECT**: supply chain (model-only distribution) |
| Warp | runtime networking library | runtime code | Blink | Lune: UNVERIFIED | none | **REJECT**: low adoption |
| Comm / TypedRemote / Net | thin remote wrappers | none | GameKit `RemoteGuard` | Roblox-only | familiar | **REJECT**: Knit's author calls such wrappers "trivial"; `RemoteGuard` adds the validation and rate limits these lack |
| Replica | Per-player subscription to server state; `Replica:BindToInstance()` for streaming | runtime code | attributes (predicted under Server Authority) plus Blink events | Roblox-only | selective replication | **REVISIT** if a game needs per-player state subscriptions beyond attributes; not before it has releases or a registry entry |
| ReplicaService | predecessor | unsupported | Replica | n/a | none | **REJECT** |

### 5d. Architecture frameworks and ECS

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Knit | https://github.com/Sleitnick/Knit ; Wally `sleitnick/knit` | Sleitnick | 1.7.0 (Wally) | **archived 2024-07-31** | "No Longer Maintained" | MIT | free |
| jecs | https://github.com/Ukendio/jecs ; Wally `ukendio/jecs` ; npm `@rbxts/jecs` ; pesde `marked/jecs` (described there as "A minimal copy") | Ukendio | 0.11.0 | 2026-03-10 (npm). The GitHub release page reading gave 2025-03-10, which conflicts; npm wins | active; 464 stars, 859 commits | MIT | free |
| Matter | https://github.com/evaera/matter (archived 2024-07-16) → fork https://github.com/matter-ecs/matter ; Wally `matter-ecs/matter` | matter-ecs | fork v0.8.5 (Wally 0.8.4) | 2024-12-09 † (fork release page) | no fork release in about 22 months | MIT | free |

| Candidate | Purpose / capabilities | Security | Overlap | Automation and Lune-testability | Benefit | Decision |
|---|---|---|---|---|---|---|
| Knit | service/controller framework with networking | n/a | plain ModuleScripts | n/a | none | **REJECT**. ARCHIVAL.md: "Knit cannot fully benefit from types"; "ModuleScripts themselves can already work in this way out of the box"; a remote wrapper "is trivial" |
| jecs | Archetype/SoA ECS; relationships as first-class; "Type-safe Luau API"; zero dependencies; claims "800,000 entities at 60 frames per second" | none | plain tables and instances | pure Luau, so Lune is plausible (UNVERIFIED) | throughput for very many simulated entities | **REVISIT** when a game repo adopts ECS or simulates thousands of entities. ECS is an architecture decision per game, not a factory default |
| Matter | ECS with a debugger | n/a | jecs | Wally metadata (original package) depends on TestEZ | none | **REJECT**: original archived, fork stale |

### 5e. Tooling libraries (console, tests, validation, tables)

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Cmdr | https://github.com/evaera/Cmdr ; docs https://eryn.io/Cmdr/ ; Wally `evaera/cmdr` | evaera | GitHub v1.13.1; **Wally newest 1.12.0** | v1.13.1 2024-09-30 † | not archived; 527 stars, 662 commits, 16 open issues | MIT | free |
| Jest Lua | https://github.com/jsdotlua/jest-lua ; Wally `jsdotlua/jest`, `jsdotlua/jest-globals` | jsdotlua | 3.10.0 (both) | see `tooling-2026-10.md` section 10 | see there | MIT | free |
| TestEZ | https://github.com/Roblox/testez | Roblox | n/a | archived 2024-09-14 | unmaintained | Apache-2.0 | free |
| t | https://github.com/osyrisrblx/t ; Wally `osyrisrblx/t` | osyrisrblx | Wally 3.1.1; npm `@rbxts/t` 3.2.1 | npm 2025-02-20 | not archived; 325 stars; no GitHub releases | MIT (repo, Wally); the npm package says ISC | free |
| Sift | https://github.com/csqrl/sift ; Wally `csqrl/sift` | csqrl | 0.0.11 | unknown | "Sift is no longer actively maintained" (not archived) | MIT | free |
| RbxUtil (collection, incl. TableUtil 1.2.1) | https://github.com/Sleitnick/RbxUtil | Sleitnick | 30 modules, versioned individually | no GitHub releases | not archived; 457 stars | MIT | free |

| Candidate | Purpose / capabilities | Security | Overlap | Automation and Lune-testability | Benefit | Decision |
|---|---|---|---|---|---|---|
| Cmdr | Typed, extensible admin/debug console; v1.13 added Guards and TextChatService support; 1.12.0 had "a critical security fix". "Commands will be blocked from running in a live game unless you register at least one `BeforeRun` hook" (except the DefaultUtil and UserAlias groups) | An admin console is an attack surface; authorise on the server. The Wally build lags the GitHub releases | `TextChatCommand`; an agent-callable debug command registry (section 9) | GUI console; agents would use `execute_luau` | live-ops and QA console for humans | **REVISIT** when a game needs a human-operated console. Then pin a version that has both a GitHub release and a registry entry |
| Jest Lua | Jest 27 port; runs only inside Roblox | none | Lune specs | Studio `execute_luau`; headless CI needs Open Cloud (rejected, D03) | in-engine tests | **SELECT** (reaffirmed): game starter allowlist, `[dev-dependencies]` |
| TestEZ | legacy BDD | n/a | Jest Lua | n/a | none | **REJECT** (reaffirmed) |
| t | runtime type checker for remote arguments | strengthens server validation | Blink (schema remotes), GameKit `Schema` | Lune: UNVERIFIED (uses `typeof` on Roblox datatypes) | concise checks | **REJECT** as a dependency. `GameKit/Schema` also covers DataStore payloads, NaN and inf rejection, size and depth budgets and path-specific errors (gap row Q03), which `t` does not target. Borrow its combinator names |
| Sift | immutable table helpers | n/a | `table.clone`, `table.freeze` | n/a | none | **REJECT**: unmaintained |
| RbxUtil | Signal, Trove, Comm, TypedRemote, Net, Component, Timer, Spring, Shake, PID, Streamable, TaskQueue, Ser, BufferUtil and more | per module | GameKit; UI pass `Feel.Spring` and `Feel.Shake` | Wally-only; Trove needs RunService at load | good API naming | **REJECT** as a dependency; it is the naming reference for `Signal`, `Scope` and `RateLimit` |

### 5f. Gameplay helpers (pathing, zones, projectiles, hitboxes, AI, rate limits)

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| SimplePath | https://github.com/grayzcale/simplepath (the release page reading named the repo `ahmicy/simplepath`) | grayzcale | v2.2.1 | 2025-02-28 † | 70 stars; Creator Store asset 6744337775; no Wally manifest seen | MIT | free |
| ZonePlus | https://github.com/1ForeverHD/ZonePlus | 1ForeverHD | v3.2.0 | year UNVERIFIED (v3.0.0 moved to the Spatial Query API) | 101 stars, 26 open issues, 11 PRs; Wally lookup returned 500 | MIT | free |
| FastCast (original) | https://devforum.roblox.com/t/making-a-combat-game-with-ranged-weapons-fastcast-may-be-the-module-for-you/133474 | Xan_TheDragon (EtiTheSpirit) | 13.2.0 | 2020-11-12 (thread) | `github.com/EtiTheSpirit/FastCastAPI` returned 404; the FastCast2 README says "FastCast is no longer actively maintained by EtiTheSpirit" | not stated in the thread | free |
| FastCast2 | https://github.com/weenachuangkud/FastCast2 ; Wally `weenachuangkud/fastcast2` | CK06 and others (unofficial continuation) | 0.1.4 | unknown | 25 stars | "MIT and ART" (exact second licence UNVERIFIED) | free |
| RaycastHitbox V4 | https://devforum.roblox.com/t/raycast-hitbox-401-for-all-your-melee-needs/374482 | TeamSwordphin | 4.01 | 2021-09-21 | "no longer supported and has been superseded by ShapecastHitbox" | "No credits necessary" (no named licence) | free |
| ShapecastHitbox | https://github.com/TeamSwordphin/ShapecastHitbox ; Wally `teamswordphin/shapecasthitbox` | TeamSwordphin | 0.2.9 (Wally) | unknown (no GitHub releases) | 22 stars, 24 commits | MIT | free |
| MuchachoHitbox | https://devforum.roblox.com/t/muchachohitbox-an-easy-to-use-spatialquery-based-hitbox-system/3682320 | SushiManster | unknown | thread posted 2025-06-08 | Creator Store + GitHub | not stated | free |
| StateQ (finite-state-machine-luau) | https://github.com/BusyCityGuy/finite-state-machine-luau ; Wally `busycityguy/stateq` | BusyCityGuy | 0.0.8 | unknown | 30 stars; Lune tests | MIT | free |
| BehaviorTrees3 + BTrees editor | https://devforum.roblox.com/t/behaviortrees3-btrees-visual-editor-v30/836158 ; GitHub `Defaultio/BehaviorTree3` | Defaultio, tyridge77 | 3.0 | last update in the thread 2020-12-02 | stale | not stated | free |
| Community rate limiters | search results only (for example `YetAnotherClown/token-bucket-luau`, `samsho-lab/roblox-remote-guard`) | various | n/a | n/a | not evaluated beyond the search listing | n/a | free |

| Candidate | Purpose / capabilities | Security | Overlap | Automation and Lune-testability | Benefit | Decision |
|---|---|---|---|---|---|---|
| SimplePath | humanoid and non-humanoid path following over PathfindingService | none | GameKit `NavAgent` | Studio-only | quick setup | **REJECT**: no registry package, low adoption. Its feature list (blocked handling, agent config) informs `NavAgent` |
| ZonePlus | enter/exit zones over spatial queries and `CanTouch` | runtime code | GameKit `Zones` | Studio-only | mature | **REJECT**: large surface for a polling diff over `GetPartBoundsInBox`/`GetPartsInPart`; open backlog |
| FastCast / FastCast2 | segment-raycast projectile simulation on Heartbeat | runtime code | GameKit `Projectile` | Studio-only | ballistic projectiles | **REJECT**: original unmaintained; the fork is unofficial with an unclear second licence; Heartbeat stepping does not match Server Authority's `BindToSimulation` model |
| RaycastHitbox V4 | attachment raycast melee hitbox | n/a | ShapecastHitbox, GameKit | n/a | none | **REJECT**: superseded by its authors |
| ShapecastHitbox | shapecast melee hitboxes | runtime code | GameKit `Hitbox` | Studio-only | maintained successor | **REJECT** as a dependency: small (22 stars) and no releases. `GameKit/Hitbox` adds the initial-overlap check the engine docs require |
| MuchachoHitbox | box/sphere hitboxes on spatial queries, velocity prediction | no stated licence | GameKit `Hitbox` | Studio-only | simple | **REJECT**: no licence means it cannot be vendored, especially into a public repo |
| StateQ | typed FSM with queued async transitions | none | GameKit `Fsm` | Lune tests exist | close to what we need | **REJECT** as a dependency: 0.0.x. `Fsm` must also store state in attributes for Server Authority |
| BehaviorTrees3 | visual BT editor, blackboards, live debugger | plugin plus module; no stated licence | GameKit `BehaviorTree` | GUI editor | visual authoring | **REJECT**: stale since 2020 and unlicensed. A data-defined tree is better for agents (plans are data) |
| Community rate limiters | token buckets for remotes | unknown | GameKit `RateLimit` | n/a | none | **REJECT**: tiny repos with unknown quality; a token bucket is about 50 lines and Lune-testable |

## 6. Licence compatibility

This section is not legal advice. It records what each licence text requires, so that a person can decide.

| Licence (candidates) | In this public repo | In a commercial Roblox game |
|---|---|---|
| MIT (most candidates), ISC/0BSD-style (Packet) | Vendoring is allowed with the copyright and licence notice kept. This pass vendors nothing | Allowed. MIT asks that the notice be "included in all copies or substantial portions". Client-visible modules (ReplicatedStorage, StarterPlayer) are sent to players' devices, so keep the notice header inside each vendored or installed module file |
| Apache-2.0 (ProfileStore, Replica, ProfileService, TestEZ) | As MIT, plus the LICENSE text and any NOTICE file; modified files must say they were changed | Allowed. ProfileStore is a server-realm package, so it stays on Roblox servers and is not sent to clients. A `THIRD_PARTY_NOTICES.md` in the game repo still records it |
| MPL-2.0 (Wally CLI; Rojo, Lune, StyLua and Selene per earlier passes) | Tools, not shipped code: no obligation for game code | Not shipped in the game |
| GPL-3.0 (UI Labs, addendum A) | Plugin use only | Never ship GPL code in a game |
| None stated (MuchachoHitbox, BehaviorTrees3, FastCast's DevForum release) | Default copyright: cannot vendor | Do not ship |
| Registry metadata without a licence (ProfileStore and LemonSignal on Wally) | Use the repo LICENSE as the source of truth and record it in the allowlist | same |

Blink-generated modules are the game's own code. Whether Blink's MIT licence attaches to generated output is not stated in the fetched pages (UNVERIFIED). Keeping a one-line attribution comment in the generated header costs nothing.

## 7. Factory design (input to the implementation plan)

### 7.1 `packages/GameKit` (genre-neutral, zero dependencies, Lune-tested)

Conventions, as in SceneKit and the UI pass:
- Pure plans and state live in Lune-tested modules.
- Engine adapters take an injected `env` (spawn/defer, clock, raycast or spatial-query functions, services), so specs run headless.
- Vectors in pure code use the `SceneKit/Vec` style (plain tables), converted only in adapters.
- No module yields inside a step function, so each can be called from `RunService:BindToSimulation()`.
- Time comes from an injected clock (`time()` in Studio, per the Server Authority docs).

| Module | API (sketch) | Lune spec covers | Replaces |
|---|---|---|---|
| `Signal` | `Signal.new(env?)`; `:Connect(fn)`, `:Once`, `:Wait`, `:Fire(...)`, `:FireDeferred(...)`, `:DisconnectAll`, `:Destroy`; a connection has `:Disconnect()` and `.Connected` | disconnect during fire; Once fires once; handler errors do not stop other handlers; deferred ordering; no leak after DisconnectAll | GoodSignal, LemonSignal, RbxUtil Signal |
| `Scope` | `Scope.new(env?)`; `:Add(obj, method?)`, `:Connect(signal, fn)`, `:Extend()`, `:Clean()`, `:Destroy()`; accepts functions, threads, instances (`Destroy`) and connection-like objects (`Disconnect`) | cleanup order (LIFO); cleanup during cleanup refused, as `Lifetime` does; nested scopes | Trove, Janitor, Maid |
| `Fsm` | `Fsm.define({ states, transitions = { { from, event, to, guard? } }, initial })` returns a spec; `Fsm.validate(spec) -> {string}`; `Fsm.new(spec, { onEnter, onExit })`; `:send(event, ctx) -> (ok, reason)`; `:state()`; `:serialize() -> string`; `Fsm.restore(spec, s)` | unreachable and dead-end states; unknown events; guard false; bounded event queue; serialize and restore round trip (state lives in one attribute, per the Server Authority techniques page) | StateQ |
| `BehaviorTree` | data-defined trees `{ type = "sequence"/"selector"/"parallel"/"invert"/"cooldown"/"repeat"/"action"/"condition", ... }`; `BehaviorTree.validate(tree, actions)`; `BehaviorTree.new(tree, actions)`; `:tick(blackboard, dt) -> "success"/"failure"/"running"`; per-tick node budget; seeded choice via `ProcGen/Rng` | statuses per composite; running-node resume; budget cut-off; same seed gives the same trace | BehaviorTrees3 |
| `RateLimit` | `RateLimit.new({ rate, burst, maxKeys })`; `:allow(key, now, cost?) -> (ok, retryAfter)`; `:forget(key)` (PlayerRemoving) | refill maths; burst; key eviction at `maxKeys`; clock going backwards | community rate limiters |
| `Retry` | `Retry.run(fn, { attempts, base, cap, jitter, rng, sleep, isRetryable })`; a DataStore preset that retries 301-306 (throttled or queue full) with "exponential backoff" plus "random jitter", per the docs, and treats other codes per the error-codes page | delay sequence with a fixed seed; stops on non-retryable errors; attempt cap | hand-written loops |
| `Schema` | combinators `number{min,max,integer,finite=true}`, `string{min,max,pattern}`, `enum{...}`, `array(item,{max})`, `map(key,value,{max})`, `struct({...},{strict=true})`, `optional`, `union`, `instance(className)` (injected `typeof`/`IsA`); `Schema.check(schema, value, {maxDepth, maxNodes}) -> (ok, path, reason)`; `Schema.size(value)` (JSON length, checked against the 4,194,304-character value limit) | NaN and inf rejected by default; extra keys rejected in strict mode; mixed or `nil`-holed tables flagged (remote doc); depth and node caps; error paths | t (gap row Q03) |
| `RemoteGuard` | `RemoteGuard.wrap(remote, { schema, rateLimit, authorize(player, args), onReject })` for RemoteEvent, UnreliableRemoteEvent and RemoteFunction (server side). Rejections are counted per player, never error or yield; `UnreliableRemoteEvent` payloads over 1,000 bytes are flagged at send | malformed, oversized, flooding, out-of-order and duplicate calls (reusing `Diagnostics/FaultQueue`); the authorize hook is honoured | RbxUtil Comm/TypedRemote; complements Blink |
| `Projectile` | `Projectile.step(state, dt, env) -> (state, hit?)`: kinematics `p = p0 + v·t + ½·g·t²` split into segments; casts through an injected `cast(origin, delta, params)` (`Raycast` or `Spherecast`); max range and lifetime; pierce and bounce counts | exact positions over time; segment coverage with no gaps; deterministic hits against a fake world; lifetime expiry | FastCast |
| `Hitbox` | `Hitbox.sweep(prev, curr, shape, env)` uses `Blockcast`/`Spherecast` from the previous to the current pose, plus `GetPartsInPart` for the initial overlap the casts miss (WorldRoot docs); per-activation hit set; `Hitbox.validateClaim(serverState, claim, { maxDistance, maxAngle, latencyWindow })` for client-reported hits | dedupe within an activation; the initial-overlap case; claim tolerance boundaries | ShapecastHitbox, MuchachoHitbox, RaycastHitbox |
| `Zones` | `Zones.new({ zones = { { id, kind = "box"/"sphere", cframe, size } }, rateHz })`; `:update(positionsById) -> enters, exits`; Studio adapter queries `GetPartBoundsInBox` at a fixed rate | enter and exit diff; hysteresis; overlapping zones; rate limiting | ZonePlus |
| `NavAgent` | `NavAgent.new(agentParams, env)` (`AgentRadius`, `AgentHeight`, `AgentCanJump`, `AgentCanClimb`, `WaypointSpacing`, `Costs`); `:follow(path)`; follow-state machine (`idle`, `computing`, `moving`, `blocked`, `stuck`, `arrived`, `failed`); recomputes on `Blocked` "only if the blocked waypoint is ahead"; stuck detection by progress over time; retry budget; `PathfindingLink` label callbacks | the follow state machine driven by a fake path; stuck and retry budget; blocked-behind ignored | SimplePath |
| `PlayerData` | section 7.2 | section 7.2 | hand-written save code |

Out of GameKit on purpose: movement (Server Authority plus the default character); ECS (REVISIT jecs); UI state (UIKit); springs and shake (`Feel`); commerce catalogues (a game decision).

### 7.2 `GameKit/PlayerData` over ProfileStore

- `PlayerData.new({ store = ProfileStore.New(name, template), schemaVersion, migrations = { [n] = fn }, keyFor = function(userId) ... end, sizeBudget, env })`. The ProfileStore module is passed in, never required by path. The factory therefore builds and tests without Wally, and a game repo injects `require(ServerPackages.ProfileStore)`.
- Lifecycle: `StartSessionAsync` with `Cancel = function() return not player.Parent end`; `AddUserId`; `Reconcile`; forward-only migrations by `schemaVersion` (one Lune case per step, as the persistence skill requires); `OnSessionEnd` kicks the player; `EndSession` on PlayerRemoving and in `BindToClose`.
- Receipts follow Roblox's documented pattern:
  1. Record the `PurchaseId` in `Profile.Data` (a bounded ring).
  2. Call `Profile:Save()`.
  3. Return `PurchaseGranted` only once `LastSavedData` contains the id; otherwise return `NotProcessedYet`.
  4. `ReceiptLedger`'s grant-once rules move into this adapter, and the separate ledger key is no longer needed for profile-backed games.
- Lune spec, with a fake ProfileStore-shaped object:
  - session steal ends the session;
  - a failed save keeps the good data;
  - a duplicate PurchaseId grants once;
  - migration from every historic version;
  - an oversize payload is refused before saving.

### 7.3 Game starter (`templates/starter`, `tools/new_project.py`)

- `tools/new_project.py --deps <bundle...>` writes `wally.toml` from a factory allowlist, `templates/starter/deps.json`. Each entry records name, exact version, realm, licence, source URL and the reason. Bundles: `persistence` (`lm-loleris/profilestore` 1.0.3, server) and `studio-tests` (`jsdotlua/jest` and `jsdotlua/jest-globals` 3.10.0, dev). The default is none, so a fresh scaffold still builds offline.
- The generated `wally.toml` sets `private = true`, which blocks publishing per the Wally README. `Packages/`, `ServerPackages/` and `DevPackages/` go in `.gitignore`; the Rojo mappings follow section 4; `wally.lock` is committed.
- The starter's `rokit.toml` gains `UpliftGames/wally@0.3.2` and `1Axen/blink@0.18.9`.
- The starter gate (`templates/starter/tools/check.py`) gains a `deps` step. Every `wally.toml` entry must be in the allowlist at the exact version, `wally.lock` must exist when deps exist, and `THIRD_PARTY_NOTICES.md` must list each dependency's licence. It also gains a `blink` step that compiles `net/*.blink` when present.
- `GameKit` joins `DEFAULT_PACKAGES`: it is genre-neutral infrastructure, like the UIKit proposal.

### 7.4 Guard hooks (factory and starter; owner change)

- `tools/hooks/guard_bash.mjs` should deny Wally's `publish` and `login` and pesde's publish and authentication commands (names to confirm from the pesde CLI help), also behind runners such as `rokit`. Its `PUBLISH_TOOLS` set lists rojo, mantle, tarmac, rbxcloud and asphalt today.
- `wally install` and `pesde install` stay allowed only in game repos. Both download code, so they are run only after an explicit game-build request.
- Add self-test cases for each verb.

### 7.5 Skills

- `roblox-persistence-and-commerce`: name `GameKit/PlayerData` plus ProfileStore, Roblox's documented lock and receipt pattern, the DataStore limits from section 3, and `ProfileStore.Mock` for Studio checks.
- `roblox-multiplayer-integrity`: add Server Authority (`AuthorityMode`, `BindToSimulation`, InputActions, attributes, no `InputBegan` in simulation, `time()`), Blink schemas for remotes, and `RemoteGuard` for any plain remote.
- `roblox-luau-testing`: name the GameKit specs as patterns, and Jest Lua through the `studio-tests` bundle.
- New `roblox-gameplay-kit` skill: maps each `roblox-genre-systems` reference (tower-defense pathing, obby checkpoints, RPG inventory and others) to the GameKit modules it needs, without choosing a genre. Run `python3 tools/sync_skills.py` afterwards.

## 8. Verification (what proves it)

- **Container (Linux, no Studio):**
  - Lune specs for every GameKit module.
  - A golden digest for `BehaviorTree` and `Projectile` traces from fixed seeds.
  - The Rojo build of a `fixtures/gamekit.project.json`.
  - StyLua and Selene.
  - `new_project.py --deps persistence studio-tests` into a temporary directory, checking the files it generates. It does not run `wally install`, which needs the network and downloads code.
  - The hook self-test with the new Wally and pesde verbs.
  - Blink compiling a neutral `.blink` fixture, if Rokit can fetch a Linux build (UNVERIFIED).
- **Studio (PC, unpublished diagnostic place):**
  - **Remotes.** Server & Clients with two clients. A client floods a `RemoteGuard`-wrapped remote with malformed and oversized payloads through `execute_luau`; the server counts rejections and no handler errors.
  - **Projectile and Hitbox.** Run against neutral targets on a ProcGen arena fixture; compare engine cast results with the Lune trace within a tolerance.
  - **Zones.** Run enter/exit with `character_navigation`.
  - **NavAgent.** Run on a ProcGen dungeon fixture with a blocked door.
  - **Server Authority.** Repeat the same set with `AuthorityMode = Server` and the modules called from `BindToSimulation`.
- **Needs a game repo, with explicit authorisation:**
  - `PlayerData` with `ProfileStore.Mock` in Studio. The Mock "doesn't persist after server shutdown and doesn't affect live data". Whether it makes any DataStore API call is UNVERIFIED, so treat it as asked-first under the hooks.
  - Real DataStore behaviour, which needs a private test universe (see gap row D03).

## 9. Proposed gap-matrix rows (for `reports/gap-matrix.json`; not edited here)

- GameKit core primitives: Signal, Scope, Fsm, RateLimit, Retry (MISSING).
- Schema and RemoteGuard (fixes Q03).
- PlayerData over ProfileStore (MISSING; R01's ReceiptLedger is PARTIAL for profile-backed games).
- Combat primitives Projectile and Hitbox (MISSING).
- Zones (MISSING).
- NPC NavAgent and BehaviorTree (MISSING).
- Starter dependency plumbing: the Wally allowlist, lock, notices, Rojo mapping and pins (MISSING).
- Blink in the starter (MISSING).
- Guard coverage for package-manager publish verbs (MISSING).
- Server Authority diagnostic fixture (MISSING).
- `roblox-gameplay-kit` skill and skill updates (MISSING).
- Agent-callable debug command registry: server-only, off in live servers by default, callable from `execute_luau` (MISSING; Cmdr stays REVISIT for a human console).

Together these move Q07 from PARTIAL towards VERIFIED_ACCEPTABLE.

## 10. UNVERIFIED

- Release years shown only on GitHub pages (†): Blink 0.18.9 and 1.0.0-pre.10 ("19 Sep"), ByteNet v0.4.3, Matter fork v0.8.5, Cmdr v1.13.1, SimplePath v2.2.1, ZonePlus v3.2.0 (year not known), GoodSignal v0.2.2 and Promise v4.0.0 ("March 3").
- jecs 0.11.0: npm says 2026-03-10; the GitHub release page reading said 2025-03-10.
- Who published the Wally scope `lm-loleris`. The official repo's `wally.toml` declares that name, but the DevForum thread credits a community member with the Wally package.
- Whether Wally accepts an exact requirement such as `@=1.0.3`, and whether `wally.lock` stores checksums. The plan relies only on the committed lockfile.
- Whether Rojo fails or skips a `$path` that does not exist yet (`Packages` before `wally install`). The starter only adds the mappings together with `--deps`.
- Whether a Linux binary of Blink is published for Rokit, and whether Blink's licence attaches to generated code.
- Whether luau-lsp now resolves types through Wally linker modules without `wally-package-types`, and that tool's current version.
- Lune loading of pure libraries (GoodSignal, LemonSignal, RbxUtil Signal, t, jecs). Which Roblox globals Lune 0.10.5 provides beyond its `@lune/*` libraries (for example a global `task` or `typeof` for Roblox datatypes) was not confirmed.
- pesde's publish and authentication command names.
- FastCast2's second licence ("ART"), Packet's licence name, ReplicaService's licence, and the missing licences of MuchachoHitbox and BehaviorTrees3.
- Whether `ProfileStore.Mock` touches DataStore APIs at all.
- The community rate-limiter repositories were seen only in search results.
- `TextChatCommand` execution context: the fetched page did not say where `Triggered` fires.

## 11. Sources (all fetched 2026-10-06)

- Registries:
  - `https://crates.io/api/v1/crates/<name>` for wally and pesde.
  - `https://api.wally.run/v1/package-metadata/<scope>/<name>` for evaera/promise, sleitnick/signal, sleitnick/trove, howmanysmall/janitor, osyrisrblx/t, csqrl/sift, sleitnick/knit, evaera/cmdr, ukendio/jecs, evaera/matter, data-oriented-house/lemonsignal, lm-loleris/profilestore, jsdotlua/jest, jsdotlua/jest-globals, roblox/signals and teamswordphin/shapecasthitbox. The lookups for ffrostfall/bytenet and 1foreverhd/zoneplus returned HTTP 500.
  - `https://registry.npmjs.org/-/v1/search?text=<query>` for jecs, @rbxts/jecs, @rbxts/t, @rbxts/janitor, @rbxts/cmdr, @rbxts/matter, @rbxts/lemon-signal, @quenty/maid and roblox-lua-promise; https://registry.npmjs.org/@rbxts/jecs/latest .
  - https://pesde.dev/packages/1axen/blink , https://pesde.dev/packages/marked/jecs .
- Package managers: https://github.com/UpliftGames/wally , https://raw.githubusercontent.com/UpliftGames/wally/main/README.md , https://github.com/UpliftGames/wally/blob/main/src/installation.rs , https://docs.pesde.dev/ , https://docs.pesde.dev/guides/roblox/ , https://docs.pesde.dev/guides/dependencies/ , https://github.com/pesde-pkg/scripts , https://github.com/JohnnyMorganz/wally-package-types
- Lune: https://lune-org.github.io/docs/ , https://lune-org.github.io/docs/the-book/7-modules/ , https://lune-org.github.io/docs/the-book/9-task-scheduler/ , https://lune-org.github.io/docs/roblox/4-api-status/
- Roblox docs (`https://create.roblox.com/docs/en-us/<path>.md`) for `projects/server-authority`, `projects/server-authority/techniques`, `scripting/events/remote`, `cloud-services/data-stores/best-practices`, `cloud-services/data-stores/error-codes-and-limits`, `cloud-services/data-stores/player-data-purchasing`, `reference/engine/classes/WorldRoot`, `characters/pathfinding`, `reference/engine/enums/SignalBehavior`, `reference/engine/libraries/buffer`, `reference/engine/classes/TextChatCommand` and `workspace/raycasting`; index https://create.roblox.com/docs/llms.txt
- DevForum: https://devforum.roblox.com/t/full-release-ship-fair-and-competitive-games-with-server-authority/4727993 , https://devforum.roblox.com/t/introducing-require-by-string/3405078 , https://devforum.roblox.com/t/profilestore-save-your-player-data-easy-datastore-module/3190543 , https://devforum.roblox.com/t/replica-server-to-client-state-replication-module/3216980 , https://devforum.roblox.com/t/packet-networking-library/3573907 , https://devforum.roblox.com/t/making-a-combat-game-with-ranged-weapons-fastcast-may-be-the-module-for-you/133474 , https://devforum.roblox.com/t/raycast-hitbox-401-for-all-your-melee-needs/374482 , https://devforum.roblox.com/t/muchachohitbox-an-easy-to-use-spatialquery-based-hitbox-system/3682320 , https://devforum.roblox.com/t/behaviortrees3-btrees-visual-editor-v30/836158
- Persistence: https://github.com/MadStudioRoblox/ProfileStore , https://github.com/MadStudioRoblox/ProfileStore/releases , https://raw.githubusercontent.com/MadStudioRoblox/ProfileStore/main/wally.toml , https://raw.githubusercontent.com/MadStudioRoblox/ProfileStore/main/LICENSE , https://madstudioroblox.github.io/ProfileStore/ , https://madstudioroblox.github.io/ProfileStore/api/ , https://github.com/MadStudioRoblox/ProfileService
- Async, signals and cleanup: https://github.com/evaera/roblox-lua-promise , https://github.com/evaera/roblox-lua-promise/releases , https://github.com/stravant/goodsignal , https://github.com/Data-Oriented-House/LemonSignal , https://github.com/Sleitnick/RbxUtil , https://github.com/Sleitnick/RbxUtil/releases , https://raw.githubusercontent.com/Sleitnick/RbxUtil/main/modules/signal/init.luau , https://raw.githubusercontent.com/Sleitnick/RbxUtil/main/modules/trove/init.luau , https://github.com/Roblox/signals , https://github.com/howmanysmall/Janitor
- Networking and replication: https://github.com/1Axen/blink , https://github.com/1Axen/blink/releases , https://github.com/1Axen/blink/releases/tag/v0.18.8 , https://github.com/1Axen/blink/releases/tag/v0.18.9 , https://github.com/1Axen/blink/blob/main/LICENSE , https://github.com/1Axen/blink/blob/main/rokit.toml , https://1axen.github.io/blink/ , https://1axen.github.io/blink/getting-started/1-installation , https://1axen.github.io/blink/language/4-types , https://github.com/red-blox/zap , https://github.com/red-blox/zap/releases , https://github.com/red-blox/zap/releases/tag/v0.6.29 , https://zap.redblox.dev/ , https://github.com/ffrostfall/ByteNet , https://github.com/ffrostfall/ByteNet/releases , https://raw.githubusercontent.com/ffrostfall/ByteNet/master/wally.toml , https://github.com/red-blox/Red , https://github.com/imezx/Warp , https://github.com/MadStudioRoblox/Replica
- Frameworks and ECS: https://github.com/Sleitnick/Knit , https://raw.githubusercontent.com/Sleitnick/Knit/main/ARCHIVAL.md , https://github.com/Ukendio/jecs , https://github.com/Ukendio/jecs/releases , https://raw.githubusercontent.com/Ukendio/jecs/main/README.md , https://raw.githubusercontent.com/Ukendio/jecs/main/wally.toml , https://github.com/evaera/matter , https://github.com/matter-ecs/matter
- Tooling libraries: https://github.com/evaera/Cmdr , https://github.com/evaera/Cmdr/releases , https://eryn.io/Cmdr/docs/hooks , https://github.com/osyrisrblx/t , https://github.com/osyrisrblx/t/releases , https://github.com/csqrl/sift
- Gameplay helpers: https://github.com/grayzcale/simplepath , https://github.com/grayzcale/simplepath/releases , https://github.com/1ForeverHD/ZonePlus , https://github.com/1ForeverHD/ZonePlus/releases , https://github.com/weenachuangkud/FastCast2 , https://github.com/TeamSwordphin/ShapecastHitbox , https://github.com/TeamSwordphin/ShapecastHitbox/releases , https://github.com/BusyCityGuy/finite-state-machine-luau
- Tried and unavailable: `https://github.com/EtiTheSpirit/FastCastAPI` (404), `https://github.com/Ukendio/jecs/tags` (robots.txt), `https://github.com/MadStudioRoblox/ProfileStore/tree/main/src` (robots.txt), `https://lune-org.github.io/docs/getting-started/4-modules` (404).
