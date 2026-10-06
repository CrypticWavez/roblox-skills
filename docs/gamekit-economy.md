# GameKit economy and progression kit

Usage guide and API reference for the G3 modules in [packages/GameKit](../packages/GameKit/). They cover the meta systems that collection, tycoon, idle, RPG, simulator, trading and roleplay games share: currencies, items, levels, objectives, streaks, odds, trades, plots, generators, crafting, schedules, season passes, followers, outfits, dialogue, onboarding and judging rounds.

The kit follows the frozen contract in [runtime-kits.md](runtime-kits.md): pure cores that run in Lune, thin `<Name>Roblox.luau` adapters, `env` as the last parameter, validators that return problem lists, and kit-event/1 events. Nothing here picks a genre, a theme, content or an economy number. Every default is a placeholder labelled as a convention in the code. A game supplies its own data and tunes its own numbers, and [EconomySim](#economysim) is the tool for that tuning.

## Modules at a glance

| Module | Tier | What it does | Saved data | Events (kit-event/1) |
|---|---|---|---|---|
| [Wallet](../packages/GameKit/Wallet.luau) | T0 | integer currencies with caps, floors, negatives, atomic multi-currency transactions, transaction-id dedupe | `wallet/1` | economy `wallet_credit` / `wallet_debit` |
| [EconomySim](../packages/GameKit/EconomySim.luau) | T0 | offline Monte Carlo of earn and spend curves (Lune only) | report `economy-sim/1` | none |
| [ItemDefs](../packages/GameKit/ItemDefs.luau) | T0 | validated, frozen item registry | none | none |
| [Inventory](../packages/GameKit/Inventory.luau) | T0 | stacks, instances with uids, equip slots, capacity, weight, atomic ops, quarantine | `inventory/1` | none (the caller reports) |
| [Progression](../packages/GameKit/Progression.luau) | T0 | XP curves (linear, power, table), levels, prestige, level rewards | `progression/1` | progression `level_up`, `prestige` |
| [Objectives](../packages/GameKit/Objectives.luau) | T0 | counters with filters, prerequisites, daily and weekly resets, claim once | `objectives/1` | progression `objective_complete`, custom `objective_claimed` |
| [Streaks](../packages/GameKit/Streaks.luau) | T0 | UTC day index, grace days, reset or decay, reward cycles | `streaks/1` | custom `streak_check_in` (or the streak's name) |
| [OddsTable](../packages/GameKit/OddsTable.luau) | T0 | weighted outcomes, exact disclosure, pity, paid-roll policy gate | none (pity is the caller's) | none |
| [Trade](../packages/GameKit/Trade.luau) | T0 | escrow state machine with two-phase commit, journal and the one-trade book | journal record per trade | economy (through Wallet), custom `trade_committed`, `trade_cancelled` |
| [Plots](../packages/GameKit/Plots.luau) | T0 | per-server plot claim and release, ordered, seeded or nearest assignment | none (per server) | none |
| [Generators](../packages/GameKit/Generators.luau) | T0 | idle production with storage caps and capped offline earnings | `generators/1` | none (credit through Wallet) |
| [Crafting](../packages/GameKit/Crafting.luau) | T0 | recipes, duplication-loop validation, atomic and timed crafts | `crafting/1` | economy (through Wallet) |
| [UnlockGraph](../packages/GameKit/UnlockGraph.luau) | T0 | tycoon buttons, skill trees and gates as a dependency graph, retry-safe payment | `unlocks/1` | progression `unlock` |
| [LiveOps](../packages/GameKit/LiveOps.luau) | T0 | UTC windows (one-off, daily, weekly, every n seconds) and seeded rotations | none | none |
| [SeasonTrack](../packages/GameKit/SeasonTrack.luau) | T0 | season tiers with free and premium tracks as flags, no prices | `season/1` | progression `season_tier`, custom `season_claim` |
| [Followers](../packages/GameKit/Followers.luau) | T0 | formation slots and a follow step with catch-up and teleport | none | none |
| [FollowersRoblox](../packages/GameKit/FollowersRoblox.luau) | T3 | AlignPosition and AlignOrientation driven from the step | none | none |
| [Outfits](../packages/GameKit/Outfits.luau) | T0 | `outfit/1` validation and HumanoidDescription plans | `outfit/1` | none |
| [OutfitsRoblox](../packages/GameKit/OutfitsRoblox.luau) | T3 | builds and applies HumanoidDescriptions | none | none |
| [Dialogue](../packages/GameKit/Dialogue.luau) | T0 | `dialogue/1` graphs, validation, sessions with conditions and effects | `dialogue-session/1` | none |
| [Onboarding](../packages/GameKit/Onboarding.luau) | T0 | step funnel on Fsm with resume after rejoin | `onboarding/1` | onboarding `onboarding_step`, custom `onboarding_complete`, `onboarding_skipped` |
| [VotingRound](../packages/GameKit/VotingRound.luau) | T0 | submissions, seeded ballots, no self votes, exact ranking and tie-breaks | none | none |

T3 means the adapter is proven only by a Studio probe that has not run yet (see [Probes](#probes-and-verification)). T0 modules run and are tested in Lune.

## Shared conventions

- **Integers for money and counts.** Amounts are integers checked with `Check.integer` (no fractions, at most 2^53). Validation also catches totals that would pass 2^53, for example cumulative XP.
- **Results, not exceptions.** Runtime operations return `(ok, reason, value)`. Reasons are short snake_case strings such as `insufficient_funds`, `at_cap`, `stale`, `store_failed`, `policy_denied` or `no_space`. Constructors and `define` raise with every problem listed. `validate` returns the list.
- **Injected interfaces.** Wallet, Inventory and Onboarding take a key store `{ get(key), set(key, value) }` and an events sink `{ emit(event) }`. Neither is required: without a store nothing persists, and without a sink nothing is reported. G1's PlayerData and Telemetry satisfy these interfaces. These modules never require them.
- **Policy fails closed.** Paid rolls and trades of paid items take `policyAllows`, either `true` or a predicate `(feature) -> boolean`. A missing predicate, an error, or anything other than `true` refuses. Features are `paidRandomItems` (OddsTable) and `trading` (Trade).
- **Server time.** Step functions take `env.clock()` time. Daily resets, offline earnings, live-ops windows and seasons take server UTC seconds as an explicit argument. Client clocks are never used.
- **Saved data is versioned and repaired.** Each `serialize()` returns a table with a `schema`. Loading repairs what it can and records a note for each repair in `.notes`. It never silently drops value: unknown inventory items go to a quarantine that serializes back.

## Persistence and anti-duplication

Duplication bugs come from three places: retries, partial writes and concurrent changes. The kit handles each the same way across modules:

1. **Two-phase commit.** `Wallet:prepare(changes)` and `Inventory:prepare(ops)` validate and return a transaction without changing anything. `commit(tx)` applies it, checking the version so a stale transaction is refused. `rollback(tx)` undoes a committed transaction. Trade, Crafting and UnlockGraph join several participants by preparing all of them first and then committing each. If any commit fails, the ones already committed roll back.
2. **Durable write before report.** After a commit, the module writes its store before it emits events. If the write raises, the in-memory state is restored and the call returns `store_failed`. An analytics event therefore never describes a change that was not saved.
3. **Idempotency keys.** Wallet remembers recent transaction ids (`ledgerSize`, a convention of 128), so a retried `transact(changes, { txId })` returns `(true, "duplicate")` and does nothing. UnlockGraph pays with the transaction id `unlock:<id>`. A request retried after a crash between the wallet write and the tracker save therefore unlocks without charging again. Trade writes a journal record `trade:<id>`, and a second commit, including one on a new trade object, returns `already_committed`.
4. **Save together.** Wallet and Inventory can share one store, so a game that keeps both in one session-locked document (G1 PlayerData) saves them as a unit. For cross-player trades, use `Trade` with a journal store plus each player's store.

The spec [gamekit_economy_trade.spec.luau](../tests/gamekit_economy_trade.spec.luau) runs a seeded 400-round fuzz with up to five open trades, injected store failures mid-commit and a check that each store agrees with memory. No item, uid or coin is created or lost.

## Wallet

```lua
local wallet = Wallet.new({
	currencies = {
		currency_a = {},                                  -- no cap, never negative
		currency_b = { cap = 1000, overflow = "clamp" },  -- the game's numbers, not ours
		currency_c = { allowNegative = true, floor = -50 },
	},
	sink = telemetrySink, player = tostring(userId), store = playerStore,
}, env)

wallet:credit("currency_a", 25, "Gameplay")              -- (ok, err, applied)
wallet:debit("currency_a", 10, "Shop", { sku = "item_a" })
wallet:transact({                                        -- all or nothing
	{ currency = "currency_a", delta = -40, reason = "Shop" },
	{ currency = "currency_b", delta = 5, reason = "Shop" },
}, { txId = "purchase:" .. receiptId })
```

- `reason` is a standard `Enum.AnalyticsEconomyTransactionType` name (`IAP`, `Shop`, `Gameplay`, `ContextualPurchase`, `TimedReward`, `Onboarding`) or a lower_snake label. It becomes the event's `transaction_type`.
- `overflow = "reject"` (the default) refuses a credit past the cap with `at_cap`. `"clamp"` applies what fits and reports the applied amount. At most five currencies report events, which is the kit-event/1 limit. Set `report = false` on the others.
- Also available: `balance`, `balances`, `has`, `canAfford(costs)`, `canTransact`, `seen(txId)`, `version`, `serialize()`, plus `prepare`, `commit`, `rollback` and `emit` for two-phase use. A rollback after events were emitted sends compensating events with `transaction_type = "rollback"`.

## EconomySim

An offline Monte Carlo that answers "how fast do players earn, what drains it, and how long until a milestone" before a game ships. Run it in Lune, in a spec or a tool, and never on a live server.

```lua
local report = EconomySim.run({
	seed = 1, players = 500,
	sessions = { count = 10, seconds = { min = 300, max = 1800 }, gap = { min = 3600, max = 86400 } },
	currencies = { currency_a = { initial = 0 }, currency_b = { cap = 500, overflow = "clamp" } },
	rates = { currency_a = 0.25 },                                  -- passive income per second
	offline = { currency_b = { perSecond = 0.01, capSeconds = 28800 } },
	actions = {
		{ id = "earn_a", every = { min = 20, max = 90 }, chance = 0.8, earn = { currency_a = { min = 1, max = 6 } } },
		{ id = "convert", every = 120, spend = { currency_a = 25 }, earn = { currency_b = 3 } },
	},
	milestones = { { id = "a_1000", currency = "currency_a", threshold = 1000, measure = "earned" } },
	targets = { currency_a = { sinkRatio = { min = 0.4, max = 0.9 } } },
})
for _, line in EconomySim.summary(report) do print(line) end
```

The report (`economy-sim/1`) contains the following.

- **Per currency:** sourced, sunk and wasted (lost to the cap) totals, a per-source and per-sink breakdown, the sink ratio (sunk / sourced), and percentiles (p10/p50/p90 by default, nearest rank) of end balance and of net change, earning and spending per play hour. Net change per hour is the inflation of the money a player holds. The report also has mean curves per session index.
- **Per action:** fired, blocked (with the reason: `needs`, `insufficient_funds`, `at_cap`), skipped by chance, and limited per session.
- **Per milestone:** the reached fraction and time-to-threshold percentiles in play seconds and in sessions. A percentile is absent when that share of players never reached the milestone.
- **Checks:** the caller's target bands, with `ok` for the whole report. Warnings list never-sourced currencies, currencies without sinks, waste at caps, actions that never fired and unreached milestones.

The same options give the same report. A work bound (`maxEvents`, a convention of 5,000,000) refuses runs that would take too long. The spec checks conservation (initial + sourced - sunk = end balances) and an exact closed-form case.

## Items and inventory

`ItemDefs.registry(defs)` validates `{ id, kind, stackable, maxStack, tags?, slot?, weight?, unique?, tradable? (default true), paid?, data? }` and freezes it.

`Inventory.new({ items, owner, capacity, maxWeight?, equipSlots?, store?, storeKey?, data? }, env)` holds one player's items:

- Stackable items fill existing stacks first. Non-stackable items are instances with uids `<owner>-<n>`, unique across players so traded items never collide, and optional plain data (at most 4 levels deep, a convention).
- `apply(ops)` is atomic. The ops are `add` (item and count, or an existing instance), `remove` (by item or uid, never equipped copies), `move`, `equip`, `unequip` and `set_data`. A failing op leaves everything untouched and returns the failing index.
- `equipSlots` is a list of slot names, where a slot takes items whose `def.slot` matches its name. It can also be a map `slot -> kind` for several slots of one kind, for example three follower slots: `{ follower_1 = "follower", follower_2 = "follower", follower_3 = "follower" }`.
- Paid copies (`paid = true` on the def or the op) never merge with earned ones, so trading rules can tell them apart. `count(item, paid?)` counts them separately.
- Capacity counts entries. Huge add counts are bounded before any loop runs.

## Progression, objectives and streaks

- `Progression.curve({ kind = "linear", base, step, maxLevel? })`, `{ kind = "power", base, exponent, maxLevel? }` or `{ kind = "table", requirements }` gives whole-number `xpToNext`, `totalFor` and `levelFor`. `Progression.new({ curve, path, rewards?, prestige?, sink, player, data }, env)` adds XP across several levels in one call. It emits one `level_up` event per gain and fires the `leveled` Signal with the rewards passed.
- `Objectives.define({ { id, counter, target, mode = "sum" | "max" | "latest", filter?, requires?, reset = "never" | "daily" | "weekly", reward? } })` refuses `requires` cycles. A tracker's `record(counter, amount, context)` returns newly completed ids. `claim(id)` returns the reward once, and `refresh(utc)` restarts daily and weekly objectives on UTC boundaries.
- `Streaks.dayIndex(utc, offset?)`, `weekIndex` (weeks start Monday) and `nextReset` are pure. A streak has `graceDays`, `onMiss = "reset" | "decay"`, `max` and a reward cycle. `checkIn(utc)` reports `started`, `continued`, `already`, `reset`, `decayed` or `clock_skew`.

## OddsTable and paid random items

Roblox's paid random items rules ([release-monetization research, section 1e](research/release-monetization-analytics-2026-10.md#1e-policyservice-and-community-standards-items-that-block-games)) require four things. Odds must be shown as percentages that sum to exactly 100% before purchase. Odds must update when an outcome can only be obtained once. Modifiers must be explained. A treatment is required where `ArePaidRandomItemsRestricted` is true. The table implements these rules:

```lua
local odds = OddsTable.new({
	{ id = "outcome_a", weight = 60 }, { id = "outcome_b", weight = 30 }, { id = "outcome_c", weight = 10, once = true },
}, Rng.new(seed), { name = "table_a", paid = true, pity = { threshold = 10, targets = { "outcome_c" } } })

local disclosure = odds:disclose({ owned = owned, pity = pityCount })  -- entries[i].text = "60.0000%"
-- allows: (feature) -> boolean from the game's policy layer (G1 PolicyGate), fail closed
local ok, result = odds:tryRoll({ policyAllows = allows, owned = owned, pity = pityCount })
if not ok then -- result is "policy_missing" / "policy_denied": apply the game's treatment
end
```

- Weights are integers. `disclose()` splits 1,000,000 units (0.0001% each) by the largest-remainder method, so the shown percentages sum to exactly 100.0000%. `validate` flags outcomes that would show as 0.0000%.
- A paid roll (`paid` on the table or `ctx.paid`) refuses unless `ctx.policyAllows` is `true` or a predicate that returns true for `paidRandomItems`. `roll()` raises and `tryRoll()` returns the reason.
- `once` outcomes drop out when owned, and `boost` factors and pity change rolls and disclosure identically, so the disclosure always matches the roll. The pity count is the caller's per-player data: it goes in as `ctx.pity` and comes out as `result.pity`.
- Draws are unbiased: rejection sampling on 32-bit integers, chi-square checked on 100,000 seeded rolls.

## Trade

`Trade.new({ id, a, b, countdown?, autoConfirm?, autoCommit?, expireSeconds?, currencies?, maxEntries?, journal?, sink }, env)`, where each party is `{ key, inventory, wallet?, policyAllows? }`.

- States: `proposed -> locked -> confirmed -> committed`, or `cancelled`. Any change to either offer clears both accepts and confirmations and unlocks a locked trade. `accept(side, revision)` must name the current revision, so a player cannot accept an offer they have not seen.
- Before locking, `accept` does a dry-run prepare of every participant, so a trade the receiver cannot hold (`no_space_b`) never locks. After both accept, `confirm` waits for the countdown (default 3 seconds, a convention).
- Paid items need both players' `trading` policy (G1 PolicyGate maps `IsPaidItemTradingAllowed`). The check runs again at commit. Equipped, untradable and missing items are refused.
- `Trade.book()` allows one open trade per player (`party_busy`).

## Plots, generators, crafting and unlock graphs

- `Plots.new({ plots = { { id, bounds = { min, max } } }, assign = "ordered" | "seeded" | "nearest", seed?, fallback? }, env)`. `claim(owner, preferred?, { near? })` resolves races in call order. Each owner gets one plot, and a repeated claim returns the same plot. Also available: `release`, `ownerOf`, `plotOf`, `at(position)` and `owns(owner, position)`.
- `Generators.new(defs, { offlineCap, offlineRate, maxStep, data })` with defs `{ id, currency, rate, storage?, maxCount? }`. `tick(now)` carries fractions so nothing is lost to rounding. `collect()` returns amounts to credit through Wallet, and `putBack` restores what the wallet refused. `markSeen(utc)` at save and `offline(utc)` at join credit `min(delta, offlineCap) * offlineRate` once. Clock skew gives nothing.
- `Crafting.new(recipes, { items, maxJobs, maxTimes, data })` with recipes `{ id, inputs, outputs, costs?, seconds? }`. `validate` refuses duplication loops: single-input, single-output conversions whose ratios multiply to more than 1 around a cycle. `craft` is instant and atomic over Inventory and Wallet. `start`, `complete` and `cancel` run timed jobs with refunds.
- `UnlockGraph.define({ { id, requires?, mode = "all" | "any", cost?, data? } })` refuses unknown requirements, cycles and nodes that can never unlock from the start nodes. `available()` lists what can be bought now in a stable topological order. `unlock(id, wallet)` pays atomically and is retry-safe. Loading keeps purchases even if requirements changed later, and records a note.

## LiveOps and SeasonTrack

- `LiveOps.define({ windows = { ... } })` takes one-off windows `{ id, start, ["end"], data? }` (UTC seconds or `"YYYY-MM-DDTHH:MM:SSZ"`) and recurring windows `{ id, every = "daily" | "weekly" | seconds, at = offset into the period, duration, from?, ["until"]?, data? }`. It gives `active(now)`, `isActive(id, now)` and `next(now)` on server UTC. Daily periods start at 00:00 UTC and weekly periods on Monday. `LiveOps.rotation(pool, { period, count, seed, offset }, now)` picks a seeded subset per period, such as a shop rotation, with the same result on every server. No events ship here.
- `SeasonTrack.define({ id, tiers = { { xp, free?, premium? } }, start?, ["end"]? })` refuses price keys on tiers. A pass counts XP only inside the window, claims each tier and track once, keeps premium claims retroactive, and starts fresh for a new season id. Premium is a flag the game sets from its own entitlement (G1 Commerce). It is not stored.

## Followers and FollowersRoblox

`Followers.new({ formation = "line" | "grid" | "arc" | "ring", spacing, distance, columns, arc, height, speed, catchUpDistance, catchUpMultiplier, teleportDistance, settleDistance, maxStep, maxFollowers })` takes distances in studs. The defaults are conventions, except `speed = 16`, the engine's default `Humanoid.WalkSpeed`.

- A follower keeps its slot until removed. The lowest free slot is reused, and `compact()` repacks the slots. Line and grid offsets depend on the slot alone. Arc and ring spread over the highest slot in use and grow their radius so neighbours stay `spacing` apart.
- The leader frame is `{ position, yaw? | lookVector? }`, where yaw is in degrees about +Y and yaw 0 faces -Z, the CFrame convention. `step(dt, leader)` never yields. It moves each follower toward its slot, faster beyond `catchUpDistance`, and snaps beyond `teleportDistance` or on first placement. It returns frames `{ id, slot, position, target, yaw, distance, teleported, catchingUp, settled }`.
- `FollowersRoblox.attach(part)` adds an Attachment, an AlignPosition and an AlignOrientation in OneAttachment mode. `start(core, handles, getLeader, env)` reads the parts back, steps the core and applies frames through `RunService:BindToSimulation`. Where that call is missing it falls back to `RunService.PreSimulation` and reports the fallback. Followers are usually cosmetic and created on the viewing client. The adapter does not set network owners.

## Outfits and OutfitsRoblox

An outfit (`outfit/1`) lists `accessories` (`Enum.AccessoryType` names with `id`, `layered?`, `order?`, `puffiness?`), `body` and `clothing` asset ids, where 0 means default. It also lists `animations`, `colors` (`"#RRGGBB"` or `{ r, g, b }`) and `scales`. Every section is optional, so a partial outfit patches the current look. The kit ships no asset ids.

- `Outfits.validate(outfit, rules?)` checks types, duplicate ids, color formats and scale ranges. The default ranges are the avatar editor ranges, a convention marked UNVERIFIED for any given experience setting. A game passes its own `rules.scales`, `maxAccessories`, `perType` limits and an `allow(kind, id)` predicate, for example "the player owns it".
- `Outfits.toDescription(outfit)` returns a plan of HumanoidDescription property values plus an accessory list for `SetAccessories(list, true)`. `fromDescription(snapshot)` maps back, and `merge(base, overlay)` puts a uniform over a player's own look, replacing accessories of the same type.
- `OutfitsRoblox.apply(humanoid, outfit, rules, env)` validates the outfit, patches `GetAppliedDescription()` and applies it with `ApplyDescriptionAsync` where the engine has it, otherwise `ApplyDescription`. It yields, so call it on the server for player characters. `read(humanoid)` returns the worn outfit.

## Dialogue, onboarding and voting rounds

- **Dialogue.** A `dialogue/1` graph is `{ schema, id, start, nodes = { [id] = { speaker?, textKey, choices? | next? | end?, effects? } } }`, with choices `{ id, textKey, to | end, conditions?, effects? }`. Text is always a localisation key. `validate(graph, kinds?)` uses ProcGen/Graph to find nodes unreachable from start, islands, non-end nodes without an exit, orphan choice targets, trap loops that cannot reach an end, and condition or effect kinds without a handler. `Dialogue.session(spec, { conditions, effects })` hides choices whose conditions fail; a raising handler counts as failed. It runs effects and resumes from saved data without running them again.
- **Onboarding.** `Onboarding.new({ steps, store, sink, player, allowSkipAhead? }, env)` runs the steps as an Fsm. `complete(step)` writes the store and only then emits the onboarding funnel event. After a rejoin it resumes at the first step not completed, and no step reports twice. There are at most 100 steps, the funnel limit.
- **VotingRound.** `VotingRound.new({ id, seed, scale?, tieBreak = "seeded" | "shared", votersMustSubmit?, allowRevote?, minVotes? }, env)` has the phases submitting, voting and closed. Ballots are seeded per voter and never include the voter's own entry. Votes refuse self votes, unknown entries, outsiders and scores off the integer scale (default 1..5, a convention). Ranking compares mean scores exactly as fractions, then vote counts, then a seeded order. With `"shared"`, tied entries share a rank. Entries under `minVotes` rank last, and `remove(player)` drops a player who left along with their entry and votes.

## Probes and verification

The two adapters and the engine-dependent behaviour are covered by four probes in the server registry [economy_probes.luau](../fixtures/kits/server/economy_probes.luau), with Studio runners in [tests/engine](../tests/engine/):

| Probe | Proves | Test mode |
|---|---|---|
| `economy_followers_formation` | constraints pull parts into formation; a far leader jump teleports; BindToSimulation present or fallback | play session on the server |
| `economy_outfits_apply` | scales and colors (no asset ids) applied to an R15 rig and read back; which apply method exists | play session on the server |
| `economy_plots_claim_race` | deferred claim threads racing for one plot resolve in call order | play session on the server |
| `economy_trade_two_client` | a trade between two real players in memory, the one-trade book, idempotent commit | Server and Clients with two clients |

In Lune the registry runs against FakeEnv and [FakeEconomyEngine](../tests/fakes/FakeEconomyEngine.luau) ([gamekit_economy_probes.spec.luau](../tests/gamekit_economy_probes.spec.luau)). That proves the wiring, not the engine. The probes stay pending, and FollowersRoblox and OutfitsRoblox stay T3, until a run on the unpublished diagnostic place prints their `ENGINE_DONE` lines.

Two seeded slices compose the kits end to end in [gamekit_slices_economy.spec.luau](../tests/gamekit_slices_economy.spec.luau). The first, `plot_generator`, covers plots, unlock buttons, generators, collection with putBack at a clamp cap, and capped offline earnings. The second, `collection_loop`, covers earning, an odds table with pity and disclosure, a paid roll refused without policy, several follower slots, selling when full, objectives, levels, a follower formation and a closing trade. Each run checks its invariants: balances equal the event ledger, no plot is shared, every unlock had its requirements met, pity holds, held items equal rolls minus sales plus trades, and the strict recorder accepted every event. The digests are stored in `tests/golden/gamekit-economy.json`.

```sh
lune run tests/run.luau gamekit_economy          # module specs
lune run tests/run.luau gamekit_slices_economy   # slices against the golden
FACTORY_UPDATE_GOLDEN=gamekit-economy lune run tests/run.luau gamekit_slices_economy  # intended changes only
```

## Conventions (not Roblox facts)

The code labels these defaults as conventions. A game should replace them with its own values:

- Wallet `ledgerSize` 128, Inventory data depth 4, and Crafting `maxJobs` 1 and `maxTimes` 100.
- Trade countdown of 3 s.
- Followers spacing, distance, columns, arc, catch-up and teleport distances, and `maxStep`. FollowersRoblox responsiveness and force.
- Outfit scale ranges (UNVERIFIED for any given experience).
- VotingRound scale 1..5.
- EconomySim step of 60 s and its work bound.

The facts the kit relies on are the kit-event/1 limits, the paid random items rules, `Enum.AccessoryType` names, HumanoidDescription property names and the default `WalkSpeed` of 16. The first two are cited in [runtime-kits.md](runtime-kits.md) and the research docs. The engine API names are checked by the T3 probes when they run.
