# Playbook: Live-ops events, rotating shop and season tracks (cross-cutting)

Kind: cross-cutting

A neutral systems reference for any genre with timed content: it maps events, rotations and season tracks to kit modules, risks and checks. It picks no event, offer, price or reward; every TBD belongs to the game's owner.

## Core loop as systems
- **Calendar**: events and rotations with UTC start and end times; the server decides what is active.
- **Event progress**: event objectives, event currency, event rewards, cleanup when the event ends.
- **Rotating shop**: a set of offers that changes on a schedule, the same for everyone or per player (seeded).
- **Season track**: tiers earned by progress, with free and premium tracks as flags.
- **Live configuration**: values changed without a new publish (ConfigService).

## Kit modules
- `GameKit/LiveOps`: timed windows, rotations and event state from explicit UTC inputs.
- `GameKit/SeasonTrack`: season tiers with free and premium flags (no prices).
- `GameKit/Objectives`, `GameKit/Streaks`: event tasks and daily returns.
- `GameKit/Wallet`, `GameKit/Inventory`: event currencies and rewards.
- `GameKit/Catalog` (catalog/1), `GameKit/CommerceRoblox`: offers and purchase prompts with runtime price reads.
- `GameKit/Config`, `GameKit/ConfigRoblox` (T4): live values.
- `GameKit/PlayerData`: event progress persistence and expiry.
- `UIKit/Components/ShopCard`, `UIKit/Components/Countdown`, `UIKit/Components/Badge`: offers, timers, new-item marks.
- `GameKit/Telemetry`: event funnel and economy events.

## Data to author
- Event definitions: id, UTC window, objectives, rewards, what is removed afterwards (TBD).
- Rotation rules: pool, slot count, period, seed per period (TBD).
- Season track: tier count, progress per tier, rewards per tier and track (TBD).
- Offers: catalog/1 entries; prices are read at runtime, never hard-coded.

## Authority and abuse risks
- **Clock**: windows are evaluated on the server with UTC passed in by the adapter; the client clock never decides.
- **Duplicate grants**: event and tier rewards grant once per player per reward id.
- **Purchases**: receipts are deduplicated by purchase id; grants are saved before `PurchaseGranted`.
- **Expired content**: offers and progress for ended events are refused even if a client still shows them.
- **Config mistakes**: validate live config with the same validators as authored data and fall back on a bad value.

## Performance pitfalls
- Recomputing rotations per player per frame: compute once per period and cache.
- Loading every past event's assets: keep only the active event's content loaded.
- Large config payloads: config values are capped in size; keep them small and versioned.

## Policy notes
- Randomised offers bought with Robux follow the paid random items rules (odds shown, summing to exactly 100%, `GameKit/PolicyGate` treatments).
- Prices are read at runtime (`GameKit/CommerceRoblox`); the factory sets no prices.
- Sales of products outside the originating experience ended on 2026-05-29 (release research, section 2).
- In agent Studio sessions the factory hooks ask before purchase prompts, deny the subscription, bulk, Premium and Robux-transfer prompt APIs and completed purchases (`docs/mcp.md`).

## Test checklist
- [ ] Event windows open and close at the configured UTC boundaries, including across a server that stays up.
- [ ] Rotation for a period is the same on every server (seeded) and changes at the boundary.
- [ ] Each reward grants once, also after rejoin and server shutdown.
- [ ] Buying an expired offer through a forged remote is refused.
- [ ] A malformed live config value falls back to the authored default.
- [ ] Season track: tier progress, free and premium flags, end-of-season handling.

## Design questions (TBD)
- TBD: Which event cadence, if any?
- TBD: Global rotation or per-player rotation?
- TBD: Is there a season track, and what are its tracks?
- TBD: Does event progress carry over after an event ends?
- TBD: Which values must be changeable without a publish?

## Reference systems
- Feature packages Season Passes, Bundles, Missions and Engagement Rewards as API shapes ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5; reference only).
- Experience configs and monetization APIs in the [release research](../../../../docs/research/release-monetization-analytics-2026-10.md), sections 2 and 3.
- catalog/1 in [runtime-kits.md](../../../../docs/runtime-kits.md), section 9.3; system X30 in the genre coverage research.
