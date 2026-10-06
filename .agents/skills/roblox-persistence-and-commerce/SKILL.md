---
name: roblox-persistence-and-commerce
description: Design, audit and fix player data and commerce with the GameKit platform modules - session-locked PlayerData (memory, DataStore or injected ProfileStore), versioned migrations, autosave and BindToClose flush, settings persistence, catalog/1 products, runtime price reads, ownership checks, policy-gated prompts and grant-once receipts (BindReceiptHandler or the ReceiptLedger) - with Lune specs that inject failures. Use for saves, data loss, duplication, migrations, rewards, shops and purchase flows.
---

# Persistence and commerce

## Purpose
Player data that survives failures and purchases that grant exactly once, built from the tested GameKit modules rather than one-off code. **Gate:** production skill. It acts on a game repository only after an explicit game-build request (AGENTS.md, Boundary); in this factory repo run it only against fixtures and fakes. Live products, prices, real purchases and production data always need the owner's explicit approval.

## Triggers
Saves, data loss, duplication, schema migrations, settings that do not stick, rewards and currency, shops, developer products, game passes, subscriptions, purchase flows, receipt handling.

## Inputs
Current data schema and every historic version, write paths, the catalog/1 product list, reward rules, known incidents.

## Required context
- Usage guide: `docs/gamekit-platform.md` (sections Player data and Commerce); contracts catalog/1 and settings/1 in `docs/runtime-kits.md`.
- Data: `packages/GameKit/PlayerData.luau` (`PlayerData.new({ template, version, migrations, backend })`, `store:load`, `session:update/get/set/grantReceipt/keyStore`, `memoryBackend`, `dataStoreBackend`, `profileStoreBackend` with ProfileStore injected, never vendored), `PlayerDataRoblox.luau` (`chooseBackend`, `bind` with kicks, autosave and the BindToClose flush), `SettingsStore.luau`.
- Commerce: `packages/GameKit/Catalog.luau` (catalog/1), `Commerce.luau` (`canPrompt`, `priceProvider`, `ownership`, `grantWriter`, `receiptProcessor`), `CommerceRoblox.luau` (`prompt`, `priceProvider`, `ownership`, `priceLevels`, `bindReceipts`), `PolicyGate.luau`.
- Separate-key ledger: `packages/Runtime/ReceiptLedger.luau` (retention `minRetentionDays`, `maxReceipts`), `RobloxReceiptAdapter.luau` (`bind` on `BindReceiptHandler`, legacy `callback`), `CommerceCatalog.luau` (`fromCatalog`, `validateEntry`).
- `references/legacy-datastore-migration.md`, `knowledge/records/analytics-release-policy.json`.

## Tools
Lune specs with the G1 fakes (`tests/fakes/FakeDataStore`, `FakeProfileStore`, `FakeMarketplace`, `FakeEnv`); `lune run tests/run.luau gamekit_platform` and `lune run tests/runtime/run.luau`. Studio MCP `execute_luau` on the diagnostic place only, for the `platform_playerdata_memory` probe. DataStore writes and purchase prompts in Luau ask first in Claude Code and are denied in Codex; completed purchases are denied in both.

## Procedure
1. Schema inventory: keys, `version`, a migration per step (`migrations[n]` from n-1 to n), the template, size and writers. Load refusals are closed reasons (`locked`, `corrupt`, `newer_schema`, `migration_failed`, `too_large`); a newer schema is never downgraded.
2. Storage: `PlayerDataRoblox.chooseBackend` (memory in Studio or with no `env.place` unless DataStores are allowed; DataStores or the game's ProfileStore live) and `PlayerDataRoblox.bind(store, { game })`. Every change goes through `session:update(fn)`, which commits only valid, storable, in-budget results.
3. Settings: `SettingsStore.new({ store = session:keyStore() })`, guarded remote with `SettingsStore.patchSchema()`.
4. Products: one catalog/1 table. Setup mode keeps everything disabled with placeholder ids (0, EXP-0); game mode needs real, owner-verified ids. No prices in data: show `priceProvider` results.
5. Prompts: `CommerceRoblox.prompt(MarketplaceService, catalog, key, player, { policy = gate:predicate(player) }, env)`, which runs `Commerce.canPrompt` first. Subscriptions and `paid_random_item` products fail closed without policy. Subscriptions also fail closed (`studio_subscription`) unless the place is known to be live: `isStudio = false`, from `ctx.place` or `env.place`.
6. Receipts: exactly one handler per server. Profile-backed: `Commerce.receiptProcessor` and `CommerceRoblox.bindReceipts` (`Processed` only after the durable save). Separate key: `ReceiptLedger` with `RobloxReceiptAdapter.bind`. Never grant from prompt-finished events. Emit economy telemetry from `onResult`, after the commit.
7. Test with failure injection: DataStore errors and throttles, a session stolen mid-game, leave mid-load, duplicate and late receipts, a missing grant writer, migration from every historic version, retention pruning.

## Outputs
Schema and migration table, the catalog/1 table, wiring code using the modules above, and specs for each migration and failure case.

## Acceptance
Migration tests from every historic version. A duplicate-receipt test grants once. Failed saves never overwrite good data. Setup mode never prompts. `lune run tests/run.luau` and `lune run tests/runtime/run.luau` are green.

## Failure
- A test needs real DataStores or purchases: keep the logic in the core, test it with the fakes, and leave the adapter T4 (owner-run in a published game).
- ProfileStore is missing from the game: inject it from the game's packages; never vendor or require it by path from GameKit.
- `receipt_capacity_requires_migration`: in-window receipts filled `maxReceipts`. Raise the cap or move to the profile-backed path; never evict in-window receipts.
- A hook asked about or denied a DataStore write or purchase prompt: it is gated on purpose. Proceed only on the unpublished diagnostic place in a Studio test session, and never work around a deny.

## Related
roblox-gameplay-kit (economy modules: `docs/gamekit-economy.md`, sections on persistence and paid random items), roblox-multiplayer-integrity, roblox-release-pass, roblox-luau-testing.
