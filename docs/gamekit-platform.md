# GameKit platform services

Usage guide for the server-side platform modules in `packages/GameKit` and the commerce fixes in `packages/Runtime`. These modules are built to be copied into a game repository. They choose no genre, theme, prices or UI. Contracts shared with other kits (Env, kit-event/1, catalog/1, settings/1, tiers) are in [runtime-kits.md](runtime-kits.md).

Every module is a pure core (`<Name>.luau`, no Roblox globals, Lune-tested) or a thin engine adapter (`<Name>Roblox.luau`) with a tier label in its header:

| Tier | Meaning here |
|---|---|
| T0 | Pure logic, proven by Lune specs in this repo |
| T3 | Engine adapter with a named Studio probe; pending until the owner's run prints `ENGINE_DONE` |
| T4 | Needs a published experience or live service (DataStores, MemoryStore, ConfigService, real text filtering, teleports, analytics delivery, purchases, bans). Never claimed as verified here |

A T3 or T4 adapter's wiring is still exercised in Lune against the fakes in `tests/fakes/`. That proves the logic and the call shapes, not the engine.

## Module map

| Area | Module | Tier | Proven by |
|---|---|---|---|
| Remotes | [RateLimit](../packages/GameKit/RateLimit.luau), [Schema](../packages/GameKit/Schema.luau), [RemoteGuard](../packages/GameKit/RemoteGuard.luau) | T0 | `tests/gamekit_platform_remotes.spec.luau` |
| | [RemoteGuardRoblox](../packages/GameKit/RemoteGuardRoblox.luau) | T3, probe `platform_remoteguard_flood` | same spec, probes spec |
| Player data | [PlayerData](../packages/GameKit/PlayerData.luau) | T0 (real DataStore and ProfileStore sessions T4) | `tests/gamekit_platform_data.spec.luau` |
| | [PlayerDataRoblox](../packages/GameKit/PlayerDataRoblox.luau) | T3, probe `platform_playerdata_memory` | same spec, probes spec |
| | [SettingsStore](../packages/GameKit/SettingsStore.luau) | T0 | `tests/gamekit_platform_settings.spec.luau` |
| Telemetry | [Telemetry](../packages/GameKit/Telemetry.luau) | T0 | `tests/gamekit_platform_telemetry.spec.luau` |
| | [TelemetryRoblox](../packages/GameKit/TelemetryRoblox.luau) | T3, probe `platform_telemetry_recorder` (live sending T4) | same spec, probes spec |
| | [analytics_report.py](../tools/analytics_report.py) | offline tool | `tests/test_analytics_report.py` |
| Live config | [Config](../packages/GameKit/Config.luau) | T0 | `tests/gamekit_platform_config.spec.luau` |
| | [ConfigRoblox](../packages/GameKit/ConfigRoblox.luau) | T4 | same spec |
| Policy and text | [PolicyGate](../packages/GameKit/PolicyGate.luau), [TextFilter](../packages/GameKit/TextFilter.luau) | T0 | `tests/gamekit_platform_policy.spec.luau` |
| | [PolicyGateRoblox](../packages/GameKit/PolicyGateRoblox.luau) | T3, probe `platform_policy_emulator` | same spec, probes spec |
| | [TextFilterRoblox](../packages/GameKit/TextFilterRoblox.luau) | T4 | policy spec |
| Commerce | [Commerce](../packages/GameKit/Commerce.luau) | T0 | `tests/gamekit_platform_commerce.spec.luau` |
| | [CommerceRoblox](../packages/GameKit/CommerceRoblox.luau) | T4 | same spec |
| | [Runtime/CommerceCatalog](../packages/Runtime/CommerceCatalog.luau), [Runtime/ReceiptLedger](../packages/Runtime/ReceiptLedger.luau) | T0 | commerce spec, `tests/runtime/run.luau`, `tests/inherited.spec.luau` |
| | [Runtime/RobloxReceiptAdapter](../packages/Runtime/RobloxReceiptAdapter.luau) | T4 | commerce spec |
| Matchmaking | [Queue](../packages/GameKit/Queue.luau) | T0 | `tests/gamekit_platform_queue.spec.luau`, golden `gamekit_platform_queue` |
| | [MemoryQueueRoblox](../packages/GameKit/MemoryQueueRoblox.luau), [TeleportRoblox](../packages/GameKit/TeleportRoblox.luau) | T4 | queue spec |
| | [PartyRoblox](../packages/GameKit/PartyRoblox.luau) | T3, probe `platform_party_simulator` | queue spec, probes spec |
| Moderation | [Moderation](../packages/GameKit/Moderation.luau) | T0 | `tests/gamekit_platform_policy.spec.luau` |
| | [ModerationRoblox](../packages/GameKit/ModerationRoblox.luau) | T4, owner-run only | policy spec |

## Server wiring at a glance

A sketch of one game server script, in order. Names such as `currency_a` and `primary_button` are placeholders; the game chooses its own.

```lua
local GameKit = game:GetService("ReplicatedStorage").Packages.GameKit
local Env = require(GameKit.Env)
local env = Env.studio() -- EnvRoblox: task.*, time(), GetService; also correct on live servers

-- 1. Player data: memory in Studio, DataStores or an injected ProfileStore live.
local backend = PlayerDataRoblox.chooseBackend({ storeName = "player_data", kind = "auto", profileStore = ProfileStore }, env)
local store = PlayerData.new({ template = { currencies = {}, settings = {} }, version = 1, backend = backend }, env)
local data = PlayerDataRoblox.bind(store, { game = game }, env)

-- 2. Telemetry: recorder in Studio, AnalyticsService on a published server.
local sink, envelope = TelemetryRoblox.forPlace(env, { catalog = analyticsCatalog })
local telemetry = Telemetry.new({ sink = sink, envelope = envelope, catalog = analyticsCatalog }, env)

-- 3. Policy, then remotes behind a guard.
local policy = PolicyGateRoblox.gate(env)
local stopPolicy = PolicyGateRoblox.bind(policy, env.services.Players, env)
local guard = RemoteGuard.new({ schemas = remoteSchemas, telemetry = telemetry }, env)
RemoteGuardRoblox.build(remotesFolder, guard, env.roblox)
RemoteGuardRoblox.bind(remotesFolder, guard, handlers, { players = env.services.Players })

-- 4. Commerce: one receipt handler per server, granting through the player's session.
local process = Commerce.receiptProcessor({
	catalog = catalog,
	sessionFor = function(userId) return store:get(userId) end,
	grant = function(draft, product) writeGrants(draft, product) end,
}, env)
CommerceRoblox.bindReceipts(env.services.MarketplaceService, process, Enum)
```

Each step is described below with its failure behaviour.

## Remotes: RateLimit, Schema, RemoteGuard, RemoteGuardRoblox

`RateLimit.new({ capacity, refillPerSec, maxKeys? }, env)` keeps a token bucket per key. `take(key, cost?)` returns `(ok, retryAfter)`. Time comes from the server clock, never from the client. A clock that runs backwards refills nothing. Memory is bounded: past `maxKeys`, full buckets are dropped first, then the least recently used.

`Schema` builds validators for untrusted values: `number`, `integer`, `string`, `boolean`, `literal`, `enum`, `vector3`, `cframe`, `instanceOf`, `optional`, `struct`, `array`, `map`, `union`, `custom`, `any`. `Schema.check(schema, value)` returns `(ok, path, reason)`, for example `false, "args[2]", "not_finite"`. NaN and infinity are always rejected, strings must be valid UTF-8, and depth and node budgets bound the work a hostile payload can cause. `Schema.storable` and `Schema.size` check DataStore-safe plain data.

`RemoteGuard.new({ schemas, rateLimit?, telemetry?, onReject?, abuse? }, env)` declares every client-to-server remote by name:

```lua
local guard = RemoteGuard.new({
	schemas = {
		settings_patch = { args = { SettingsStore.patchSchema() }, rate = { capacity = 5, refillPerSec = 1 } },
		primary_button = { kind = "function", args = { Schema.string({ maxLen = 32 }) } },
		aim_update = { kind = "unreliable", args = { Schema.vector3({ maxMagnitude = 2048 }) } },
		claim_reward = { args = { Schema.string({ maxLen = 40 }) }, dedupe = { arg = 1 } },
	},
	telemetry = telemetry,
}, env)
```

`guard:wrap(name, handler)` returns the function to connect. Calls are checked cheapest first: `invalid_player`, `unknown_remote`, `rate`, `arity`, `schema`, `duplicate`, `unauthorized`. A rejected call never reaches the handler, never raises and never yields. Handler errors are caught (`handler_error`) and reported, never sent to the client. `guard:stats(player?)` gives accept and reject counts; the `abuse` option calls `onAbuse` after many rejects in a window.

`RemoteGuardRoblox.build(folder, guard, roblox)` creates missing remotes of the right class. `bind(folder, guard, handlers, { players })` connects them and fails closed: it raises when the folder holds a remote with no schema, when a schema has no remote or handler, or when a remote's class does not match its kind. `plan()` is the pure version, tested in Lune.

## Player data: PlayerData, PlayerDataRoblox, SettingsStore

`PlayerData.new(options, env)` is a session-locked store. One server owns a player's data at a time, and every change goes through `session:update(fn)`:

```lua
local ok, reason, detail = session:update(function(data)
	data.currencies.currency_a = (data.currencies.currency_a or 0) + 10
end)
```

`fn` runs on a copy. The result is committed only if it is storable, passes `options.schema` and fits the size budget, so a failed update never touches live data. Other session methods: `get(path)`, `set(path, value)`, `keyStore(prefix)` (the get/set interface other kits take), `hasReceipt`, `grantReceipt`, `save`, `saveAsync`, `release`, `isActive`, plus the `onSessionLost` and `changed` signals.

Options: `template` (reconciled into loaded data), `version` with `migrations[n]` (from version n to n+1), `backend`, `schema?`, `sizeBudget?` (default 4,000,000 characters, under Roblox's 4,194,304 limit), `receiptRing?` (100), `autosave?` (180 s with jitter, as in Roblox's reference architecture) and `closeDeadline?` (25 s, inside the 30 s BindToClose window).

Backends:

- `memoryBackend()`: Lune and Studio without DataStores.
- `dataStoreBackend(dataStore, opts, env)`: Roblox's documented lock-in-metadata pattern over `UpdateAsync`, with a serial save queue and a lock timeout.
- `profileStoreBackend(ProfileStore, storeName)`: ProfileStore 1.0.3, injected by the game (`require` of the game's own copy). It is never vendored or required here. ProfileStore manages its own autosave and resolves session conflicts; `Steal` is never used.

`store:load(userId, { cancel })` refuses with a closed reason (`locked`, `corrupt`, `newer_schema`, `migration_failed`, `too_large`, ...) and leaves stored data untouched. A newer schema is never downgraded.

`PlayerDataRoblox.chooseBackend({ storeName, kind, profileStore, allowStudioDataStores, ... }, env)` picks storage: memory in Studio unless DataStores are explicitly allowed. `PlayerDataRoblox.bind(store, { game, kickOnFailure?, kickMessage? }, env)` loads on join, releases on leave, kicks a player whose data could not load or whose session was lost, runs autosave and flushes in `BindToClose`. It returns `loaded` and `failed` signals, `sessionFor(player)`, `waitForSession(player, timeout?)` and `unbind()`.

`PlayerData.eraseKeys(userId, stores)` lists the DataStore keys holding a user's data, for the owner's manual handling of an erasure request. It deletes nothing.

`SettingsStore.new({ store = session:keyStore(), key?, schema?, migrations?, rate? }, env)` persists one player's settings/1 values. `load()` migrates whatever was saved and writes the clean result back once. `apply(patch)` takes a client's partial change, sanitizes it with `Settings.merge`, rate-limits it and saves only on change. It returns `(ok, values | reason, notes)` with reasons `rate`, `invalid_patch` and `store_failed:<why>`. `SettingsStore.patchSchema()` is the RemoteGuard schema for the settings remote.

## Telemetry: Telemetry, TelemetryRoblox, analytics_report.py

`Telemetry.new({ sink, catalog?, envelope?, budget?, strict? }, env)` validates kit-event/1 events and checks them against AnalyticsService limits before Roblox would silently bucket them as "Other": 100 custom names, 10 funnels of 100 steps, the 10 most recent funnel sessions per player and funnel, 5 currencies, 20 transaction types and 3 custom fields. It also checks funnel and onboarding step order and an optional declared catalog. Rejects return `(false, reason)` and are counted; analytics never breaks gameplay.

```lua
telemetry:economy(player, "source", "currency_a", 100, newBalance, "IAP", "currency_pack_a")
local sessionId = telemetry:funnelStart(player, "funnel_a")
telemetry:funnelStep(player, "funnel_a", sessionId, "step_b")
telemetry:progression(player, "path_a", "complete", 3)
telemetry:purchase(player, "prompted", "currency_pack_a", "devproduct", "shop")
```

Emit economy events after the durable write (from `onResult` of a receipt, not inside an update function).

`TelemetryRoblox.forPlace(env, { catalog })` returns the recorder sink in Studio and the live sink on a published server. It raises on a client. The live sink maps events to `AnalyticsService:Log*Event` in documented argument order and never sends synthetic events. Delivery is T4: Roblox accepts events only from published servers, and dashboards lag up to 24 hours. The recorder prints `TELEMETRY_JSON <kit-event/1 line>` per event.

`tools/analytics_report.py` reads exported JSONL offline:

```
python3 tools/analytics_report.py events.jsonl --out build/report.json
python3 tools/analytics_report.py studio_console.txt --console      # TELEMETRY_JSON lines only
python3 tools/analytics_report.py fixtures/analytics/neutral_events.jsonl --start 2026-10-05T12:00:00Z --end 2026-10-05T12:10:00Z
```

Kit-event input gives funnel and onboarding conversion, economy sources and sinks per currency, progression drop-off and purchase-intent stages. Legacy session rows give per-cohort session metrics inside an explicit window. Synthetic, Lune, Studio and test traffic is excluded by default. Exit code 2 means bad input.

## Live config: Config, ConfigRoblox

`Config.new({ defaults, schema? })` declares every tunable up front. `get(key)` always returns a valid value and raises on an undeclared key (a typo fails in tests, not in production). `apply(values, source)` takes valid values, falls back to the default per key for invalid or missing values, returns notes and fires `changed(key, value, previous)`.

`ConfigRoblox.load(config, ConfigService, { player?, timeout = 10 }, env)` reads `GetConfigAsync` (or `GetConfigForPlayerAsync` for experiment values) with a timeout. On any error the defaults stay. It follows `UpdateAvailable` with `Refresh`, so a published kill switch reaches running servers. It returns `{ ok, reason, notes, refresh, disconnect }`, where reason is `no_service`, `timeout`, `error` or `partial`. Publishing a config is a production change and owner-only.

## Policy and text: PolicyGate, PolicyGateRoblox, TextFilter, TextFilterRoblox

`PolicyGate.evaluate(info, feature)` answers `(allowed, reason)` from a `GetPolicyInfoForPlayerAsync` result. A feature is allowed only when its field holds exactly the permitting boolean. Anything else fails closed: a missing or wrong-typed field, an unknown feature, or no info. Features are `paidRandomItems`, `trading`, `ads`, `subscriptions`, `commerceProducts`, `contentSharing`, `voice`, plus `externalLinks` and `socialLinks`, which are always false in game.

`PolicyGate.new({ fetch, retry?, negativeTtl? }, env)` caches one info table per player. `load(player)` yields, and concurrent loads share one fetch. `allows(player, feature)` and `predicate(player)` never yield and say no until a load succeeded. `PolicyGateRoblox.gate(env)` builds a gate on PolicyService and VoiceChatService. `bind(gate, Players, env)` loads on join and forgets on leave.

`TextFilter.new({ filter, maxLength = 200, allowNewlines?, rate? }, env)` is the path for player-written text others will see (names, signs, notes). `submit(player, text, audience)` runs type and UTF-8 checks and strips control, bidi and zero-width characters. It then trims, checks length and rate, and filters. It returns `(true, filtered)` or `(false, "", reason)`, so callers display nothing on failure. Use `filter(text, authorId, audience)` again when stored text is shown to a different audience. `TextFilterRoblox.backend(TextService, { context })` calls `FilterStringAsync` and then the broadcast or per-user variant. Whether filtering changes text in Studio is unverified, which is why it is T4.

## Commerce: Commerce, CommerceRoblox and the Runtime modules

Products are a catalog/1 table ([runtime-kits.md](runtime-kits.md) section 9.3, `GameKit/Catalog`). Prices are never data: regional pricing and Managed Pricing change them, so they are read at runtime.

`Commerce.canPrompt(catalog, key, { policy, owned, isStudio })` returns `(true, nil, product)` or `(false, reason, detail)`, with reasons in order:

1. `invalid_catalog`
2. `unknown_product`
3. `setup_mode` (setup catalogs sell nothing)
4. `disabled`
5. `policy_unknown`
6. `policy_denied` (detail: the feature)
7. `already_owned`
8. `studio_subscription`

Subscriptions need PolicyGate `subscriptions`. Products tagged `paid_random_item` need `paidRandomItems`. Pass `policy = gate:predicate(player)`; with no predicate, a product that needs one is refused. A subscription prompt in Studio can take the real payment path, so a subscription opens only when `isStudio` is `false` (a known live place); a missing `isStudio` counts as Studio and is refused with `studio_subscription`.

`CommerceRoblox.prompt(MarketplaceService, catalog, key, player, { policy = gate:predicate(player) }, env)` runs `canPrompt` and then the matching `Prompt*Purchase`. `isStudio` comes from `ctx.isStudio`, then `ctx.place.isStudio`, then `env.place.isStudio` (EnvRoblox reads RunService); with none of them a subscription is refused. A prompt only asks; nothing is granted from prompt events.

Prices for UI: `CommerceRoblox.priceProvider(MarketplaceService, { ttl?, retryAfter?, format? }, env)` returns a provider. `provider:price(product)` never yields and returns `{ state = "ok" | "pending" | "unavailable", text?, robux?, reason? }`. A missing or stale price starts one background read (`GetProductInfoAsync` with `InfoType.Product` or `GamePass`, or `GetSubscriptionProductInfoAsync` for its `DisplayPrice`). `provider.changed` fires `(productKey, info)`. A failed re-read keeps the last good price. Placeholder ids never fetch. Run the provider on the client, where the price is shown, and never trust a price sent to the server.

Ownership: `CommerceRoblox.ownership(MarketplaceService, opts, env)` wraps `UserOwnsGamePassAsync` and `GetUserSubscriptionStatusAsync` with retries in a shared cache. `owns(player, product)` yields and returns `owned`, `not_owned` or `unknown`; `unknown` means benefits stay off. `peek` never yields. Owned passes stay cached for the session. Subscriptions are re-checked after 60 s and never stored as permanent. Use `markOwned` after a confirmed server-side pass purchase and `invalidate` on a subscription status change. `CommerceRoblox.priceLevels(MarketplaceService, userIds)` reads `GetUsersPriceLevelsAsync` fresh every call; call it at join for trade and gift caps.

Receipts have two paths. Bind exactly one developer-product receipt handler per server.

- **Profile-backed (with PlayerData).** `Commerce.receiptProcessor({ catalog, sessionFor, grant, onResult? }, env)` grants through `session:grantReceipt`, whose purchase-id ring makes a re-delivered receipt grant once. It answers `granted` only after a durable save. `CommerceRoblox.bindReceipts(MarketplaceService, process, Enum)` binds it with `BindReceiptHandler(Enum.ReceiptType.DeveloperProduct, ...)` and maps `granted` to `Enum.ReceiptDecision.Processed`; anything else is `NotProcessedYet`, and Roblox delivers again later. A product disabled after purchase still grants, because the player paid. A live Wallet or Inventory over the same session keeps its own copy of the state: call `wallet:reload()` and `inventory:reload()` from `onResult` when the status is `granted`, before anything else writes, or the next commit writes the old balance back over the grant (`tests/slices_integration.spec.luau`, session_persistence). Setup catalogs and unknown products never grant. `Commerce.grantWriter({ currency, item, entitlement, custom })` turns catalog grants into one update function; a grant with no writer fails the update, so nothing is half-granted.
- **Separate ledger key.** `Runtime/ReceiptLedger.new({ store, namespace, universeId, products, maxReceipts?, minRetentionDays?, now? })` records grants in its own `UpdateAsync` transform and does not need the player online. `Runtime/RobloxReceiptAdapter.bind(MarketplaceService, ledger, onResult?, enums?)` binds it the same way. `Adapter.callback` remains for the legacy `ProcessReceipt` path, which still receives receipts no bound handler claims.

Ledger retention: every receipt stores `at` (unix seconds). Receipts older than `minRetentionDays` are pruned on the next grant. The default of 30 days is a convention; how long Roblox re-delivers an unacknowledged receipt is unverified. `receipt_capacity_requires_migration` is returned only when receipts inside the window fill `maxReceipts`. In-window dedupe is never given up to admit a new receipt. Receipts saved before retention existed are stamped on first touch and kept a full window.

`Runtime/CommerceCatalog.fromCatalog(universeId, catalog, platform)` gives the inherited display and entitlement API over a catalog/1 table. Display states are:

- `available` (game mode, enabled, owner-verified);
- `preview_only` (`setup_mode`, `disabled` or `ownership_unverified`);
- `unavailable` (`unconfigured`, `placeholder` or `platform_info_unavailable`).

`validateEntry(entry, mode)` lists problems with a legacy entry. Legacy entries may spell the id `productId` (the inherited Creator shop's spelling); `id` and `productId` must agree. `CommerceRoblox.platform(MarketplaceService, Enum)` provides the `platform` seam.

## Matchmaking: Queue, MemoryQueueRoblox, TeleportRoblox, PartyRoblox

`Queue.new({ teams = 2, teamSize = 4, maxPartySize?, skill?, partial?, expireAfter?, maxTickets? }, env)` is a pure queue of tickets `{ id, players = { userIds }, skill?, pool?, at? }`. `plan(now)` returns `{ matches, expired, waiting }` without changing the queue, and `take(now)` commits it:

- A party is never split across teams or matches.
- The oldest ticket anchors a match. Others join oldest first while their skill is within the anchor's band. The band starts at `skill.initial` and widens by `skill.widenPerSecond` up to `skill.max`; the defaults 100, 10 and 1000 are conventions. `skill = false` ignores skill.
- Parties go to teams largest first, each to the team with the most free slots; ties go to the lower skill total, which balances teams.
- With `partial = { after, minPlayers, maxImbalance = 1 }`, an anchor that waited `after` seconds may start a smaller match. Every team must be non-empty and team sizes may differ by at most `maxImbalance`.
- `pool` labels keep modes or regions apart. `expireAfter` drops old tickets into `plan.expired`.
- Plans are deterministic: same tickets, same time, same plan. There is no randomness, and order is by time, then id. The golden `tests/golden/gamekit_platform_queue.json` pins a seeded 180 s simulation.

Greedy selection can miss an exact fill another choice would find; those tickets wait for the next plan. Cost is about O(tickets^2) per plan, so plan every few seconds rather than every frame. Each match carries `id = "match:<anchor ticket>"`, `teams[i].players`, `tickets`, `partial`, `spread` and `waited`.

`MemoryQueueRoblox.new(MemoryStoreService, { name, invisibility = 30, expiration = 600, batch = 100 }, env)` shares tickets between servers through a MemoryStoreQueue. Lobby servers `push(ticket)`. The matchmaking server calls `cycle(queueOptions, onMatch)`:

1. Read a batch.
2. Plan it with Queue. Invalid and duplicate tickets are dropped and reported.
3. Call `onMatch(match)`, which yields and returns true once launched.
4. Remove the batch.
5. Push back every ticket not launched, with its original time.

A failed remove pushes nothing back; the batch reappears after the invisibility timeout. Delivery is at least once. Lobbies should keep their tickets and re-push those with no result after `expiration`, and `onMatch` must claim each ticket atomically (for example `MemoryStoreHashMap:UpdateAsync` on the ticket id) so a duplicate is skipped.

`TeleportRoblox.options(roblox, { reserve | accessCode | serverInstanceId, data? })` builds `TeleportOptions`. `teleport(TeleportService, placeId, players, options, env)` retries a raising `TeleportAsync` and returns `(true, result)` or `(false, "studio" | "invalid" | "failed", detail)`. `reserve(TeleportService, placeId, env)` wraps `ReserveServer`. `bindRetry(TeleportService, env, { maxRetries = 3, onGiveUp })` handles `TeleportInitFailed`: Flooded is retried after 15 s and Failure after 1 s, the delays from Roblox's teleport guide. Other results give up. Teleports refuse in Studio, where Roblox does not support them. Teleport data passes through the client, so record match membership server-side and check it on arrival.

`PartyRoblox.ticket(SocialService, player, { skillOf?, pool?, maxPartySize? })` turns the player's Roblox party members in this server into one ticket (`party:<PartyId>`), or a solo ticket. `members(SocialService, partyId, env)` lists every member through `GetPartyAsync`. `bind(queue, Players, { onRemoved })` removes a ticket when a member leaves or their `PartyId` changes, so a party re-queues as it now is. PartyId groups players; it is not an authority, and the server still caps sizes.

## Moderation: Moderation, ModerationRoblox

`Moderation.banRequest({ userIds, duration, displayReason, privateReason?, applyToUniverse?, excludeAltAccounts? })` validates a ban and returns the `Players:BanAsync` config, or `nil, problems`. The limits it enforces (50 users, 400 and 1000 characters) are recalled from the class reference and unverified. `Moderation.ladder(steps)` validates a game-supplied escalation ladder of `{ after, action = "warn" | "kick" | "ban", duration? }`, and `decide(ladder, offenses)` picks the step. The factory ships no ladder and no durations; those are the owner's policy.

`ModerationRoblox.ban(Players, request, { place, confirm = ModerationRoblox.CONFIRM })` refuses in Studio, without a place, or without the confirm token. Bans act on real accounts: owner-run in a live game only, never by agents.

## Testing

- Specs: `lune run tests/run.luau gamekit_platform` runs every G1 spec. The runtime suite is `lune run tests/runtime/run.luau` (writes `build/runtime_status.json`), and `python3 -m unittest tests/test_analytics_report.py` covers the report tool.
- Fakes in `tests/fakes/` (G1): FakeDataStore, FakeProfileStore (ProfileStore 1.0.3 API, session handoff and blocking conflicts), FakeAnalytics, FakePolicy (region presets), FakeConfig, FakeTextService, FakeMarketplace, FakeMemoryStore, and FakePlatformRoblox (Instances, signals, Players, SocialService, TeleportService, `game`). FakeEnv is Stage 0's: its `spawn` runs at once, `wait` parks until `advance`, and errors and reports are collected.
- Goldens: `gamekit_platform_telemetry_calls` and `gamekit_platform_queue`, plus the byte-checked `fixtures/analytics/kit_events.jsonl` (`gamekit_platform_kit_events`). Update one deliberately with `FACTORY_UPDATE_GOLDEN=<name> lune run tests/run.luau <spec>` and explain the change.
- Mutation checks: the specs were checked by mutating guard conditions in each module and confirming a test fails. The survivors left are equivalent mutants, such as a capacity pre-check that packing already enforces.

## Studio probes (owner steps)

Build the kits place with `rojo build fixtures/kits.project.json -o build/kits.rbxl` and open it as an unpublished place. Every probe refuses on a published place. Run each entry from `tests/engine/` on the server of a play session; each prints `ENGINE_CHECK` lines and one `ENGINE_DONE`:

| Probe | Session | Needs |
|---|---|---|
| `platform_remoteguard_flood` | Play | one player |
| `platform_playerdata_memory` | Play | one player (memory backend; no DataStores) |
| `platform_telemetry_recorder` | Play | nothing; prints `TELEMETRY_JSON` lines for `analytics_report.py --console` |
| `platform_policy_emulator` | Play, once per Player Emulator region | Test > Player Emulator > Enable Test Profile |
| `platform_party_simulator` | Server & Clients, two or more clients | the clients placed in one party with the Party Simulator (beta) |

The flood probe calls the bound handlers directly with a real Player and removes its remotes when it ends. To see the guard against real network delivery, run Server & Clients. On the server, bind a guard as in the wiring sketch, for example a folder `GuardTest` in ReplicatedStorage with an event `probe_flood` whose only argument is `Schema.vector3({ maxMagnitude = 1000 })` at `{ capacity = 10, refillPerSec = 0 }`. Then, in a client's command bar:

```lua
local remote = game:GetService("ReplicatedStorage"):WaitForChild("GuardTest"):WaitForChild("probe_flood")
for _ = 1, 1000 do remote:FireServer(Vector3.new(0 / 0, 0, 0)) end
```

The server's `guard:stats(player)` should show no accepted calls, 10 `schema` rejects (the first calls, which got a token) and `rate` rejects for every later call that arrived. Rate is checked first, so a flood spends its own budget. Roblox's own per-remote throttling may drop some calls before they reach the server. Remove the folder afterwards.

## Conventions and Roblox numbers

Roblox numbers: 180 s autosave with jitter, 30 s BindToClose, 4,194,304-character values, 50-character keys, AnalyticsService limits, 100 items per MemoryStore read, 45-day queue expiration, and the 15 s and 1 s teleport retry delays.

Conventions (not Roblox numbers):

- RateLimit and RemoteGuard defaults;
- the 25 s close deadline;
- the 200-codepoint text limit;
- PolicyGate's 30 s negative cache;
- the 60 s price, subscription and not-owned TTLs and the 30 s retry and unknown TTLs;
- the 30-day receipt retention;
- the Queue skill band defaults;
- the 600 s ticket expiration;
- three teleport init retries.

Each is labelled where it is defined.

## Owner-only actions

Nothing here publishes, uploads, buys or spends. The following happen only in a game repository, by the owner, on a published experience:

- real purchases and prompts;
- DataStore and ProfileStore sessions on live data;
- MemoryStore queues;
- teleports;
- ConfigService publishes;
- AnalyticsService delivery;
- bans.

The `tools/hooks` guards ask or deny on purchase prompts, DataStore and MemoryStore writes and publishing in agent sessions, including calls through these adapters (`CommerceRoblox.prompt`, LeaderboardRoblox `submit`/`remove` or `writes = true`, LiveBoardRoblox, MemoryQueueRoblox `push`/`ack`/`cycle`, the PlayerData DataStore and ProfileStore backends, `allowStudioDataStores`). They match the code as text, so an adapter required under another name, or a module already in the place that makes the call, is not seen ([mcp.md](mcp.md), Safety gates).
